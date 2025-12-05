//! TerminalPool - 多终端管理 + 统一渲染
//!
//! 职责分离：
//! - TerminalPool 管理多个 Terminal 实例（状态 + PTY）
//! - 渲染位置由调用方指定（Swift 控制布局）
//! - 统一提交：beginFrame → renderTerminal × N → endFrame

use crate::domain::aggregates::{Terminal, TerminalId};
use crate::rio_event::EventQueue;
use crate::rio_machine::Machine;
use crate::render::{Renderer, RenderConfig};
use crate::render::font::FontContext;
use corcovado::channel;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use std::thread::JoinHandle;
use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
use sugarloaf::{Sugarloaf, SugarloafWindow, SugarloafWindowSize, SugarloafRenderer, Object, ImageObject, layout::RootStyle};
use std::ffi::c_void;

use super::ffi::{AppConfig, ErrorCode, TerminalEvent, TerminalEventType, TerminalAppEventCallback};

/// 单个终端条目
struct TerminalEntry {
    /// Terminal 聚合根
    terminal: Arc<Mutex<Terminal>>,

    /// PTY 输入通道
    pty_tx: channel::Sender<rio_backend::event::Msg>,

    /// Machine 线程句柄
    #[allow(dead_code)]
    machine_handle: JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>,

    /// 终端尺寸
    cols: u16,
    rows: u16,
}

/// 终端池
pub struct TerminalPool {
    /// 终端映射表
    terminals: HashMap<usize, TerminalEntry>,

    /// 下一个终端 ID
    next_id: usize,

    /// Sugarloaf 渲染引擎（共享）
    sugarloaf: Mutex<Sugarloaf<'static>>,

    /// 渲染器
    renderer: Mutex<Renderer>,

    /// 字体上下文
    font_context: Arc<FontContext>,

    /// 待渲染的 objects（每帧累积）
    pending_objects: Vec<Object>,

    /// 事件队列
    event_queue: EventQueue,

    /// 事件回调
    event_callback: Option<(TerminalAppEventCallback, *mut c_void)>,

    /// 配置
    config: AppConfig,
}

// TerminalPool 需要实现 Send（跨线程传递）
// 注意：event_callback 中的 *mut c_void 不是 Send，但我们保证只在主线程使用
unsafe impl Send for TerminalPool {}

impl TerminalPool {
    /// 创建终端池
    pub fn new(config: AppConfig) -> Result<Self, ErrorCode> {
        // 验证配置
        if config.window_handle.is_null() {
            return Err(ErrorCode::InvalidConfig);
        }

        // 创建 EventQueue
        let event_queue = EventQueue::new();

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

        // 创建 Sugarloaf
        let sugarloaf = Self::create_sugarloaf(&config, &font_library_for_sugarloaf)?;

        Ok(Self {
            terminals: HashMap::new(),
            next_id: 1,  // 从 1 开始，0 表示无效
            sugarloaf: Mutex::new(sugarloaf),
            renderer: Mutex::new(renderer),
            font_context,
            pending_objects: Vec::new(),
            event_queue,
            event_callback: None,
            config,
        })
    }

    /// 创建 Sugarloaf 实例
    fn create_sugarloaf(config: &AppConfig, font_library: &FontLibrary) -> Result<Sugarloaf<'static>, ErrorCode> {
        #[cfg(target_os = "macos")]
        let raw_window_handle = {
            use raw_window_handle::{AppKitWindowHandle, RawWindowHandle};
            match std::ptr::NonNull::new(config.window_handle) {
                Some(nn_ptr) => {
                    let handle = AppKitWindowHandle::new(nn_ptr);
                    RawWindowHandle::AppKit(handle)
                }
                None => return Err(ErrorCode::InvalidConfig),
            }
        };

        #[cfg(target_os = "macos")]
        let raw_display_handle = {
            use raw_window_handle::{AppKitDisplayHandle, RawDisplayHandle};
            RawDisplayHandle::AppKit(AppKitDisplayHandle::new())
        };

        let window = SugarloafWindow {
            handle: raw_window_handle,
            display: raw_display_handle,
            size: SugarloafWindowSize {
                width: config.window_width,
                height: config.window_height,
            },
            scale: config.scale,
        };

        let renderer = SugarloafRenderer::default();
        let layout = RootStyle {
            font_size: config.font_size,
            line_height: config.line_height,
            scale_factor: config.scale,
        };

        let mut sugarloaf = match Sugarloaf::new(window, renderer, font_library, layout) {
            Ok(instance) => instance,
            Err(with_errors) => with_errors.instance,
        };

        // 透明背景，让 Swift 层的磨砂效果显示
        sugarloaf.set_background_color(None);

        Ok(sugarloaf)
    }

    /// 创建新终端
    ///
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal(&mut self, cols: u16, rows: u16) -> i32 {
        let id = self.next_id;
        self.next_id += 1;

        eprintln!("🆕 [TerminalPool] Creating terminal {} ({}x{})", id, cols, rows);

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
        );

        // 2. 创建 PTY 和 Machine
        let (machine_handle, pty_tx) = match Self::create_pty_and_machine(&terminal, self.event_queue.clone()) {
            Ok(result) => result,
            Err(e) => {
                eprintln!("❌ [TerminalPool] Failed to create PTY: {:?}", e);
                return -1;
            }
        };

        // 3. 存储条目
        let entry = TerminalEntry {
            terminal: Arc::new(Mutex::new(terminal)),
            pty_tx,
            machine_handle,
            cols,
            rows,
        };

        self.terminals.insert(id, entry);

        eprintln!("✅ [TerminalPool] Terminal {} created", id);

        id as i32
    }

    /// 创建 PTY 和 Machine
    fn create_pty_and_machine(
        terminal: &Terminal,
        event_queue: EventQueue,
    ) -> Result<(JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>, channel::Sender<rio_backend::event::Msg>), ErrorCode> {
        use teletypewriter::create_pty_with_fork;
        use crate::rio_event::FFIEventListener;
        use std::borrow::Cow;
        use std::env;

        let crosswords = terminal.inner_crosswords()
            .ok_or(ErrorCode::InvalidConfig)?;

        let cols = terminal.cols() as u16;
        let rows = terminal.rows() as u16;
        let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());

        let pty = create_pty_with_fork(&Cow::Owned(shell), cols, rows)
            .map_err(|_| ErrorCode::RenderError)?;

        let pty_fd = *pty.child.id;
        let shell_pid = *pty.child.pid as u32;

        let event_listener = FFIEventListener::new(event_queue, terminal.id().0);

        let machine = Machine::new(
            crosswords,
            pty,
            event_listener,
            terminal.id().0,
            pty_fd,
            shell_pid,
        ).map_err(|_| ErrorCode::RenderError)?;

        let pty_tx = machine.channel();
        let handle = machine.spawn();

        Ok((handle, pty_tx))
    }

    /// 关闭终端
    pub fn close_terminal(&mut self, id: usize) -> bool {
        if let Some(entry) = self.terminals.remove(&id) {
            eprintln!("🗑️ [TerminalPool] Closing terminal {}", id);
            // PTY 会在 pty_tx drop 时自动清理
            drop(entry.pty_tx);
            true
        } else {
            false
        }
    }

    /// 调整终端大小
    pub fn resize_terminal(&mut self, id: usize, cols: u16, rows: u16, width: f32, height: f32) -> bool {
        if let Some(entry) = self.terminals.get_mut(&id) {
            eprintln!("📐 [TerminalPool] Resizing terminal {} to {}x{}", id, cols, rows);

            // 更新 Terminal
            {
                let mut terminal = entry.terminal.lock();
                terminal.resize(cols as usize, rows as usize);
            }

            // 通知 PTY
            use teletypewriter::WinsizeBuilder;
            let winsize = WinsizeBuilder {
                rows,
                cols,
                width: width as u16,
                height: height as u16,
            };
            crate::rio_machine::send_resize(&entry.pty_tx, winsize);

            // 更新存储的尺寸
            entry.cols = cols;
            entry.rows = rows;

            true
        } else {
            false
        }
    }

    /// 发送输入到终端
    pub fn input(&self, id: usize, data: &[u8]) -> bool {
        if let Some(entry) = self.terminals.get(&id) {
            crate::rio_machine::send_input(&entry.pty_tx, data);
            true
        } else {
            false
        }
    }

    /// 滚动终端
    pub fn scroll(&self, id: usize, delta: i32) -> bool {
        if let Some(entry) = self.terminals.get(&id) {
            let mut terminal = entry.terminal.lock();
            terminal.scroll(delta);
            true
        } else {
            false
        }
    }

    // ========================================================================
    // 渲染流程（统一提交）
    // ========================================================================

    /// 开始新的一帧（清空待渲染列表）
    pub fn begin_frame(&mut self) {
        self.pending_objects.clear();
    }

    /// 渲染终端到指定位置（累积到待渲染列表）
    ///
    /// # 参数
    /// - id: 终端 ID
    /// - x, y: 渲染位置（逻辑坐标，Y 从顶部开始）
    /// - width, height: 终端区域大小（逻辑坐标）
    ///   - 如果 > 0，会自动计算 cols/rows 并 resize
    ///   - 如果 = 0，不执行 resize
    pub fn render_terminal(&mut self, id: usize, x: f32, y: f32, width: f32, height: f32) -> bool {
        // 获取字体度量（用于计算 cols/rows 和 Y 坐标）
        let font_metrics = {
            let renderer = self.renderer.lock();
            crate::render::config::FontMetrics::compute(
                renderer.config(),
                &self.font_context,
            )
        };
        let cell_width = font_metrics.cell_width;
        let cell_height = font_metrics.cell_height;

        // 如果提供了 width/height，自动计算 cols/rows 并 resize
        if width > 0.0 && height > 0.0 {
            // width/height 是逻辑坐标，转成物理像素
            // cell_width/cell_height 已经是基于物理字体大小计算的（物理像素）
            let scale = self.config.scale;
            let physical_width = width * scale;
            let physical_height = height * scale;

            // cell_width/cell_height 已经是物理像素，不需要再乘 scale
            let new_cols = (physical_width / cell_width).floor() as u16;
            let new_rows = (physical_height / cell_height).floor() as u16;

            if new_cols > 0 && new_rows > 0 {
                // 获取当前终端尺寸，只在变化时 resize
                if let Some(entry) = self.terminals.get(&id) {
                    if entry.cols != new_cols || entry.rows != new_rows {
                        self.resize_terminal(id, new_cols, new_rows, width, height);
                    }
                }
            }
        }

        let entry = match self.terminals.get(&id) {
            Some(e) => e,
            None => return false,
        };

        // 获取终端状态
        let terminal = entry.terminal.lock();
        let state = terminal.state();
        let rows = terminal.rows();
        drop(terminal);

        // 使用 Renderer 渲染每一行
        let mut renderer = self.renderer.lock();

        for line in 0..rows {
            let image = renderer.render_line(line, &state);

            let image_obj = ImageObject {
                position: [x, y + line as f32 * cell_height],
                image,
            };

            self.pending_objects.push(Object::Image(image_obj));
        }

        drop(renderer);
        true
    }

    /// 结束帧（统一提交渲染）
    pub fn end_frame(&mut self) {
        let frame_start = std::time::Instant::now();

        let mut sugarloaf = self.sugarloaf.lock();

        // 设置所有待渲染对象
        sugarloaf.set_objects(self.pending_objects.clone());

        // 触发 GPU 渲染
        sugarloaf.render();

        // 清空缓冲区
        let object_count = self.pending_objects.len();
        self.pending_objects.clear();

        drop(sugarloaf);

        let frame_time = frame_start.elapsed().as_micros();
        eprintln!("🎯FRAME_PERF TerminalPool::end_frame() took {}μs ({:.2}ms) | objects={}",
                  frame_time, frame_time as f32 / 1000.0, object_count);
    }

    /// 调整 Sugarloaf 尺寸
    pub fn resize_sugarloaf(&mut self, width: f32, height: f32) {
        let mut sugarloaf = self.sugarloaf.lock();
        sugarloaf.resize(width as u32, height as u32);
    }

    /// 设置事件回调
    pub fn set_event_callback(&mut self, callback: TerminalAppEventCallback, context: *mut c_void) {
        self.event_callback = Some((callback, context));

        // 设置 EventQueue 回调
        let pool_ptr = self as *mut TerminalPool as *mut c_void;
        self.event_queue.set_callback(
            Self::event_queue_callback,
            None,
            pool_ptr,
        );
    }

    /// EventQueue 回调
    extern "C" fn event_queue_callback(context: *mut c_void, event: crate::rio_event::FFIEvent) {
        if context.is_null() {
            return;
        }

        let event_type = match event.event_type {
            0 => TerminalEventType::Wakeup,
            1 => TerminalEventType::Render,
            2 => TerminalEventType::CursorBlink,
            3 => TerminalEventType::Bell,
            4 => TerminalEventType::TitleChanged,
            _ => return,
        };

        let terminal_event = TerminalEvent {
            event_type,
            data: event.route_id as u64,  // 传递终端 ID
        };

        unsafe {
            let pool = &*(context as *const TerminalPool);
            if let Some((callback, swift_context)) = pool.event_callback {
                callback(swift_context, terminal_event);
            }
        }
    }

    /// 获取终端数量
    pub fn terminal_count(&self) -> usize {
        self.terminals.len()
    }
}

impl Drop for TerminalPool {
    fn drop(&mut self) {
        eprintln!("🗑️ [TerminalPool] Dropping pool with {} terminals", self.terminals.len());
        // terminals 会自动 drop，PTY 连接会关闭
    }
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_config() -> AppConfig {
        AppConfig {
            cols: 80,
            rows: 24,
            font_size: 14.0,
            line_height: 1.2,
            scale: 2.0,
            window_handle: std::ptr::null_mut(),  // 测试环境
            display_handle: std::ptr::null_mut(),
            window_width: 800.0,
            window_height: 600.0,
            history_size: 10000,
        }
    }

    #[test]
    fn test_terminal_pool_create_fails_without_window() {
        let config = create_test_config();
        let result = TerminalPool::new(config);
        assert!(result.is_err());  // 没有 window_handle 应该失败
    }
}
