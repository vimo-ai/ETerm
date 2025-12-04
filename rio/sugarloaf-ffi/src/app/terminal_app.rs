//! TerminalApp - 终端应用协调者
//!
//! 职责：
//! - 持有 Terminal 聚合根和 Renderer
//! - 协调 PTY → Terminal → Render → Metal 完整链路
//! - 提供高层 API 给 FFI 层

use crate::domain::aggregates::{Terminal, TerminalId};
use crate::domain::events::TerminalEvent as DomainEvent;
use crate::domain::views::selection::SelectionType;
use crate::render::{Renderer, RenderConfig};
use crate::render::font::FontContext;
use super::ffi::{AppConfig, ErrorCode, TerminalEvent, TerminalEventType, TerminalAppEventCallback, FontMetrics, GridPoint};
use std::sync::Arc;
use std::ffi::c_void;
use parking_lot::Mutex;
use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
use sugarloaf::{Sugarloaf, SugarloafWindow, SugarloafWindowSize, SugarloafRenderer, Object, layout::RootStyle};

/// 终端应用（协调者）
pub struct TerminalApp {
    /// Terminal 聚合根
    terminal: Arc<Mutex<Terminal>>,

    /// 渲染器
    renderer: Mutex<Renderer>,

    /// Sugarloaf 渲染引擎 (测试环境下可能为 None)
    sugarloaf: Option<Mutex<Sugarloaf<'static>>>,

    /// 字体上下文
    font_context: Arc<FontContext>,

    /// 事件回调
    event_callback: Option<(TerminalAppEventCallback, *mut c_void)>,

    /// 配置
    config: AppConfig,
}

impl TerminalApp {
    /// 创建终端应用
    pub fn new(config: AppConfig) -> Result<Self, ErrorCode> {
        // 验证配置
        if config.cols == 0 || config.rows == 0 {
            return Err(ErrorCode::InvalidConfig);
        }

        // 创建 Terminal（使用 new_for_test，ID 固定为 0）
        let terminal_id = TerminalId(0);
        let terminal = Terminal::new_for_test(
            terminal_id,
            config.cols as usize,
            config.rows as usize,
        );

        // 创建 FontLibrary (为 FontContext 和 Sugarloaf 各创建一个)
        let (font_library_for_context, _) = FontLibrary::new(SugarloafFonts::default());
        let (font_library_for_sugarloaf, _) = FontLibrary::new(SugarloafFonts::default());

        // 创建字体上下文
        let font_context = Arc::new(FontContext::new(font_library_for_context));

        // 创建渲染配置
        let render_config = RenderConfig::new(
            config.font_size,
            config.line_height,
            config.scale,
        );

        // 创建渲染器
        let renderer = Renderer::new(font_context.clone(), render_config);

        // 创建 Sugarloaf (测试环境下允许失败)
        let sugarloaf = if config.window_handle.is_null() {
            #[cfg(test)]
            {
                None // 测试环境：window_handle 为 null 时跳过 Sugarloaf
            }
            #[cfg(not(test))]
            {
                return Err(ErrorCode::InvalidConfig); // 非测试环境：必须提供 window_handle
            }
        } else {
            Some(Mutex::new(Self::create_sugarloaf(&config, &font_library_for_sugarloaf)?))
        };

        Ok(Self {
            terminal: Arc::new(Mutex::new(terminal)),
            renderer: Mutex::new(renderer),
            sugarloaf,
            font_context,
            event_callback: None,
            config,
        })
    }

    /// 创建 Sugarloaf 实例
    fn create_sugarloaf(config: &AppConfig, font_library: &FontLibrary) -> Result<Sugarloaf<'static>, ErrorCode> {
        // 验证 window_handle
        if config.window_handle.is_null() {
            return Err(ErrorCode::InvalidConfig);
        }

        // 创建 raw window handle (macOS)
        #[cfg(target_os = "macos")]
        let raw_window_handle = {
            use raw_window_handle::{AppKitWindowHandle, RawWindowHandle};
            match std::ptr::NonNull::new(config.window_handle) {
                Some(nn_ptr) => {
                    let handle = AppKitWindowHandle::new(nn_ptr);
                    RawWindowHandle::AppKit(handle)
                }
                None => {
                    return Err(ErrorCode::InvalidConfig);
                }
            }
        };

        #[cfg(target_os = "macos")]
        let raw_display_handle = {
            use raw_window_handle::{AppKitDisplayHandle, RawDisplayHandle};
            RawDisplayHandle::AppKit(AppKitDisplayHandle::new())
        };

        // 创建 SugarloafWindow
        let window = SugarloafWindow {
            handle: raw_window_handle,
            display: raw_display_handle,
            size: SugarloafWindowSize {
                width: config.window_width,
                height: config.window_height,
            },
            scale: config.scale,
        };

        // 创建 Sugarloaf 渲染器
        let renderer = SugarloafRenderer::default();

        // 创建 RootStyle
        let layout = RootStyle {
            font_size: config.font_size,
            line_height: config.line_height,
            scale_factor: config.scale,
        };

        // 创建 Sugarloaf
        let sugarloaf = match Sugarloaf::new(window, renderer, font_library, layout) {
            Ok(instance) => instance,
            Err(with_errors) => with_errors.instance,
        };

        Ok(sugarloaf)
    }

    /// 设置事件回调
    pub fn set_event_callback(&mut self, callback: TerminalAppEventCallback, context: *mut c_void) {
        self.event_callback = Some((callback, context));
    }

    /// 触发事件
    fn emit_event(&self, event_type: TerminalEventType, data: u64) {
        if let Some((callback, context)) = self.event_callback {
            let event = TerminalEvent { event_type, data };
            callback(context, event);
        }
    }

    /// 写入数据（PTY → Terminal）
    pub fn write(&mut self, data: &[u8]) -> Result<(), ErrorCode> {
        // 验证 UTF-8（警告但不失败）
        if std::str::from_utf8(data).is_err() {
            eprintln!("[TerminalApp] Warning: Invalid UTF-8 data");
        }

        // 写入 Terminal
        {
            let mut terminal = self.terminal.lock();
            terminal.write(data);
        }

        // 触发 Damaged 事件（通知 Swift 重绘）
        self.emit_event(TerminalEventType::Damaged, 0);

        Ok(())
    }

    /// 渲染（批量渲染所有行）
    pub fn render(&mut self) -> Result<(), ErrorCode> {
        // 1. 从 Terminal 获取状态
        let terminal = self.terminal.lock();
        let state = terminal.state();
        let rows = terminal.rows();
        drop(terminal);

        // 2. 使用 Renderer 渲染所有行，得到 SkImage
        let mut renderer = self.renderer.lock();
        let mut objects = Vec::with_capacity(rows);

        // 获取字体度量（用于计算 Y 坐标）
        let font_metrics = crate::render::config::FontMetrics::compute(
            renderer.config(),
            &self.font_context,
        );
        let cell_height = font_metrics.cell_height;

        // 批量渲染所有可见行
        for line in 0..rows {
            let image = renderer.render_line(line, &state);

            // 创建 ImageObject
            let image_obj = sugarloaf::ImageObject {
                position: [0.0, line as f32 * cell_height],
                image,
            };

            objects.push(Object::Image(image_obj));
        }

        drop(renderer);

        // 3. 提交给 Sugarloaf 渲染 (如果存在)
        if let Some(ref sugarloaf) = self.sugarloaf {
            let mut sugarloaf = sugarloaf.lock();
            sugarloaf.set_objects(objects);
            sugarloaf.render();
        }

        Ok(())
    }

    /// 调整大小
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), ErrorCode> {
        if cols == 0 || rows == 0 {
            return Err(ErrorCode::InvalidConfig);
        }

        // 调整 Terminal 大小
        {
            let mut terminal = self.terminal.lock();
            terminal.resize(cols as usize, rows as usize);
        }

        // 清空渲染缓存（尺寸变化需要重新渲染）
        // TODO: renderer.clear_cache()

        // 触发 Damaged 事件
        self.emit_event(TerminalEventType::Damaged, 0);

        Ok(())
    }

    /// 开始选区
    pub fn start_selection(&mut self, point: GridPoint) -> Result<(), ErrorCode> {
        use crate::domain::primitives::GridPoint as DomainPoint;
        use crate::domain::primitives::Absolute;

        let mut terminal = self.terminal.lock();
        let domain_point = DomainPoint::<Absolute>::new(point.col as usize, point.row as usize);
        terminal.start_selection(domain_point, SelectionType::Simple);

        self.emit_event(TerminalEventType::Damaged, 0);
        Ok(())
    }

    /// 更新选区
    pub fn update_selection(&mut self, point: GridPoint) -> Result<(), ErrorCode> {
        use crate::domain::primitives::GridPoint as DomainPoint;
        use crate::domain::primitives::Absolute;

        let mut terminal = self.terminal.lock();
        let domain_point = DomainPoint::<Absolute>::new(point.col as usize, point.row as usize);
        terminal.update_selection(domain_point);

        self.emit_event(TerminalEventType::Damaged, 0);
        Ok(())
    }

    /// 清除选区
    pub fn clear_selection(&mut self) -> Result<(), ErrorCode> {
        let mut terminal = self.terminal.lock();
        terminal.clear_selection();

        self.emit_event(TerminalEventType::Damaged, 0);
        Ok(())
    }

    /// 获取选区文本
    pub fn get_selection_text(&self, out_buffer: &mut [u8]) -> Result<usize, ErrorCode> {
        let terminal = self.terminal.lock();
        let text_opt = terminal.selection_text();

        let text = text_opt.unwrap_or_default();
        let bytes = text.as_bytes();

        if bytes.len() > out_buffer.len() {
            return Err(ErrorCode::OutOfBounds);
        }

        out_buffer[..bytes.len()].copy_from_slice(bytes);
        Ok(bytes.len())
    }

    /// 搜索文本
    pub fn search(&mut self, pattern: &str) -> usize {
        let mut terminal = self.terminal.lock();
        terminal.search(pattern)
    }

    /// 下一个匹配
    pub fn next_match(&mut self) -> bool {
        let mut terminal = self.terminal.lock();
        terminal.next_match();
        true
    }

    /// 上一个匹配
    pub fn prev_match(&mut self) -> bool {
        let mut terminal = self.terminal.lock();
        terminal.prev_match();
        true
    }

    /// 清除搜索
    pub fn clear_search(&mut self) -> Result<(), ErrorCode> {
        let mut terminal = self.terminal.lock();
        terminal.clear_search();
        Ok(())
    }

    /// 滚动
    pub fn scroll(&mut self, delta: i32) -> Result<(), ErrorCode> {
        let mut terminal = self.terminal.lock();
        terminal.scroll(delta);

        self.emit_event(TerminalEventType::Damaged, 0);
        Ok(())
    }

    /// 滚动到顶部
    pub fn scroll_to_top(&mut self) -> Result<(), ErrorCode> {
        let mut terminal = self.terminal.lock();
        terminal.scroll_to_top();

        self.emit_event(TerminalEventType::Damaged, 0);
        Ok(())
    }

    /// 滚动到底部
    pub fn scroll_to_bottom(&mut self) -> Result<(), ErrorCode> {
        let mut terminal = self.terminal.lock();
        terminal.scroll_to_bottom();

        self.emit_event(TerminalEventType::Damaged, 0);
        Ok(())
    }

    /// 重新配置
    pub fn reconfigure(&mut self, config: AppConfig) -> Result<(), ErrorCode> {
        if config.cols == 0 || config.rows == 0 {
            return Err(ErrorCode::InvalidConfig);
        }

        // 更新配置
        self.config = config;

        // 更新渲染配置
        let render_config = RenderConfig::new(
            config.font_size,
            config.line_height,
            config.scale,
        );

        {
            let mut renderer = self.renderer.lock();
            renderer.reconfigure(render_config);
        } // 释放 renderer 锁

        // 调整终端大小（如果变化）
        self.resize(config.cols, config.rows)?;

        Ok(())
    }

    /// 获取字体度量
    pub fn get_font_metrics(&self) -> FontMetrics {
        let renderer = self.renderer.lock();
        let config = renderer.config();

        // 计算字体度量
        let metrics = crate::render::config::FontMetrics::compute(config, &self.font_context);

        FontMetrics {
            cell_width: metrics.cell_width,
            cell_height: metrics.cell_height,
            baseline_offset: metrics.baseline_offset,
            line_height: metrics.cell_height,
        }
    }

    /// 轮询事件（从 Terminal 获取领域事件）
    pub fn poll_events(&mut self) -> Vec<DomainEvent> {
        let mut terminal = self.terminal.lock();
        terminal.tick()
    }
}

// 线程安全：TerminalApp 本身不实现 Send/Sync
// 使用者必须从同一线程调用（通常是主线程）

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_config() -> AppConfig {
        AppConfig {
            cols: 80,
            rows: 24,
            font_size: 14.0,
            line_height: 1.2,
            scale: 1.0,
            window_handle: std::ptr::null_mut(),
            display_handle: std::ptr::null_mut(),
            window_width: 800.0,
            window_height: 600.0,
            history_size: 1000,
        }
    }

    #[test]
    fn test_create_terminal_app() {
        let config = create_test_config();
        let app = TerminalApp::new(config);
        assert!(app.is_ok());
    }

    #[test]
    fn test_write_and_render() {
        let config = create_test_config();
        let mut app = TerminalApp::new(config).unwrap();

        // 写入数据
        let data = b"Hello, World!\n";
        assert!(app.write(data).is_ok());

        // 渲染
        assert!(app.render().is_ok());
    }

    #[test]
    fn test_resize() {
        let config = create_test_config();
        let mut app = TerminalApp::new(config).unwrap();

        assert!(app.resize(100, 30).is_ok());
        assert!(app.resize(0, 30).is_err());  // 无效尺寸
    }

    #[test]
    fn test_selection() {
        let config = create_test_config();
        let mut app = TerminalApp::new(config).unwrap();

        // 写入一些数据
        app.write(b"Hello, World!\n").unwrap();

        // 开始选区
        let start = GridPoint { col: 0, row: 0 };
        assert!(app.start_selection(start).is_ok());

        // 更新选区
        let end = GridPoint { col: 5, row: 0 };
        assert!(app.update_selection(end).is_ok());

        // 获取选区文本
        let mut buffer = [0u8; 256];
        let len = app.get_selection_text(&mut buffer).unwrap();
        let text = std::str::from_utf8(&buffer[..len]).unwrap();
        assert!(text.contains("Hello"));

        // 清除选区
        assert!(app.clear_selection().is_ok());
    }
}
