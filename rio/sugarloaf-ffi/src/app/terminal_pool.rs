//! TerminalPool - 多终端管理 + 统一渲染
//!
//! 职责分离（DDD）：
//! - TerminalPool 管理多个 Terminal 实例（状态 + PTY）
//! - 渲染位置由调用方指定
//! - 统一提交：beginFrame → renderTerminal × N → endFrame
//!
//! 注意：TerminalPool 不知道 DisplayLink 的存在
//! 渲染调度由 RenderScheduler 负责

use crate::domain::aggregates::{Terminal, TerminalId};
use crate::rio_event::EventQueue;
use crate::rio_machine::Machine;
use crate::render::{Renderer, RenderConfig};
use crate::render::font::FontContext;
use corcovado::channel;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use sugarloaf::font::FontLibrary;
use crate::create_default_font_spec;
use sugarloaf::{Sugarloaf, SugarloafWindow, SugarloafWindowSize, SugarloafRenderer, Object, ImageObject, layout::RootStyle};
use std::ffi::c_void;

use super::ffi::{AppConfig, ErrorCode, TerminalEvent, TerminalEventType, TerminalPoolEventCallback};

/// 单个终端的渲染缓存
struct TerminalRenderCache {
    /// 缓存的渲染结果（Image 比 Surface 更轻量）
    cached_image: skia_safe::Image,
    /// 缓存对应的尺寸（物理像素）
    width: u32,
    height: u32,
}

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

    /// PTY 文件描述符（用于获取 CWD）
    pty_fd: i32,

    /// Shell 进程 ID（用于获取 CWD）
    shell_pid: u32,

    /// 渲染缓存（缓存的 Image，按需更新）
    render_cache: Option<TerminalRenderCache>,
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
    event_callback: Option<(TerminalPoolEventCallback, *mut c_void)>,

    /// 配置
    config: AppConfig,

    /// 是否需要渲染（dirty 标记，供外部调度器查询）
    needs_render: Arc<AtomicBool>,

    /// 渲染布局（由 Swift 侧设置，Rust 侧使用）
    /// Vec<(terminal_id, x, y, width, height)>
    render_layout: Arc<Mutex<Vec<(usize, f32, f32, f32, f32)>>>,

    /// 容器高度（用于坐标转换）
    container_height: Arc<Mutex<f32>>,
}

// TerminalPool 需要实现 Send（跨线程传递）
// 注意：event_callback 中的 *mut c_void 不是 Send，但我们保证只在主线程使用
unsafe impl Send for TerminalPool {}

impl TerminalPool {
    /// 创建临时 Surface 用于渲染（用完即释放）
    ///
    /// # 参数
    /// - width, height: Surface 尺寸（物理像素）
    ///
    /// # 返回
    /// - Some(Surface): 创建成功
    /// - None: 创建失败
    fn create_temp_surface(&self, width: u32, height: u32) -> Option<skia_safe::Surface> {
        if width == 0 || height == 0 {
            return None;
        }

        let sugarloaf = self.sugarloaf.lock();
        let context = sugarloaf.get_context();

        // 从 Skia 上下文创建 GPU 加速的 Surface
        #[cfg(target_os = "macos")]
        {
            use skia_safe::{
                gpu::{SurfaceOrigin, surfaces, Budgeted},
                ColorType, ImageInfo, AlphaType, ColorSpace,
            };

            let image_info = ImageInfo::new(
                (width as i32, height as i32),
                ColorType::RGBA8888,
                AlphaType::Premul,
                ColorSpace::new_srgb(),
            );

            // 使用 Skia DirectContext 创建 GPU Surface
            let mut skia_context = context.skia_context.clone();
            let surface = surfaces::render_target(
                &mut skia_context,
                Budgeted::Yes,
                &image_info,
                None,  // sample_count
                SurfaceOrigin::TopLeft,
                None,  // surface_props
                false, // should_create_with_mips
                false, // is_protected
            )?;

            Some(surface)
        }

        #[cfg(not(target_os = "macos"))]
        {
            // 其他平台暂不支持
            None
        }
    }

    /// 创建终端池
    pub fn new(config: AppConfig) -> Result<Self, ErrorCode> {
        // 验证配置
        if config.window_handle.is_null() {
            return Err(ErrorCode::InvalidConfig);
        }

        // 创建 EventQueue
        let event_queue = EventQueue::new();

        // 创建 FontLibrary (为 FontContext 和 Sugarloaf 各创建一个)
        // 使用统一的字体配置（Maple Mono NF CN + Apple Color Emoji）
        let font_spec = create_default_font_spec(config.font_size);
        let (font_library_for_context, _) = FontLibrary::new(font_spec.clone());
        let (font_library_for_sugarloaf, _) = FontLibrary::new(font_spec);

        // 创建字体上下文
        let font_context = Arc::new(FontContext::new(font_library_for_context));

        // 创建渲染配置（统一背景色配置源）
        use crate::domain::primitives::LogicalPixels;
        use rio_backend::config::colors::Colors;
        let colors = Arc::new(Colors::default());
        let render_config = RenderConfig::new(
            LogicalPixels::new(config.font_size),
            config.line_height,
            config.scale,
            colors,
        );

        // 创建渲染器
        let renderer = Renderer::new(font_context.clone(), render_config.clone());

        // 创建 Sugarloaf（使用 render_config 的背景色）
        let sugarloaf = Self::create_sugarloaf(&config, &font_library_for_sugarloaf, &render_config)?;

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
            needs_render: Arc::new(AtomicBool::new(false)),
            render_layout: Arc::new(Mutex::new(Vec::new())),
            container_height: Arc::new(Mutex::new(0.0)),
        })
    }

    /// 创建 Sugarloaf 实例
    fn create_sugarloaf(
        config: &AppConfig,
        font_library: &FontLibrary,
        render_config: &RenderConfig,
    ) -> Result<Sugarloaf<'static>, ErrorCode> {
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

        // 使用统一的背景色配置（来自 RenderConfig）
        sugarloaf.set_background_color(Some(render_config.background_color));

        Ok(sugarloaf)
    }

    /// 创建新终端
    ///
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal(&mut self, cols: u16, rows: u16) -> i32 {
        let id = self.next_id;
        self.next_id += 1;

        // eprintln!("🆕 [TerminalPool] Creating terminal {} ({}x{})", id, cols, rows);

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
        );

        // 2. 创建 PTY 和 Machine
        let (machine_handle, pty_tx, pty_fd, shell_pid) = match Self::create_pty_and_machine(&terminal, self.event_queue.clone()) {
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
            pty_fd,
            shell_pid,
            render_cache: None,  // 首次渲染时创建
        };

        self.terminals.insert(id, entry);

        // eprintln!("✅ [TerminalPool] Terminal {} created", id);

        id as i32
    }

    /// 创建新终端（指定工作目录）
    ///
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal_with_cwd(&mut self, cols: u16, rows: u16, working_dir: Option<String>) -> i32 {
        let id = self.next_id;
        self.next_id += 1;

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
        );

        // 2. 创建 PTY 和 Machine（带工作目录）
        let (machine_handle, pty_tx, pty_fd, shell_pid) = match Self::create_pty_and_machine_with_cwd(&terminal, self.event_queue.clone(), working_dir) {
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
            pty_fd,
            shell_pid,
            render_cache: None,  // 首次渲染时创建
        };

        self.terminals.insert(id, entry);

        id as i32
    }

    /// 创建 PTY 和 Machine
    ///
    /// 默认使用 $HOME 作为工作目录
    fn create_pty_and_machine(
        terminal: &Terminal,
        event_queue: EventQueue,
    ) -> Result<(JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>, channel::Sender<rio_backend::event::Msg>, i32, u32), ErrorCode> {
        // 默认使用用户 home 目录
        let home = std::env::var("HOME").ok();
        Self::create_pty_and_machine_with_cwd(terminal, event_queue, home)
    }

    /// 创建 PTY 和 Machine（支持工作目录）
    ///
    /// 返回: (machine_handle, pty_tx, pty_fd, shell_pid)
    fn create_pty_and_machine_with_cwd(
        terminal: &Terminal,
        event_queue: EventQueue,
        working_dir: Option<String>,
    ) -> Result<(JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>, channel::Sender<rio_backend::event::Msg>, i32, u32), ErrorCode> {
        use teletypewriter::create_pty_with_spawn;
        use crate::rio_event::FFIEventListener;
        use std::env;

        let crosswords = terminal.inner_crosswords()
            .ok_or(ErrorCode::InvalidConfig)?;

        let cols = terminal.cols() as u16;
        let rows = terminal.rows() as u16;
        let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());

        // 注入 ETERM_TERMINAL_ID 环境变量（用于 Claude Hook 调用）
        env::set_var("ETERM_TERMINAL_ID", terminal.id().0.to_string());

        // 统一使用 spawn 创建 PTY（支持指定工作目录）
        // 如果未指定工作目录，默认使用 $HOME
        let cwd = working_dir.or_else(|| env::var("HOME").ok());
        let pty = create_pty_with_spawn(&shell, vec!["-l".to_string()], &cwd, cols, rows)
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

        Ok((handle, pty_tx, pty_fd, shell_pid))
    }

    /// 关闭终端
    pub fn close_terminal(&mut self, id: usize) -> bool {
        if let Some(entry) = self.terminals.remove(&id) {
            // eprintln!("🗑️ [TerminalPool] Closing terminal {}", id);
            // PTY 会在 pty_tx drop 时自动清理
            drop(entry.pty_tx);
            true
        } else {
            false
        }
    }

    /// 获取终端的当前工作目录
    pub fn get_cwd(&self, id: usize) -> Option<std::path::PathBuf> {
        if let Some(entry) = self.terminals.get(&id) {
            teletypewriter::foreground_process_path(entry.pty_fd, entry.shell_pid).ok()
        } else {
            None
        }
    }

    /// 调整终端大小
    pub fn resize_terminal(&mut self, id: usize, cols: u16, rows: u16, width: f32, height: f32) -> bool {
        if let Some(entry) = self.terminals.get_mut(&id) {
            // eprintln!("📐 [TerminalPool] Resizing terminal {} to {}x{}", id, cols, rows);

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
            // 输入后标记需要渲染
            // 某些应用（如 Claude CLI）在 raw 模式下不产生即时回显，
            // 但仍需要更新光标位置等状态，所以输入后应触发渲染
            self.needs_render.store(true, Ordering::Release);
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

    /// 渲染终端到指定位置（累积到待渲染列表，增量渲染）
    ///
    /// # 参数
    /// - id: 终端 ID
    /// - x, y: 渲染位置（逻辑坐标，Y 从顶部开始）
    /// - width, height: 终端区域大小（逻辑坐标）
    ///   - 如果 > 0，会自动计算 cols/rows 并 resize
    ///   - 如果 = 0，不执行 resize
    pub fn render_terminal(&mut self, id: usize, _x: f32, _y: f32, width: f32, height: f32) -> bool {
        // 获取字体度量（物理像素）
        let font_metrics = {
            let renderer = self.renderer.lock();
            crate::render::config::FontMetrics::compute(
                renderer.config(),
                &self.font_context,
            )
        };

        let scale = self.config.scale;

        // 如果提供了 width/height，自动计算 cols/rows 并 resize
        if width > 0.0 && height > 0.0 {
            use crate::domain::primitives::PhysicalPixels;

            let physical_width = PhysicalPixels::new(width * scale);
            let physical_height = PhysicalPixels::new(height * scale);
            // 使用 line_height（= cell_height * factor）计算行数
            let physical_line_height = font_metrics.cell_height.value * self.config.line_height;

            let new_cols = (physical_width.value / font_metrics.cell_width.value).floor() as u16;
            let new_rows = (physical_height.value / physical_line_height).floor() as u16;

            if new_cols > 0 && new_rows > 0 {
                if let Some(entry) = self.terminals.get(&id) {
                    if entry.cols != new_cols || entry.rows != new_rows {
                        self.resize_terminal(id, new_cols, new_rows, width, height);
                    }
                }
            }
        }

        // 计算所需尺寸（物理像素）
        use crate::domain::primitives::PhysicalPixels;
        let physical_width = PhysicalPixels::new(width * scale);
        let physical_height = PhysicalPixels::new(height * scale);
        let cache_width = physical_width.value as u32;
        let cache_height = physical_height.value as u32;

        // 检查缓存是否有效（尺寸匹配）
        let cache_valid = {
            match self.terminals.get(&id) {
                Some(entry) => match &entry.render_cache {
                    Some(cache) => cache.width == cache_width && cache.height == cache_height,
                    None => false,
                },
                None => return false,
            }
        };

        // 检查是否有 damage
        let is_damaged = {
            match self.terminals.get(&id) {
                Some(entry) => {
                    let terminal = entry.terminal.lock();
                    terminal.is_damaged()
                },
                None => return false,
            }
        };

        // 如果缓存有效且没有 damage，跳过渲染
        if cache_valid && !is_damaged {
            return true;
        }

        // 需要重新渲染：获取终端状态
        let (state, rows) = {
            match self.terminals.get(&id) {
                Some(entry) => {
                    let terminal = entry.terminal.lock();
                    let state = terminal.state();
                    let rows = terminal.rows();
                    (state, rows)
                },
                None => return false,
            }
        };

        // 创建临时 Surface 进行渲染
        let mut temp_surface = match self.create_temp_surface(cache_width, cache_height) {
            Some(s) => s,
            None => {
                eprintln!("❌ [TerminalPool] Failed to create temp surface for terminal {}", id);
                return false;
            }
        };

        // 渲染所有行到临时 Surface
        {
            let canvas = temp_surface.canvas();
            canvas.clear(skia_safe::Color::TRANSPARENT);

            let mut renderer = self.renderer.lock();

            let logical_cell_size = font_metrics.to_logical_size(scale);
            let logical_line_height = logical_cell_size.height * self.config.line_height;

            for line in 0..rows {
                let image = renderer.render_line(line, &state);

                // 计算该行在 Surface 内的位置（物理像素）
                let y_offset_pixels = (logical_line_height * (line as f32)) * scale;
                let y_offset = y_offset_pixels.value;

                canvas.draw_image(&image, (0.0f32, y_offset), None);
            }

            renderer.print_frame_stats(&format!("terminal_{}", id));
        }

        // 从临时 Surface 获取 Image 快照并缓存
        let cached_image = temp_surface.image_snapshot();

        // 更新缓存
        if let Some(entry) = self.terminals.get_mut(&id) {
            entry.render_cache = Some(TerminalRenderCache {
                cached_image,
                width: cache_width,
                height: cache_height,
            });
        }

        // temp_surface 在这里自动 drop，释放 GPU 资源

        // 重置 damage 状态
        if let Some(entry) = self.terminals.get(&id) {
            let mut terminal = entry.terminal.lock();
            terminal.reset_damage();
        }

        true
    }

    /// 结束帧（贴图合成）
    ///
    /// 从缓存获取 Image，贴图合成到最终画面
    pub fn end_frame(&mut self) {
        let frame_start = std::time::Instant::now();

        // 从 layout 获取当前需要渲染的终端
        let layout = {
            let render_layout = self.render_layout.lock();
            render_layout.clone()
        };

        if layout.is_empty() {
            return;
        }

        // 清空 pending_objects（新方案不再使用）
        self.pending_objects.clear();

        let mut sugarloaf = self.sugarloaf.lock();
        let lock_time = frame_start.elapsed().as_micros();

        // 从每个终端的缓存获取 Image
        let mut objects = Vec::new();
        for (terminal_id, x, y, _width, _height) in &layout {
            if let Some(entry) = self.terminals.get(terminal_id) {
                if let Some(render_cache) = &entry.render_cache {
                    // 直接使用缓存的 Image（clone 是廉价的引用计数增加）
                    let image_obj = ImageObject {
                        position: [*x, *y],
                        image: render_cache.cached_image.clone(),
                    };

                    objects.push(Object::Image(image_obj));
                }
            }
        }

        let object_count = objects.len();
        sugarloaf.set_objects(objects);
        let set_time = frame_start.elapsed().as_micros() - lock_time;

        // 触发 GPU 渲染
        sugarloaf.render();
        let render_time = frame_start.elapsed().as_micros() - lock_time - set_time;

        // ⚠️ 性能监控日志，请勿删除
        let total_time = frame_start.elapsed().as_micros();
        eprintln!("🎯FRAME_PERF end_frame() total={}μs ({:.2}ms) | lock={}μs set={}μs render={}μs | terminals={}",
                  total_time, total_time as f64 / 1000.0, lock_time, set_time, render_time, object_count);
    }

    // ========================================================================
    // 布局管理（供 RenderScheduler 使用）
    // ========================================================================

    /// 设置渲染布局
    ///
    /// Swift 侧在布局变化时调用（Tab 切换、窗口 resize 等）
    /// 坐标已转换为 Rust 坐标系（Y 从顶部开始）
    ///
    /// # 参数
    /// - layout: Vec<(terminal_id, x, y, width, height)>
    /// - container_height: 容器高度（用于坐标转换）
    pub fn set_render_layout(&self, layout: Vec<(usize, f32, f32, f32, f32)>, container_height: f32) {
        {
            let mut render_layout = self.render_layout.lock();
            *render_layout = layout;
        }
        {
            let mut height = self.container_height.lock();
            *height = container_height;
        }
    }

    /// 获取渲染布局的 Arc 引用（供 RenderScheduler 使用）
    pub fn render_layout_ref(&self) -> Arc<Mutex<Vec<(usize, f32, f32, f32, f32)>>> {
        self.render_layout.clone()
    }

    /// 获取容器高度的 Arc 引用（供 RenderScheduler 使用）
    pub fn container_height_ref(&self) -> Arc<Mutex<f32>> {
        self.container_height.clone()
    }

    /// 渲染所有布局中的终端（由 RenderScheduler 调用）
    ///
    /// 完整的渲染循环：begin_frame → render_terminal × N → end_frame
    /// 在 Rust 侧完成，无需 Swift 参与
    pub fn render_all(&mut self) {
        // 获取当前布局
        let layout = {
            let render_layout = self.render_layout.lock();
            render_layout.clone()
        };

        if layout.is_empty() {
            return;
        }

        // 开始新的一帧
        self.begin_frame();

        // 渲染每个终端
        for (terminal_id, x, y, width, height) in &layout {
            self.render_terminal(*terminal_id, *x, *y, *width, *height);
        }

        // 结束帧（统一提交渲染）
        self.end_frame();
    }

    /// 调整 Sugarloaf 尺寸
    pub fn resize_sugarloaf(&mut self, width: f32, height: f32) {
        let mut sugarloaf = self.sugarloaf.lock();
        sugarloaf.resize(width as u32, height as u32);
    }

    /// 设置 DPI 缩放（窗口在不同 DPI 屏幕间移动时调用）
    ///
    /// 更新渲染器的 scale factor，确保坐标转换正确
    pub fn set_scale(&mut self, scale: f32) {
        // 更新 config 中的 scale
        self.config.scale = scale;

        // 更新渲染器的 scale
        let mut renderer = self.renderer.lock();
        renderer.set_scale(scale);
        drop(renderer);

        // 更新 Sugarloaf 的 scale
        let mut sugarloaf = self.sugarloaf.lock();
        sugarloaf.rescale(scale);
        drop(sugarloaf);

        // 标记需要重新渲染
        self.needs_render.store(true, Ordering::Release);
    }

    /// 设置事件回调
    pub fn set_event_callback(&mut self, callback: TerminalPoolEventCallback, context: *mut c_void) {
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
    ///
    /// 当收到 Wakeup/Render 事件时，标记对应终端的 dirty_lines
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

        // 收到 Wakeup/Render 事件时：
        // 设置 needs_render 标记（供外部调度器查询）
        // 注意：Crosswords 在写入时已自动标记 damage，无需手动调用
        if event_type == TerminalEventType::Wakeup || event_type == TerminalEventType::Render {
            unsafe {
                let pool = &mut *(context as *mut TerminalPool);
                // 设置 dirty 标记
                pool.needs_render.store(true, Ordering::Release);
            }
        }

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

    /// 获取终端（只读）
    pub fn get_terminal(&self, id: usize) -> Option<parking_lot::MutexGuard<'_, Terminal>> {
        self.terminals.get(&id).map(|entry| entry.terminal.lock())
    }

    /// 获取终端（可变）
    pub fn get_terminal_mut(&mut self, id: usize) -> Option<parking_lot::MutexGuard<'_, Terminal>> {
        self.terminals.get(&id).map(|entry| entry.terminal.lock())
    }

    /// 检查是否需要渲染
    ///
    /// 供外部调度器（如 RenderScheduler）查询
    #[inline]
    pub fn needs_render(&self) -> bool {
        self.needs_render.load(Ordering::Acquire)
    }

    /// 清除渲染标记
    ///
    /// 渲染完成后调用
    #[inline]
    pub fn clear_render_flag(&self) {
        self.needs_render.store(false, Ordering::Release);
    }

    /// 获取 needs_render 的 Arc 引用
    ///
    /// 供 RenderScheduler 使用
    pub fn needs_render_flag(&self) -> Arc<AtomicBool> {
        self.needs_render.clone()
    }

    /// 获取字体度量（物理像素）
    ///
    /// 返回 (cell_width, cell_height, line_height)
    /// - cell_width: 单元格宽度（物理像素）
    /// - cell_height: 基础单元格高度（物理像素，不含 line_height_factor）
    /// - line_height: 实际行高（物理像素，= cell_height * line_height_factor）
    pub fn get_font_metrics(&self) -> (f32, f32, f32) {
        let renderer = self.renderer.lock();
        let metrics = crate::render::config::FontMetrics::compute(
            renderer.config(),
            &self.font_context,
        );

        let cell_width = metrics.cell_width.value;
        let cell_height = metrics.cell_height.value;
        let line_height = cell_height * self.config.line_height;

        (cell_width, cell_height, line_height)
    }

    /// 调整字体大小
    ///
    /// # 参数
    /// - operation: 0=重置, 1=减小, 2=增大
    ///
    /// # 说明
    /// - 重置：恢复到默认 14.0pt
    /// - 减小：每次 -1.0pt，最小 6.0pt
    /// - 增大：每次 +1.0pt，最大 100.0pt
    pub fn change_font_size(&mut self, operation: u8) {
        use crate::domain::primitives::LogicalPixels;

        // 计算新字体大小
        let new_font_size = match operation {
            0 => 14.0,  // Reset
            1 => (self.config.font_size - 1.0).max(6.0),  // Decrease
            2 => (self.config.font_size + 1.0).min(100.0),  // Increase
            _ => return,  // 无效操作
        };

        // 更新配置
        self.config.font_size = new_font_size;

        // 更新渲染器
        {
            let mut renderer = self.renderer.lock();
            renderer.set_font_size(LogicalPixels::new(new_font_size));
        }

        // 标记需要重新渲染
        self.needs_render.store(true, Ordering::Release);
    }

    /// 获取当前字体大小
    pub fn get_font_size(&self) -> f32 {
        self.config.font_size
    }

    // ========================================================================
    // 搜索功能
    // ========================================================================

    /// 搜索文本
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    /// - query: 搜索关键词
    ///
    /// # 返回
    /// - 匹配数量（>= 0），失败返回 -1
    pub fn search(&self, terminal_id: usize, query: &str) -> i32 {
        let entry = match self.terminals.get(&terminal_id) {
            Some(e) => e,
            None => return -1,
        };

        let mut terminal = entry.terminal.lock();
        let count = terminal.search(query);

        // 触发渲染更新
        self.needs_render.store(true, Ordering::Release);

        count as i32
    }

    /// 跳转到下一个匹配
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    pub fn search_next(&self, terminal_id: usize) {
        if let Some(entry) = self.terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.next_match();

            // 触发渲染更新
            self.needs_render.store(true, Ordering::Release);
        }
    }

    /// 跳转到上一个匹配
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    pub fn search_prev(&self, terminal_id: usize) {
        if let Some(entry) = self.terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.prev_match();

            // 触发渲染更新
            self.needs_render.store(true, Ordering::Release);
        }
    }

    /// 清除搜索
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    pub fn clear_search(&self, terminal_id: usize) {
        if let Some(entry) = self.terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.clear_search();

            // 触发渲染更新
            self.needs_render.store(true, Ordering::Release);
        }
    }
}

impl Drop for TerminalPool {
    fn drop(&mut self) {
        // eprintln!("🗑️ [TerminalPool] Dropping pool with {} terminals", self.terminals.len());
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
        use super::super::ffi::DEFAULT_LINE_HEIGHT;

        AppConfig {
            cols: 80,
            rows: 24,
            font_size: 14.0,
            line_height: DEFAULT_LINE_HEIGHT,
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

    /// 测试字体大小计算逻辑（不需要 TerminalPool 实例）
    #[test]
    fn test_font_size_calculation() {
        let initial_size = 14.0f32;

        // Test reset (operation = 0)
        let reset_size = 14.0f32;  // Reset 固定为 14.0
        assert_eq!(reset_size, 14.0);

        // Test decrease (operation = 1)
        let decreased = (initial_size - 1.0).max(6.0);
        assert_eq!(decreased, 13.0);

        // Test decrease at minimum
        let at_min = 6.0f32;
        let decreased_at_min = (at_min - 1.0).max(6.0);
        assert_eq!(decreased_at_min, 6.0);  // 不能低于 6.0

        // Test increase (operation = 2)
        let increased = (initial_size + 1.0).min(100.0);
        assert_eq!(increased, 15.0);

        // Test increase at maximum
        let at_max = 100.0f32;
        let increased_at_max = (at_max + 1.0).min(100.0);
        assert_eq!(increased_at_max, 100.0);  // 不能超过 100.0
    }

    /// 测试字体大小操作序列
    #[test]
    fn test_font_size_operations_sequence() {
        let mut font_size = 14.0f32;

        // 连续增大 3 次
        for _ in 0..3 {
            font_size = (font_size + 1.0).min(100.0);
        }
        assert_eq!(font_size, 17.0);

        // 重置
        font_size = 14.0;
        assert_eq!(font_size, 14.0);

        // 连续减小到最小
        for _ in 0..20 {
            font_size = (font_size - 1.0).max(6.0);
        }
        assert_eq!(font_size, 6.0);
    }

    /// 顶层集成测试：选区变化时的渲染性能
    ///
    /// 模拟真实场景：Terminal + Renderer，选区从 (0,0)-(3,10) 扩展到 (0,0)-(3,20)
    #[test]
    fn test_selection_change_full_pipeline() {
        use crate::domain::aggregates::{Terminal, TerminalId};
        use crate::domain::{SelectionView, SelectionType, AbsolutePoint};
        use crate::render::{Renderer, RenderConfig};
        use crate::render::font::FontContext;
        use crate::domain::primitives::LogicalPixels;
        use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
        use rio_backend::config::colors::Colors;
        use std::sync::Arc;

        // 1. 创建 100 行的 Terminal
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 100);

        // 写入一些内容让每行不同
        for i in 0..100 {
            terminal.write(format!("Line {:03} - some content here\r\n", i).as_bytes());
        }

        // 2. 创建 Renderer
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));
        let colors = Arc::new(Colors::default());
        let config = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 1.0, colors);
        let mut renderer = Renderer::new(font_context, config);

        // 3. 第一帧：设置初始选区 (0,0)-(3,10)，渲染所有行
        let mut state = terminal.state();
        state.selection = Some(SelectionView::new(
            AbsolutePoint::new(0, 0),
            AbsolutePoint::new(3, 10),
            SelectionType::Simple,
        ));

        let frame1_start = std::time::Instant::now();
        for line in 0..100 {
            let _img = renderer.render_line(line, &state);
        }
        let frame1_time = frame1_start.elapsed();
        let frame1_stats = renderer.stats.clone();

        eprintln!("Frame 1: {:?} | misses={} hits={} layout_hits={}",
            frame1_time, frame1_stats.cache_misses, frame1_stats.cache_hits, frame1_stats.layout_hits);

        renderer.reset_stats();

        // 4. 第二帧：选区扩展到 (0,0)-(3,20)
        // 注意：需要重新获取 state，模拟真实场景
        let state_start = std::time::Instant::now();
        let mut state2 = terminal.state();
        let state_time = state_start.elapsed();

        state2.selection = Some(SelectionView::new(
            AbsolutePoint::new(0, 0),
            AbsolutePoint::new(3, 20),
            SelectionType::Simple,
        ));

        let render_start = std::time::Instant::now();
        for line in 0..100 {
            let _img = renderer.render_line(line, &state2);
        }
        let render_time = render_start.elapsed();
        let frame2_stats = renderer.stats.clone();

        let total_time = state_start.elapsed();

        eprintln!("Frame 2: total={:?} | state={:?} render={:?}",
            total_time, state_time, render_time);
        eprintln!("Frame 2 stats: misses={} hits={} layout_hits={}",
            frame2_stats.cache_misses, frame2_stats.cache_hits, frame2_stats.layout_hits);

        // 5. 验证
        // 第一帧应该全部 miss
        assert_eq!(frame1_stats.cache_misses, 100, "Frame 1: all lines should miss");

        // 第二帧：只有 row3 需要重绘
        assert_eq!(frame2_stats.cache_hits, 99,
            "Frame 2: 99 lines should hit cache, got {} hits {} misses {} layout_hits",
            frame2_stats.cache_hits, frame2_stats.cache_misses, frame2_stats.layout_hits);

        eprintln!("Speedup: {:.1}x (render only: {:.1}x)",
            frame1_time.as_micros() as f64 / total_time.as_micros() as f64,
            frame1_time.as_micros() as f64 / render_time.as_micros() as f64);
    }
}
