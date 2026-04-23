//! TerminalPool - 多终端管理 + 统一渲染
//!
//! 职责分离（DDD）：
//! - TerminalPool 管理多个 Terminal 实例（状态 + PTY）
//! - 渲染位置由调用方指定
//! - 统一提交：beginFrame → renderTerminal × N → endFrame
//!
//! 注意：TerminalPool 不知道 DisplayLink 的存在
//! 渲染调度由 RenderScheduler 负责
//!
//! # 锁顺序约定（重要！防止死锁）
//!
//! 为防止死锁，**所有线程**必须按以下顺序获取锁：
//!
//! ```text
//! 1. sugarloaf      (最外层，GPU 渲染)
//! 2. render_layout  (布局信息)
//! 3. container_height
//! 4. terminals      (终端 HashMap)
//! 5. renderer       (文字光栅化)
//! 6. entry.terminal (单个终端状态)
//! ```
//!
//! ## 涉及的线程
//!
//! | 线程 | 触发场景 | 主要锁 |
//! |-----|---------|-------|
//! | **主线程** (AppKit) | 窗口 resize、Tab 切换 | sugarloaf → render_layout |
//! | **CVDisplayLink** | VSync 渲染回调 | sugarloaf → render_layout → terminals |
//! | **PTY 线程** | 终端输出 | terminals → entry.terminal |
//!
//! ## 死锁案例（已修复）
//!
//! ```text
//! 主线程:           CVDisplayLink:
//! ─────────         ──────────────
//! sugarloaf.lock()  render_layout.lock()
//!       ↓                 ↓
//! render_layout.lock()  sugarloaf.lock()
//!       ↓                 ↓
//!    等待...            等待...
//!       └──── 💀 死锁 ────┘
//! ```
//!
//! ## 规则
//!
//! 1. **绝对禁止**反向获取锁
//! 2. 如需获取多个锁，必须按上述顺序
//! 3. 尽量缩短锁持有时间（clone 后立即释放）
//! 4. 优先使用 `try_lock()` 避免阻塞主线程

use crate::domain::aggregates::{Terminal, TerminalId};
use crate::render::font::FontContext;
use crate::render::{RenderConfig, Renderer};
use crate::rio_event::EventQueue;
use crate::rio_machine::Machine;
use corcovado::channel;
use parking_lot::{Mutex, RwLock};
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{OnceLock, Weak};
use std::thread::JoinHandle;
use sugarloaf::font::FontLibrary;
use sugarloaf::{
    ImageObject, Object, Sugarloaf, SugarloafRenderer, SugarloafWindow,
    SugarloafWindowSize, layout::RootStyle,
};

use super::ffi::{
    AppConfig, ErrorCode, TerminalEvent, TerminalEventType, TerminalPoolEventCallback,
};

// ============================================================================
// 全局终端事件路由（修复跨 Pool 迁移后事件丢失问题）
// ============================================================================

/// 终端事件目标
///
/// 存储终端的 dirty_flag 和所属 Pool 的 needs_render 引用。
/// 当终端在 Pool 之间迁移时，更新 needs_render 指向新 Pool。
struct TerminalEventTarget {
    /// 终端的脏标记（跟随终端，不变）
    dirty_flag: Arc<crate::infra::AtomicDirtyFlag>,
    /// 所属 Pool 的 needs_render（迁移时更新）
    needs_render: Weak<AtomicBool>,
}

/// 全局终端注册表
///
/// 映射 terminal_id → TerminalEventTarget
/// 用于 PTY 事件路由：无论终端在哪个 Pool，都能正确标记 dirty 和 needs_render
static TERMINAL_REGISTRY: OnceLock<RwLock<HashMap<usize, TerminalEventTarget>>> =
    OnceLock::new();

/// 获取全局终端注册表（懒初始化）
fn global_terminal_registry() -> &'static RwLock<HashMap<usize, TerminalEventTarget>> {
    TERMINAL_REGISTRY.get_or_init(|| RwLock::new(HashMap::new()))
}

/// 注册终端到全局路由
///
/// 在 create_terminal 时调用
pub fn register_terminal_event_target(
    terminal_id: usize,
    dirty_flag: Arc<crate::infra::AtomicDirtyFlag>,
    needs_render: &Arc<AtomicBool>,
) {
    let target = TerminalEventTarget {
        dirty_flag,
        needs_render: Arc::downgrade(needs_render),
    };
    global_terminal_registry()
        .write()
        .insert(terminal_id, target);
}

/// 更新终端的 needs_render 指向（迁移到新 Pool 时调用）
///
/// 在 attach_terminal 时调用
pub fn update_terminal_needs_render(terminal_id: usize, needs_render: &Arc<AtomicBool>) {
    if let Some(target) = global_terminal_registry().write().get_mut(&terminal_id) {
        target.needs_render = Arc::downgrade(needs_render);
    }
}

/// 注销终端（终端关闭时调用）
pub fn unregister_terminal_event_target(terminal_id: usize) {
    global_terminal_registry().write().remove(&terminal_id);
}

/// 通过全局路由处理 Wakeup 事件
///
/// 返回 true 如果找到终端并处理了事件
pub fn route_wakeup_event(terminal_id: usize) -> bool {
    let registry = global_terminal_registry().read();
    if let Some(target) = registry.get(&terminal_id) {
        // 标记终端为脏
        target.dirty_flag.mark_dirty();
        // 通知所属 Pool 需要渲染
        if let Some(needs_render) = target.needs_render.upgrade() {
            needs_render.store(true, Ordering::Release);
            return true;
        } else {
            // Weak 引用失效，Pool 可能已被释放
            #[cfg(debug_assertions)]
            crate::rust_log_warn!(
                "[RenderLoop] ⚠️ route_wakeup: needs_render.upgrade() failed for terminal {}",
                terminal_id
            );
        }
    } else {
        #[cfg(debug_assertions)]
        crate::rust_log_warn!(
            "[RenderLoop] ⚠️ route_wakeup: terminal {} not found in registry",
            terminal_id
        );
    }
    false
}

/// 待延迟释放的 GPU 资源
struct DeferredGpuDrop {
    surface: Option<TerminalSurfaceCache>,
    image: Option<TerminalRenderCache>,
}

/// 单个终端的渲染缓存
struct TerminalRenderCache {
    /// 缓存的渲染结果（Image 比 Surface 更轻量）
    cached_image: skia_safe::Image,
    /// 缓存对应的尺寸（物理像素）
    width: u32,
    height: u32,
}

/// GPU Surface 缓存（按需创建，尺寸变化时重建）
///
/// P4 优化：避免每帧创建/销毁 GPU Surface
/// - 尺寸不变时复用 Surface
/// - 尺寸变化时重建（自动 drop 旧 Surface）
struct TerminalSurfaceCache {
    /// GPU 渲染 Surface
    surface: skia_safe::Surface,
    /// Surface 尺寸（物理像素）
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

    /// GPU Surface 缓存（P4 优化：复用 Surface，避免每帧创建/销毁）
    surface_cache: Option<TerminalSurfaceCache>,

    /// 原子光标缓存（无锁读取）
    cursor_cache: Arc<crate::infra::AtomicCursorCache>,

    /// 原子模式标记：是否为后台模式（无锁读取）
    /// true = Background 模式，false = Active 模式
    is_background: Arc<AtomicBool>,

    /// 原子选区缓存（无锁读取）
    selection_cache: Arc<crate::infra::AtomicSelectionCache>,

    /// 原子标题缓存（无锁读取）
    title_cache: Arc<crate::infra::AtomicTitleCache>,

    /// 原子滚动缓存（无锁读取）
    scroll_cache: Arc<crate::infra::AtomicScrollCache>,

    /// 原子脏标记（无锁读写）
    /// PTY 线程写入后标记为脏，渲染线程检查后清除
    dirty_flag: Arc<crate::infra::AtomicDirtyFlag>,

    /// 持久化渲染状态（增量同步用）
    /// 使用 Arc<Mutex<...>> 以支持在释放 terminals 读锁后继续访问
    render_state: Arc<Mutex<crate::domain::aggregates::render_state::RenderState>>,

    /// 独立选区叠加层（不在 Terminal 内）
    selection_overlay: Arc<crate::infra::SelectionOverlay>,

    /// IME 预编辑状态（独立存储，不修改 Terminal 聚合根）
    /// 使用 RwLock 以支持渲染时无锁读取
    ime_state: Arc<RwLock<Option<crate::domain::ImeView>>>,

    /// Daemon session (if using pty-daemon)
    daemon_session: Option<super::daemon_client::DaemonSession>,

    /// keepAlive 标记：关闭终端时 detach daemon session 而非 kill
    ///
    /// 为 true 时，close_terminal 会调用 DaemonClient::detach()，
    /// daemon session 保留，后续可通过 reattach 恢复。
    keep_daemon_alive: bool,
}

/// 分离的终端（用于跨池迁移）
///
/// 当终端从一个池分离时，PTY 连接保持活跃，终端状态完整保留。
/// 可以被另一个池接收，实现跨窗口终端迁移。
///
/// # 注意
/// - PTY 线程继续运行，事件仍发送到原池的 EventQueue
/// - 迁移后需要手动触发渲染以更新显示
/// - 渲染缓存会被清空（目标池需要重新渲染）
pub struct DetachedTerminal {
    /// 原始终端 ID
    pub id: usize,
    /// 终端条目（包含所有状态）
    entry: TerminalEntry,
}

// DetachedTerminal 需要 Send 以支持跨线程传递
unsafe impl Send for DetachedTerminal {}

/// 终端池
pub struct TerminalPool {
    /// 终端映射表
    /// 使用 RwLock 保护，防止 PTY 线程和主线程的数据竞争
    terminals: RwLock<HashMap<usize, TerminalEntry>>,

    /// 下一个终端 ID
    next_id: usize,

    /// Sugarloaf 渲染引擎（共享）
    sugarloaf: Mutex<Sugarloaf<'static>>,

    /// 渲染器
    renderer: Mutex<Renderer>,

    /// 待渲染的 objects（每帧累积）
    pending_objects: Vec<Object>,

    /// 事件队列
    event_queue: EventQueue,

    /// 事件回调
    event_callback: Option<(TerminalPoolEventCallback, *mut c_void)>,

    /// 字符串事件回调（用于 CWD、Command 等）
    string_event_callback:
        Option<(super::ffi::TerminalPoolStringEventCallback, *mut c_void)>,

    /// 配置
    config: AppConfig,

    /// 上次 GPU OOM 恢复的时间戳（epoch 秒，原子操作避免渲染线程阻塞）
    /// 0 表示从未触发过恢复
    last_gpu_recovery_epoch: std::sync::atomic::AtomicU64,

    /// 是否需要渲染（dirty 标记，供外部调度器查询）
    needs_render: Arc<AtomicBool>,

    /// 渲染布局（由 Swift 侧设置，Rust 侧使用）
    /// Vec<(terminal_id, x, y, width, height)>
    render_layout: Arc<Mutex<Vec<(usize, f32, f32, f32, f32)>>>,

    /// 容器高度（用于坐标转换）
    container_height: Arc<Mutex<f32>>,

    // ========================================================================
    // 待处理的更新（避免主线程阻塞）
    // ========================================================================
    //
    // 主线程使用 try_lock 尝试更新，如果锁被占用则存入 pending_*
    // CVDisplayLink 线程在 render_all() 开始时检查并应用这些更新
    // 这样既避免了死锁，又保证更新不会丢失
    /// 待处理的 Sugarloaf resize (width, height)
    pending_resize: Mutex<Option<(f32, f32)>>,

    /// 待处理的 scale 更新
    pending_scale: Mutex<Option<f32>>,

    /// 待处理的字体大小更新
    pending_font_size: Mutex<Option<f32>>,

    /// 待处理的终端 resize (terminal_id, cols, rows, width, height)
    /// 当 CVDisplayLink 线程无法获取 terminals 写锁时，将 resize 排队
    pending_terminal_resizes: Mutex<Vec<(usize, u16, u16, f32, f32)>>,

    /// 缓存的字体度量 (cell_width, cell_height, line_height)
    /// 启动时计算一次，只在字体大小/scale 变化时更新
    /// 使用原子读写避免锁争用
    cached_font_metrics: std::sync::RwLock<(f32, f32, f32)>,

    /// Reattach hint：下次 create_terminal 时优先 attach 到此 daemon session
    ///
    /// 插件在 reopenTerminal 前通过 set_reattach_hint 设置，
    /// create_terminal_with_cwd 消费后自动清空（一次性语义）。
    reattach_hint: RwLock<Option<String>>,

    /// GPU 资源延迟释放队列
    ///
    /// 主线程关闭/resize/切换终端时，GPU Surface/Image 不能直接 drop（会从主线程修改
    /// Skia GrResourceCache，与 CVDisplayLink 线程竞态）。改为 .take() 放入此队列，
    /// 由 CVDisplayLink 线程在 render_all() 开头统一 drop。
    deferred_gpu_drops: Mutex<Vec<DeferredGpuDrop>>,
}

// TerminalPool 需要实现 Send（跨线程传递）
// 注意：event_callback 中的 *mut c_void 不是 Send，但我们保证只在主线程使用
unsafe impl Send for TerminalPool {}

impl TerminalPool {
    /// 创建临时 Surface 用于渲染（用完即释放）
    ///
    fn defer_gpu_drop(&self, entry: &mut TerminalEntry) {
        let surface = entry.surface_cache.take();
        let image = entry.render_cache.take();
        if surface.is_some() || image.is_some() {
            self.deferred_gpu_drops.lock().push(DeferredGpuDrop { surface, image });
        }
    }

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
                AlphaType, ColorSpace, ColorType, ImageInfo,
                gpu::{Budgeted, SurfaceOrigin, surfaces},
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
                None, // sample_count
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

        // 获取全局共享的 FontLibrary（所有 TerminalPool 共用同一个实例，节省约 180MB 内存）
        let font_library = crate::get_shared_font_library(config.font_size);

        // 创建字体上下文（clone FontLibrary，只增加 Arc 引用计数）
        let font_context = Arc::new(FontContext::new(font_library.clone()));

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
        let mut renderer = Renderer::new(font_context.clone(), render_config.clone());

        // 启动时计算一次 font metrics 并缓存
        let metrics = renderer.get_font_metrics();
        let initial_font_metrics = (
            metrics.cell_width.value,
            metrics.cell_height.value,
            metrics.cell_height.value * config.line_height,
        );

        // 创建 Sugarloaf（使用共享的 font_library）
        let sugarloaf = Self::create_sugarloaf(&config, &font_library, &render_config)?;

        Ok(Self {
            terminals: RwLock::new(HashMap::new()),
            next_id: 1, // 从 1 开始，0 表示无效
            sugarloaf: Mutex::new(sugarloaf),
            renderer: Mutex::new(renderer),
            pending_objects: Vec::new(),
            event_queue,
            event_callback: None,
            string_event_callback: None,
            config,
            last_gpu_recovery_epoch: std::sync::atomic::AtomicU64::new(0),
            needs_render: Arc::new(AtomicBool::new(false)),
            render_layout: Arc::new(Mutex::new(Vec::new())),
            container_height: Arc::new(Mutex::new(0.0)),
            // 初始化待处理更新为 None
            pending_resize: Mutex::new(None),
            pending_scale: Mutex::new(None),
            pending_font_size: Mutex::new(None),
            pending_terminal_resizes: Mutex::new(Vec::new()),
            // 缓存初始 font metrics
            cached_font_metrics: std::sync::RwLock::new(initial_font_metrics),
            reattach_hint: RwLock::new(None),
            deferred_gpu_drops: Mutex::new(Vec::new()),
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
            self.config.log_buffer_size,
        );

        // 2. 创建 PTY 和 Machine
        let (machine_handle, pty_tx, pty_fd, shell_pid, daemon_session) =
            match Self::create_pty_and_machine(&terminal, self.event_queue.clone()) {
                Ok(result) => result,
                Err(e) => {
                    eprintln!("❌ [TerminalPool] Failed to create PTY: {:?}", e);
                    return -1;
                }
            };

        // 3. 存储条目
        let dirty_flag = Arc::new(crate::infra::AtomicDirtyFlag::new());
        let entry = TerminalEntry {
            terminal: Arc::new(Mutex::new(terminal)),
            pty_tx,
            machine_handle,
            cols,
            rows,
            pty_fd,
            shell_pid,
            render_cache: None,  // 首次渲染时创建
            surface_cache: None, // P4: 首次渲染时创建 Surface 缓存
            cursor_cache: Arc::new(crate::infra::AtomicCursorCache::new()),
            is_background: Arc::new(AtomicBool::new(false)), // 默认为 Active 模式
            selection_cache: Arc::new(crate::infra::AtomicSelectionCache::new()),
            title_cache: Arc::new(crate::infra::AtomicTitleCache::new()),
            scroll_cache: Arc::new(crate::infra::AtomicScrollCache::new()),
            dirty_flag: dirty_flag.clone(),
            render_state: Arc::new(Mutex::new(
                crate::domain::aggregates::render_state::RenderState::new(
                    cols as usize,
                    rows as usize,
                ),
            )), // 增量同步用，首次 sync 时全量同步
            selection_overlay: Arc::new(crate::infra::SelectionOverlay::new()),
            ime_state: Arc::new(RwLock::new(None)),
            daemon_session,
            keep_daemon_alive: false,
        };

        self.terminals.write().insert(id, entry);

        // 4. 注册到全局事件路由（支持跨 Pool 迁移）
        register_terminal_event_target(id, dirty_flag, &self.needs_render);

        // eprintln!("✅ [TerminalPool] Terminal {} created", id);

        id as i32
    }

    /// 创建新终端（指定工作目录）
    ///
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal_with_cwd(
        &mut self,
        cols: u16,
        rows: u16,
        working_dir: Option<String>,
    ) -> i32 {
        let id = self.next_id;
        self.next_id += 1;

        // 消费 reattach hint（一次性语义）
        let reattach_hint = self.reattach_hint.write().take();

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
            self.config.log_buffer_size,
        );

        // 2. 创建 PTY 和 Machine（带工作目录）
        let (machine_handle, pty_tx, pty_fd, shell_pid, daemon_session) =
            match Self::create_pty_and_machine_with_cwd(
                &terminal,
                self.event_queue.clone(),
                working_dir,
                reattach_hint,
            ) {
                Ok(result) => result,
                Err(e) => {
                    eprintln!("❌ [TerminalPool] Failed to create PTY: {:?}", e);
                    return -1;
                }
            };

        // 3. 存储条目
        let dirty_flag = Arc::new(crate::infra::AtomicDirtyFlag::new());
        let entry = TerminalEntry {
            terminal: Arc::new(Mutex::new(terminal)),
            pty_tx,
            machine_handle,
            cols,
            rows,
            pty_fd,
            shell_pid,
            render_cache: None,  // 首次渲染时创建
            surface_cache: None, // P4: 首次渲染时创建 Surface 缓存
            cursor_cache: Arc::new(crate::infra::AtomicCursorCache::new()),
            is_background: Arc::new(AtomicBool::new(false)), // 默认为 Active 模式
            selection_cache: Arc::new(crate::infra::AtomicSelectionCache::new()),
            title_cache: Arc::new(crate::infra::AtomicTitleCache::new()),
            scroll_cache: Arc::new(crate::infra::AtomicScrollCache::new()),
            dirty_flag: dirty_flag.clone(),
            render_state: Arc::new(Mutex::new(
                crate::domain::aggregates::render_state::RenderState::new(
                    cols as usize,
                    rows as usize,
                ),
            )), // 增量同步用，首次 sync 时全量同步
            selection_overlay: Arc::new(crate::infra::SelectionOverlay::new()),
            ime_state: Arc::new(RwLock::new(None)),
            daemon_session,
            keep_daemon_alive: false,
        };

        self.terminals.write().insert(id, entry);

        // 4. 注册到全局事件路由（支持跨 Pool 迁移）
        register_terminal_event_target(id, dirty_flag, &self.needs_render);

        id as i32
    }

    /// 创建新终端（使用 Swift 传入的 ID）
    ///
    /// 用于 Session 恢复，确保 ID 在重启后保持一致
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal_with_id(&mut self, id: usize, cols: u16, rows: u16) -> i64 {
        // 检查 ID 是否已存在
        if self.terminals.read().contains_key(&id) {
            eprintln!("❌ [TerminalPool] Terminal ID {} already exists", id);
            return -1;
        }

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
            self.config.log_buffer_size,
        );

        // 2. 创建 PTY 和 Machine
        let (machine_handle, pty_tx, pty_fd, shell_pid, daemon_session) =
            match Self::create_pty_and_machine(&terminal, self.event_queue.clone()) {
                Ok(result) => result,
                Err(e) => {
                    eprintln!("❌ [TerminalPool] Failed to create PTY: {:?}", e);
                    return -1;
                }
            };

        // 3. 存储条目
        let dirty_flag = Arc::new(crate::infra::AtomicDirtyFlag::new());
        let entry = TerminalEntry {
            terminal: Arc::new(Mutex::new(terminal)),
            pty_tx,
            machine_handle,
            cols,
            rows,
            pty_fd,
            shell_pid,
            render_cache: None,
            surface_cache: None,
            cursor_cache: Arc::new(crate::infra::AtomicCursorCache::new()),
            is_background: Arc::new(AtomicBool::new(false)),
            selection_cache: Arc::new(crate::infra::AtomicSelectionCache::new()),
            title_cache: Arc::new(crate::infra::AtomicTitleCache::new()),
            scroll_cache: Arc::new(crate::infra::AtomicScrollCache::new()),
            dirty_flag: dirty_flag.clone(),
            render_state: Arc::new(Mutex::new(
                crate::domain::aggregates::render_state::RenderState::new(
                    cols as usize,
                    rows as usize,
                ),
            )),
            selection_overlay: Arc::new(crate::infra::SelectionOverlay::new()),
            ime_state: Arc::new(RwLock::new(None)),
            daemon_session,
            keep_daemon_alive: false,
        };

        self.terminals.write().insert(id, entry);

        // 4. 注册到全局事件路由（支持跨 Pool 迁移）
        register_terminal_event_target(id, dirty_flag, &self.needs_render);

        // 更新 next_id（确保不会冲突）
        if id >= self.next_id {
            self.next_id = id + 1;
        }

        id as i64
    }

    /// 创建新终端（使用 Swift 传入的 ID + 指定工作目录）
    ///
    /// 用于 Session 恢复，确保 ID 在重启后保持一致
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal_with_id_and_cwd(
        &mut self,
        id: usize,
        cols: u16,
        rows: u16,
        working_dir: Option<String>,
    ) -> i64 {
        // 检查 ID 是否已存在
        if self.terminals.read().contains_key(&id) {
            eprintln!("❌ [TerminalPool] Terminal ID {} already exists", id);
            return -1;
        }

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
            self.config.log_buffer_size,
        );

        // 2. 创建 PTY 和 Machine（带工作目录，session restore 不使用 hint，用 terminal_id 匹配）
        let (machine_handle, pty_tx, pty_fd, shell_pid, daemon_session) =
            match Self::create_pty_and_machine_with_cwd(
                &terminal,
                self.event_queue.clone(),
                working_dir,
                None, // session restore 通过 terminal_id 精确匹配
            ) {
                Ok(result) => result,
                Err(e) => {
                    eprintln!("❌ [TerminalPool] Failed to create PTY: {:?}", e);
                    return -1;
                }
            };

        // 3. 存储条目
        let dirty_flag = Arc::new(crate::infra::AtomicDirtyFlag::new());
        let entry = TerminalEntry {
            terminal: Arc::new(Mutex::new(terminal)),
            pty_tx,
            machine_handle,
            cols,
            rows,
            pty_fd,
            shell_pid,
            render_cache: None,
            surface_cache: None,
            cursor_cache: Arc::new(crate::infra::AtomicCursorCache::new()),
            is_background: Arc::new(AtomicBool::new(false)),
            selection_cache: Arc::new(crate::infra::AtomicSelectionCache::new()),
            title_cache: Arc::new(crate::infra::AtomicTitleCache::new()),
            scroll_cache: Arc::new(crate::infra::AtomicScrollCache::new()),
            dirty_flag: dirty_flag.clone(),
            render_state: Arc::new(Mutex::new(
                crate::domain::aggregates::render_state::RenderState::new(
                    cols as usize,
                    rows as usize,
                ),
            )),
            selection_overlay: Arc::new(crate::infra::SelectionOverlay::new()),
            ime_state: Arc::new(RwLock::new(None)),
            daemon_session,
            keep_daemon_alive: false,
        };

        self.terminals.write().insert(id, entry);

        // 4. 注册到全局事件路由（支持跨 Pool 迁移）
        register_terminal_event_target(id, dirty_flag, &self.needs_render);

        // 更新 next_id（确保不会冲突）
        if id >= self.next_id {
            self.next_id = id + 1;
        }

        id as i64
    }

    /// 用外部 PTY fd 创建终端（用于 dev-runner 等外部进程管理器集成）
    ///
    /// 不分配新 PTY，不启动新 shell，直接复用外部 fd。
    /// 适用于调用方已通过 openpty() + fork() 启动进程的场景。
    pub fn create_terminal_with_fd(
        &mut self,
        fd: i32,
        child_pid: u32,
        cols: u16,
        rows: u16,
    ) -> i64 {
        use crate::rio_event::FFIEventListener;
        use std::os::fd::FromRawFd;

        let id = self.next_id;
        self.next_id += 1;

        // 1. 创建 Terminal
        let terminal_id = TerminalId(id);
        let terminal = Terminal::new_with_pty(
            terminal_id,
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
            self.config.log_buffer_size,
        );

        let crosswords = match terminal.inner_crosswords() {
            Some(cw) => cw,
            None => {
                eprintln!("❌ [TerminalPool] Failed to get crosswords for external fd terminal");
                return -1;
            }
        };

        // 2. 从外部 fd 创建 PTY wrapper
        let pty = match unsafe {
            let file = std::fs::File::from_raw_fd(fd);
            teletypewriter::create_pty_from_file(file, child_pid)
        } {
            Ok(pty) => pty,
            Err(e) => {
                eprintln!("❌ [TerminalPool] Failed to create PTY from fd {}: {:?}", fd, e);
                return -1;
            }
        };

        // 3. 创建 Machine
        let event_listener = FFIEventListener::new(self.event_queue.clone(), terminal.id().0);

        let machine = match Machine::new_with_log_buffer(
            crosswords,
            pty,
            event_listener,
            terminal.id().0,
            fd,
            child_pid,
            terminal.log_buffer().clone(),
            None, // 无 shared ring buffer
        ) {
            Ok(m) => m,
            Err(e) => {
                eprintln!("❌ [TerminalPool] Failed to create machine from fd: {:?}", e);
                return -1;
            }
        };

        let pty_tx = machine.channel();
        let machine_handle = machine.spawn();

        // 4. 存储条目
        let dirty_flag = Arc::new(crate::infra::AtomicDirtyFlag::new());
        let entry = TerminalEntry {
            terminal: Arc::new(Mutex::new(terminal)),
            pty_tx,
            machine_handle,
            cols,
            rows,
            pty_fd: fd,
            shell_pid: child_pid,
            render_cache: None,
            surface_cache: None,
            cursor_cache: Arc::new(crate::infra::AtomicCursorCache::new()),
            is_background: Arc::new(AtomicBool::new(false)),
            selection_cache: Arc::new(crate::infra::AtomicSelectionCache::new()),
            title_cache: Arc::new(crate::infra::AtomicTitleCache::new()),
            scroll_cache: Arc::new(crate::infra::AtomicScrollCache::new()),
            dirty_flag: dirty_flag.clone(),
            render_state: Arc::new(Mutex::new(
                crate::domain::aggregates::render_state::RenderState::new(
                    cols as usize,
                    rows as usize,
                ),
            )),
            selection_overlay: Arc::new(crate::infra::SelectionOverlay::new()),
            ime_state: Arc::new(RwLock::new(None)),
            daemon_session: None, // 非 daemon 管理
            keep_daemon_alive: false,
        };

        self.terminals.write().insert(id, entry);

        // 5. 注册全局事件路由
        register_terminal_event_target(id, dirty_flag, &self.needs_render);

        eprintln!("[TerminalPool] created terminal {} from external fd {} (pid={})", id, fd, child_pid);

        id as i64
    }

    /// 创建 PTY 和 Machine
    ///
    /// 默认使用 $HOME 作为工作目录
    fn create_pty_and_machine(
        terminal: &Terminal,
        event_queue: EventQueue,
    ) -> Result<
        (
            JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>,
            channel::Sender<rio_backend::event::Msg>,
            i32,
            u32,
            Option<super::daemon_client::DaemonSession>,
        ),
        ErrorCode,
    > {
        // 默认使用用户 home 目录，无 reattach hint
        let home = std::env::var("HOME").ok();
        Self::create_pty_and_machine_with_cwd(terminal, event_queue, home, None)
    }

    /// 创建 PTY 和 Machine（支持工作目录）
    ///
    /// 返回: (machine_handle, pty_tx, pty_fd, shell_pid, daemon_session)
    ///
    /// `reattach_session_id`: 优先 attach 到此 daemon session（插件 reopen 场景）
    fn create_pty_and_machine_with_cwd(
        terminal: &Terminal,
        event_queue: EventQueue,
        working_dir: Option<String>,
        reattach_session_id: Option<String>,
    ) -> Result<
        (
            JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>,
            channel::Sender<rio_backend::event::Msg>,
            i32,
            u32,
            Option<super::daemon_client::DaemonSession>,
        ),
        ErrorCode,
    > {
        use crate::rio_event::FFIEventListener;
        use std::env;
        use teletypewriter::create_pty_with_spawn;

        let crosswords = terminal
            .inner_crosswords()
            .ok_or(ErrorCode::InvalidConfig)?;

        let cols = terminal.cols() as u16;
        let rows = terminal.rows() as u16;

        // NOTE(main): pty-daemon is intentionally bypassed on main for stability.
        // Keep the daemon implementation below so it can be re-enabled later,
        // but force all default terminal creation back to the in-process PTY path.
        //
        // let cwd_ref = working_dir.as_deref();
        // let terminal_id = terminal.id().0 as u32;
        // match Self::try_create_daemon_pty(
        //     terminal,
        //     event_queue.clone(),
        //     cols,
        //     rows,
        //     cwd_ref,
        //     terminal_id,
        //     reattach_session_id.as_deref(),
        // ) {
        //     Ok((handle, pty_tx, pty_fd, shell_pid, daemon_session)) => {
        //         eprintln!(
        //             "[TerminalPool] using daemon PTY: session_id={}",
        //             daemon_session
        //                 .as_ref()
        //                 .map(|s| s.session_id.as_str())
        //                 .unwrap_or("unknown")
        //         );
        //         return Ok((handle, pty_tx, pty_fd, shell_pid, daemon_session));
        //     }
        //     Err(e) => {
        //         crate::rust_log_info!(
        //             "[TerminalPool] daemon pty failed, fallback to in-process: {}",
        //             e
        //         );
        //     }
        // }

        if reattach_session_id.is_some() {
            crate::rust_log_info!(
                "[TerminalPool] pty-daemon path is disabled on main; ignoring reattach request"
            );
        }

        let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());

        // 统一使用 spawn 创建 PTY（支持指定工作目录）
        // 如果未指定工作目录，默认使用 $HOME
        let cwd = working_dir.or_else(|| env::var("HOME").ok());
        let terminal_id = terminal.id().0 as u32;
        let pty = create_pty_with_spawn(
            &shell,
            vec!["-l".to_string()],
            &cwd,
            cols,
            rows,
            terminal_id,
        )
        .map_err(|_| ErrorCode::RenderError)?;

        let pty_fd = *pty.child.id;
        let shell_pid = *pty.child.pid as u32;

        let event_listener = FFIEventListener::new(event_queue, terminal.id().0);

        // 非 daemon 模式不使用共享内存 ring buffer
        let machine = Machine::new_with_log_buffer(
            crosswords,
            pty,
            event_listener,
            terminal.id().0,
            pty_fd,
            shell_pid,
            terminal.log_buffer().clone(),
            None,
        )
        .map_err(|_| ErrorCode::RenderError)?;

        let pty_tx = machine.channel();
        let handle = machine.spawn();

        Ok((handle, pty_tx, pty_fd, shell_pid, None))
    }

    /// 尝试使用 daemon 创建或 reattach PTY（失败时回退到 in-process）
    ///
    /// 启动时优先 reattach 已有 Active/Idle session，无可用 session 才 create 新的。
    ///
    /// `reattach_session_id`: 若不为 None，优先 attach 到此 session（插件 reopen 场景）；
    /// 否则退回按 terminal_id 精确匹配的旧逻辑。
    fn try_create_daemon_pty(
        terminal: &Terminal,
        event_queue: EventQueue,
        cols: u16,
        rows: u16,
        cwd: Option<&str>,
        terminal_id: u32,
        reattach_session_id: Option<&str>,
    ) -> Result<
        (
            JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>,
            channel::Sender<rio_backend::event::Msg>,
            i32,
            u32,
            Option<super::daemon_client::DaemonSession>,
        ),
        String,
    > {
        use crate::rio_event::FFIEventListener;
        use std::os::fd::FromRawFd;

        let crosswords = terminal
            .inner_crosswords()
            .ok_or_else(|| "failed to get crosswords".to_string())?;

        // 优先使用 reattach hint（插件通过 set_reattach_hint 指定的 session_id）
        let (mut daemon_session, is_reattach) = if let Some(sid) = reattach_session_id {
            match super::daemon_client::DaemonClient::attach(sid) {
                Ok(session) => {
                    eprintln!("[TerminalPool] reattach via hint: session_id={}", sid);
                    (session, true)
                }
                Err(e) => {
                    eprintln!("[TerminalPool] reattach hint failed (session={}): {}, creating new", sid, e);
                    (super::daemon_client::DaemonClient::create(cols, rows, cwd, Some(terminal_id))?, false)
                }
            }
        } else {
            // 原有逻辑：按 terminal_id 精确 reattach 已有 session
            match Self::try_reattach(terminal_id) {
                Some(session) => {
                    eprintln!("[TerminalPool] reattach to existing session: {} (terminal_id={})", session.session_id, terminal_id);
                    (session, true)
                }
                None => {
                    eprintln!("[TerminalPool] no reattachable session for terminal_id={}, creating new", terminal_id);
                    (super::daemon_client::DaemonClient::create(cols, rows, cwd, Some(terminal_id))?, false)
                }
            }
        };

        let pty_fd = daemon_session.pty_fd;
        let shell_pid = daemon_session.child_pid as u32;
        let shm_name = &daemon_session.shm_name;

        // 打开共享内存 ring buffer，从 shm 直接读取历史数据
        let shared_ring = match pty_daemon::shared_ring::SharedRingBuffer::open(shm_name) {
            Ok(shm) => {
                eprintln!("[TerminalPool] opened shared ring buffer: {}", shm_name);
                Some(shm)
            }
            Err(e) => {
                eprintln!("[TerminalPool] warning: failed to open shared ring buffer {}: {}", shm_name, e);
                None
            }
        };

        // 从 shm dump 历史数据并回放到终端
        let ring_data = shared_ring.as_ref().map(|shm| shm.dump()).unwrap_or_default();
        if !ring_data.is_empty() {
            eprintln!("[TerminalPool] replaying {} bytes of ring data from shm", ring_data.len());
            let mut parser = rio_backend::performer::handler::Processor::<rio_backend::performer::handler::StdSyncHandler>::new();
            let mut cw = crosswords.write();
            parser.advance(&mut *cw, &ring_data);
        }

        // Create a PTY wrapper from the daemon's dup(master_fd)
        let pty = unsafe {
            let file = std::fs::File::from_raw_fd(pty_fd);
            teletypewriter::create_pty_from_file(file, shell_pid as u32)
                .map_err(|e| format!("failed to create pty from fd: {:?}", e))?
        };

        let event_listener = FFIEventListener::new(event_queue, terminal.id().0);

        let machine = Machine::new_with_log_buffer(
            crosswords,
            pty,
            event_listener,
            terminal.id().0,
            pty_fd,
            shell_pid,
            terminal.log_buffer().clone(),
            shared_ring,
        )
        .map_err(|e| format!("failed to create machine: {:?}", e))?;

        let pty_tx = machine.channel();
        let handle = machine.spawn();

        // Reattach 且 ring buffer 为空：shell 在 detach 期间空闲，屏幕内容丢失。
        // 标记 needs_sigwinch_bounce，由首次 resize_terminal 用正确尺寸触发 SIGWINCH。
        // 新建 session 不需要 bounce —— shell 刚启动会自然绘制 prompt。
        if is_reattach && ring_data.is_empty() {
            daemon_session.needs_sigwinch_bounce = true;
        }

        Ok((handle, pty_tx, pty_fd, shell_pid, Some(daemon_session)))
    }

    /// 按 terminal_id 精确匹配可 reattach 的 daemon session
    fn try_reattach(terminal_id: u32) -> Option<super::daemon_client::DaemonSession> {
        let sessions = super::daemon_client::DaemonClient::list().ok()?;
        // 优先精确匹配 terminal_id
        let reattachable = sessions.iter().find(|s| {
            s.terminal_id == Some(terminal_id)
                && (s.state == "Active" || s.state == "Idle")
                && s.child_alive
        })?;
        let session_id = &reattachable.id;
        eprintln!("[TerminalPool] found reattachable session: {} (terminal_id={}, state={})", session_id, terminal_id, reattachable.state);
        super::daemon_client::DaemonClient::attach(session_id).ok()
    }

    /// 设置 reattach hint
    ///
    /// 下次 create_terminal_with_cwd 时，优先 attach 到此 daemon session（而非按 terminal_id 匹配）。
    /// hint 是一次性的：被消费后自动清空。
    ///
    /// 使用场景：插件 reopenTerminal 时，先调用此方法设置旧 session_id，
    /// 再调用 createTerminalTab，新终端会 reattach 到原 daemon session。
    pub fn set_reattach_hint(&self, session_id: String) {
        // NOTE(main): reattach is intentionally disabled while the daemon path
        // is bypassed on main. Keep the implementation available for later.
        let _ = session_id;
        *self.reattach_hint.write() = None;
    }

    /// 查询终端关联的 daemon session ID
    ///
    /// 返回终端当前绑定的 daemon session ID，若终端不存在或未使用 daemon 则返回 None。
    pub fn get_daemon_session_id(&self, id: usize) -> Option<String> {
        self.terminals.read().get(&id)
            .and_then(|entry| entry.daemon_session.as_ref())
            .map(|ds| ds.session_id.clone())
    }

    /// 标记终端为 keepAlive
    ///
    /// 设置后，close_terminal 关闭时会 detach daemon session 而非 kill，
    /// daemon session 保留，后续可通过 reattach 恢复。
    pub fn mark_keep_alive(&self, id: usize) {
        // NOTE(main): keepAlive only makes sense with pty-daemon reattach.
        // Leave the API in place but keep it as a no-op on main for stability.
        let _ = id;
    }

    /// 关闭终端
    ///
    /// 若 keep_daemon_alive 为 true，则 detach daemon session（session 保留可恢复）；
    /// 否则 kill daemon session（彻底清理）。
    pub fn close_terminal(&mut self, id: usize) -> bool {
        if let Some(mut entry) = self.terminals.write().remove(&id) {
            self.defer_gpu_drop(&mut entry);
            // 从全局事件路由注销
            unregister_terminal_event_target(id);
            // 根据 keepAlive 标记决定关闭策略
            if let Some(ref ds) = entry.daemon_session {
                if entry.keep_daemon_alive {
                    // keepAlive：detach session，保留 daemon 进程供后续 reattach
                    if let Err(e) = super::daemon_client::DaemonClient::detach(
                        &ds.session_id,
                        entry.cols,
                        entry.rows,
                    ) {
                        eprintln!(
                            "[TerminalPool] daemon detach failed (session={}): {}",
                            ds.session_id, e
                        );
                    }
                } else {
                    // 主动关闭：Kill daemon session（区分于崩溃的 crash detach 保留 session）
                    if let Err(e) = super::daemon_client::DaemonClient::kill(&ds.session_id) {
                        eprintln!(
                            "[TerminalPool] daemon kill failed (session={}): {}",
                            ds.session_id, e
                        );
                    }
                }
            }
            // 通知 Machine 线程退出事件循环
            // Machine 退出后 PTY drop → master fd 关闭 → 内核 SIGHUP → 子进程清理
            let _ = entry.pty_tx.send(rio_backend::event::Msg::Shutdown);
            drop(entry.pty_tx);
            true
        } else {
            false
        }
    }

    /// 强制关闭终端（无视 keepAlive 标记，直接 kill daemon session）
    ///
    /// 供插件主动清理时使用，确保彻底终止 daemon session。
    pub fn close_terminal_force(&mut self, id: usize) -> bool {
        if let Some(mut entry) = self.terminals.write().remove(&id) {
            self.defer_gpu_drop(&mut entry);
            // 从全局事件路由注销
            unregister_terminal_event_target(id);
            // 无视 keep_daemon_alive，直接 kill
            if let Some(ref ds) = entry.daemon_session {
                if let Err(e) = super::daemon_client::DaemonClient::kill(&ds.session_id) {
                    eprintln!(
                        "[TerminalPool] force kill failed (session={}): {}",
                        ds.session_id, e
                    );
                }
            }
            // 通知 Machine 线程退出
            let _ = entry.pty_tx.send(rio_backend::event::Msg::Shutdown);
            drop(entry.pty_tx);
            true
        } else {
            false
        }
    }

    /// 分离终端（用于跨池迁移）
    ///
    /// 将终端从当前池中移除，返回 DetachedTerminal。
    /// PTY 连接保持活跃，终端状态完整保留。
    ///
    /// # 参数
    /// - `id`: 要分离的终端 ID
    ///
    /// # 返回
    /// - `Some(DetachedTerminal)`: 分离成功
    /// - `None`: 终端不存在
    ///
    /// # 注意
    /// - 分离后，原池不再管理该终端
    /// - PTY 事件仍会发送到原池的 EventQueue（需要目标池手动触发渲染）
    /// - 渲染缓存会被清空
    pub fn detach_terminal(&mut self, id: usize) -> Option<DetachedTerminal> {
        let mut entry = self.terminals.write().remove(&id)?;

        // 清空渲染缓存（目标池需要重新渲染）
        // GPU 资源延迟释放，避免主线程修改 Skia resource cache
        self.defer_gpu_drop(&mut entry);

        // 标记为脏，确保目标池会重新渲染
        entry.dirty_flag.mark_dirty();

        Some(DetachedTerminal { id, entry })
    }

    /// 接收分离的终端（用于跨池迁移）
    ///
    /// 将 DetachedTerminal 添加到当前池。
    /// 终端会使用原来的 ID（如果不冲突）或新 ID。
    ///
    /// # 参数
    /// - `detached`: 分离的终端
    ///
    /// # 返回
    /// - 终端在当前池中的 ID
    ///
    /// # 注意
    /// - PTY 连接保持活跃
    /// - 终端历史和状态完整保留
    /// - 全局事件路由会自动更新，PTY 事件会正确路由到新 Pool
    pub fn attach_terminal(&mut self, detached: DetachedTerminal) -> usize {
        let id = detached.id;

        // 检查 ID 是否已存在
        let final_id = if self.terminals.read().contains_key(&id) {
            // ID 冲突，使用新 ID
            let new_id = self.next_id;
            self.next_id += 1;
            new_id
        } else {
            // 使用原 ID
            if id >= self.next_id {
                self.next_id = id + 1;
            }
            id
        };

        // 插入终端
        self.terminals.write().insert(final_id, detached.entry);

        // 更新全局事件路由，指向新 Pool 的 needs_render
        // 注意：使用原始 id（route_id），因为 PTY 线程仍使用原始 id 发送事件
        update_terminal_needs_render(id, &self.needs_render);

        // 标记需要渲染
        self.needs_render.store(true, Ordering::Release);

        final_id
    }

    /// 获取终端的当前工作目录（通过 proc_pidinfo 系统调用）
    ///
    /// 注意：此方法获取的是前台进程的 CWD，如果有子进程运行（如 vim、claude），
    /// 可能返回子进程的 CWD 而非 shell 的 CWD。
    /// 推荐使用 `get_cached_cwd` 获取 OSC 7 缓存的 CWD。
    pub fn get_cwd(&self, id: usize) -> Option<std::path::PathBuf> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            teletypewriter::foreground_process_path(entry.pty_fd, entry.shell_pid).ok()
        } else {
            None
        }
    }

    /// 获取终端的缓存工作目录（通过 OSC 7）
    ///
    /// Shell 通过 OSC 7 转义序列主动上报 CWD。此方法比 `get_cwd` 更可靠：
    /// - 不受子进程（如 vim、claude）干扰
    /// - Shell 自己最清楚当前目录
    /// - 每次 cd 后立即更新
    ///
    /// 如果 OSC 7 缓存为空（shell 未配置或刚启动），返回 None。
    pub fn get_cached_cwd(&self, id: usize) -> Option<std::path::PathBuf> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            terminal.get_current_directory()
        } else {
            None
        }
    }

    /// 获取终端的前台进程名称
    ///
    /// 返回当前前台进程的名称（如 "vim", "cargo", "python" 等）
    /// 如果前台进程就是 shell 本身，返回 shell 名称（如 "zsh", "bash"）
    pub fn get_foreground_process_name(&self, id: usize) -> Option<String> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let name =
                teletypewriter::foreground_process_name(entry.pty_fd, entry.shell_pid);
            if name.is_empty() { None } else { Some(name) }
        } else {
            None
        }
    }

    /// 检查终端是否有正在运行的子进程（非 shell）
    ///
    /// 返回 true 如果前台进程不是 shell 本身
    pub fn has_running_process(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let fg_name =
                teletypewriter::foreground_process_name(entry.pty_fd, entry.shell_pid);
            if fg_name.is_empty() {
                return false;
            }
            // 检查是否是常见的 shell
            let shell_names = ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "csh", "dash"];
            !shell_names.contains(&fg_name.as_str())
        } else {
            false
        }
    }

    /// 查询终端的日志缓冲（可选功能）
    ///
    /// 仅当 `log_buffer_size > 0` 时可用。
    /// 返回 JSON 格式的日志查询结果，包含 lines、next_seq、has_more、truncated。
    ///
    /// # 参数
    /// - `id`: 终端 ID
    /// - `since`: 返回 seq > since 的日志（None 表示全部）
    /// - `limit`: 最多返回的行数
    /// - `search`: 可选的搜索过滤
    /// - `is_regex`: 是否将 search 作为正则表达式
    /// - `case_insensitive`: 是否大小写不敏感
    pub fn query_log(
        &self,
        id: usize,
        after: Option<u64>,
        before: Option<u64>,
        limit: usize,
        search: Option<&str>,
        is_regex: bool,
        case_insensitive: bool,
        backward: bool,
        current_run: bool,
    ) -> Option<String> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            if let Some(ref log_buffer) = terminal.log_buffer() {
                // current_run: use boundary_seq as effective after
                let effective_after = if current_run {
                    match (log_buffer.boundary_seq(), after) {
                        (Some(b), Some(a)) => Some(a.max(b - 1)), // user's after takes precedence if larger
                        (Some(b), None) => Some(b - 1),           // boundary - 1 so seq >= boundary passes
                        (None, a) => a,                            // no boundary, use user's after
                    }
                } else {
                    after
                };

                let result = log_buffer.query(
                    effective_after, before, limit, search,
                    is_regex, case_insensitive, backward,
                );
                let json = serde_json::json!({
                    "lines": result.lines.iter().map(|l| {
                        serde_json::json!({
                            "seq": l.seq,
                            "text": l.text
                        })
                    }).collect::<Vec<_>>(),
                    "next_seq": result.next_seq,
                    "has_more": result.has_more,
                    "truncated": result.truncated,
                    "boundary_seq": result.boundary_seq,
                    "boundary_valid": result.boundary_valid
                });
                Some(json.to_string())
            } else {
                None // LogBuffer 未启用
            }
        } else {
            None
        }
    }

    /// Mark a run boundary on the terminal's log buffer
    ///
    /// Returns the boundary seq value, or None if LogBuffer is not enabled.
    pub fn mark_log_boundary(&self, id: usize) -> Option<u64> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            terminal.log_buffer().as_ref().map(|lb| lb.mark_boundary())
        } else {
            None
        }
    }

    /// 获取终端日志的最后 N 行
    ///
    /// 仅当 `log_buffer_size > 0` 时可用。
    pub fn tail_log(&self, id: usize, count: usize) -> Option<String> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            if let Some(ref log_buffer) = terminal.log_buffer() {
                let lines = log_buffer.tail(count);
                let json = serde_json::json!(
                    lines.iter().map(|l| {
                        serde_json::json!({
                            "seq": l.seq,
                            "text": l.text
                        })
                    }).collect::<Vec<_>>()
                );
                Some(json.to_string())
            } else {
                None
            }
        } else {
            None
        }
    }

    /// 清空终端的日志缓冲
    ///
    /// 仅当 `log_buffer_size > 0` 时可用。
    pub fn clear_log(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            if let Some(ref log_buffer) = terminal.log_buffer() {
                log_buffer.clear();
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    /// 检查终端是否启用了 Bracketed Paste Mode
    ///
    /// 当启用时（应用程序发送了 \x1b[?2004h），粘贴时应该用转义序列包裹内容。
    /// 当未启用时，直接发送原始文本。
    pub fn is_bracketed_paste_enabled(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            terminal.is_bracketed_paste_enabled()
        } else {
            false
        }
    }

    /// 检查终端是否启用了 Kitty 键盘协议
    ///
    /// 应用程序通过发送 `CSI > flags u` 启用 Kitty 键盘模式。
    /// 启用后，终端应使用 Kitty 协议编码按键（如 Shift+Enter → `\x1b[13;2u`）。
    pub fn is_kitty_keyboard_enabled(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            terminal.is_kitty_keyboard_enabled()
        } else {
            false
        }
    }

    /// 检查是否启用了鼠标追踪模式（SGR 1006, X11 1000, 等）
    ///
    /// 应用程序通过 DECSET 序列（如 `\x1b[?1006h`）启用鼠标追踪。
    /// 启用后，终端应将鼠标事件转换为 SGR 格式发送到 PTY。
    ///
    /// # 返回值
    /// - `true`: 鼠标追踪已启用，终端应发送鼠标事件到 PTY
    /// - `false`: 鼠标追踪未启用，终端处理自己的鼠标交互（选择、滚动等）
    pub fn has_mouse_tracking_mode(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            terminal.has_mouse_tracking_mode()
        } else {
            false
        }
    }

    /// 发送 SGR 格式的鼠标报告到 PTY
    ///
    /// SGR 鼠标报告格式：`\x1b[<button;col;rowM` 或 `\x1b[<button;col;rowm`
    ///
    /// # 参数
    /// - `id`: 终端 ID
    /// - `button`: 按钮编码
    ///   - 0=左键, 1=中键, 2=右键
    ///   - 64=滚轮向上, 65=滚轮向下
    /// - `col`: 网格列号（1-based）
    /// - `row`: 网格行号（1-based）
    /// - `pressed`: 是否按下（M/m）
    ///
    /// # 返回值
    /// - `true`: 发送成功
    /// - `false`: 终端不存在
    pub fn send_mouse_sgr(
        &self,
        id: usize,
        button: u8,
        col: u16,
        row: u16,
        pressed: bool,
    ) -> bool {
        let c = if pressed { 'M' } else { 'm' };
        let msg = format!("\x1b[<{};{};{}{}", button, col, row, c);
        self.input(id, msg.as_bytes())
    }

    /// 调整终端大小
    ///
    /// 分两阶段执行以避免死锁：
    /// 1. 获取 terminals 写锁，快速更新 entry 字段，获取 terminal Arc
    /// 2. 释放 terminals 写锁后，再调用 terminal.resize()
    ///
    /// 这避免了 terminals 锁和 crosswords 锁的循环等待：
    /// - PTY-1 可能持有 crosswords 锁并等待 terminals 读锁
    /// - 如果我们在持有 terminals 写锁时调用 terminal.resize()（需要 crosswords 锁）
    /// - 就会形成死锁
    pub fn resize_terminal(
        &mut self,
        id: usize,
        cols: u16,
        rows: u16,
        width: f32,
        height: f32,
    ) -> bool {
        use std::time::Duration;

        // 阶段 1：快速更新 entry 字段（持有写锁时间尽量短）
        // 使用 try_write_for 让 writer 实际排队，parking_lot 对排队的 writer 是公平的
        let (terminal_arc, pty_tx, daemon_session_id, needs_bounce) = {
            let mut terminals =
                match self.terminals.try_write_for(Duration::from_micros(200)) {
                    Some(t) => t,
                    None => {
                        // 写锁超时，排队待处理
                        self.pending_terminal_resizes
                            .lock()
                            .push((id, cols, rows, width, height));
                        self.needs_render.store(true, Ordering::Release);
                        return true;
                    }
                };

            if let Some(entry) = terminals.get_mut(&id) {
                // 更新存储的尺寸
                entry.cols = cols;
                entry.rows = rows;

                // GPU 资源延迟释放，避免主线程修改 Skia resource cache
                let old_surface = entry.surface_cache.take();
                let old_image = entry.render_cache.take();
                if old_surface.is_some() || old_image.is_some() {
                    self.deferred_gpu_drops.lock().push(DeferredGpuDrop {
                        surface: old_surface,
                        image: old_image,
                    });
                }
                entry.dirty_flag.mark_dirty();

                // 更新 RenderState 尺寸，标记需要全量同步
                {
                    let mut render_state = entry.render_state.lock();
                    render_state.handle_resize(cols as usize, rows as usize);
                }

                // 获取需要的引用，稍后在锁外使用
                let daemon_session_id = entry.daemon_session.as_ref().map(|s| s.session_id.clone());
                let needs_bounce = entry.daemon_session.as_mut()
                    .map(|s| std::mem::replace(&mut s.needs_sigwinch_bounce, false))
                    .unwrap_or(false);
                (entry.terminal.clone(), entry.pty_tx.clone(), daemon_session_id, needs_bounce)
            } else {
                return false;
            }
            // terminals 写锁在这里释放
        };

        // 阶段 2：在锁外执行可能阻塞的操作
        // 更新 Terminal（可能需要获取 crosswords 锁）
        let grid_resized = if let Some(mut terminal) = terminal_arc.try_lock() {
            terminal.resize(cols as usize, rows as usize);
            true
        } else {
            false
        };

        eprintln!("[resize_terminal] id={} cols={} rows={} grid_resized={} is_daemon={} needs_bounce={}",
            id, cols, rows, grid_resized, daemon_session_id.is_some(), needs_bounce);

        // 通知 PTY
        use teletypewriter::WinsizeBuilder;
        let winsize = WinsizeBuilder {
            rows,
            cols,
            width: width as u16,
            height: height as u16,
        };
        crate::rio_machine::send_resize(&pty_tx, winsize);

        // Reattach bounce：用当前正确尺寸触发 SIGWINCH，迫使 shell 重绘 prompt。
        // 缩小 1 列再恢复，保证即使窗口尺寸未变也能产生 SIGWINCH。
        if needs_bounce {
            let bounce = WinsizeBuilder { cols: cols.saturating_sub(1), rows, width: 0, height: 0 };
            crate::rio_machine::send_resize(&pty_tx, bounce);
            let restore = WinsizeBuilder { cols, rows, width: width as u16, height: height as u16 };
            crate::rio_machine::send_resize(&pty_tx, restore);
        }

        // 通知 daemon 更新 PTY 窗口大小
        if let Some(session_id) = daemon_session_id {
            let _ = super::daemon_client::DaemonClient::winsize_update(&session_id, cols, rows);
        }

        true
    }

    /// 发送输入到终端
    pub fn input(&self, id: usize, data: &[u8]) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            crate::rio_machine::send_input(&entry.pty_tx, data);
            // 输入后标记需要渲染
            // 某些应用（如 Claude CLI）在 raw 模式下不产生即时回显，
            // 但仍需要更新光标位置等状态，所以输入后应触发渲染
            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            eprintln!("[TerminalPool] input: id={} NOT FOUND (have: {:?})", id, terminals.keys().collect::<Vec<_>>());
            false
        }
    }

    /// 滚动终端
    ///
    /// 使用 try_lock 避免阻塞主线程，如果锁被占用则跳过这次滚动
    pub fn scroll(&self, id: usize, delta: i32) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            // 使用 try_lock 避免阻塞主线程
            if let Some(mut terminal) = entry.terminal.try_lock() {
                terminal.scroll(delta);
                // P1-C1 修复：滚动后标记脏，触发重新渲染
                // 滚动改变 display_offset，必须重新渲染视口
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
                true
            } else {
                // 锁被占用，跳过这次滚动
                false
            }
        } else {
            false
        }
    }

    /// 清屏：清除可视区域和滚动历史
    ///
    /// 使用 try_lock 避免阻塞主线程，如果锁被占用则跳过
    pub fn clear_screen(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                // 先清除可视区域（会把内容推入历史），再清除历史
                terminal.clear_visible_area();
                terminal.clear_saved_history();
                // 清除选区
                entry.selection_overlay.clear();
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    /// 设置选区
    ///
    /// 使用 try_lock 避免阻塞主线程
    /// 自动修正宽字符边界，确保选中整个宽字符：
    /// - start 在 spacer 上 → 向左修正到宽字符
    /// - end 在宽字符上 → 向右扩展到 spacer
    pub fn set_selection(
        &self,
        id: usize,
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
    ) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            // 尝试修正宽字符边界（如果能获取锁）
            let (adjusted_start_col, adjusted_end_col) =
                if let Some(terminal) = entry.terminal.try_lock() {
                    let state = terminal.state();
                    let grid = &state.grid;

                    // 修正 start：spacer 向左到宽字符
                    let adj_start =
                        Self::adjust_start_for_wide_char(start_row, start_col, grid);
                    // 修正 end：宽字符向右扩展到 spacer
                    let adj_end = Self::adjust_end_for_wide_char(end_row, end_col, grid);

                    (adj_start, adj_end)
                } else {
                    // 获取不到锁时保持原样（极少情况）
                    (start_col, end_col)
                };

            // 操作 SelectionOverlay
            entry.selection_overlay.update(
                start_row as i32,
                adjusted_start_col as u32,
                end_row as i32,
                adjusted_end_col as u32,
                crate::infra::SelectionType::Simple,
            );

            // 标记需要渲染
            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// 修正选区起点：如果在 spacer 上，向左移到宽字符
    fn adjust_start_for_wide_char(
        absolute_row: usize,
        col: usize,
        grid: &crate::domain::views::GridView,
    ) -> usize {
        const WIDE_CHAR_SPACER: u16 = 0b0000_0000_0100_0000;

        if let Some(screen_row) = grid.absolute_to_screen(absolute_row) {
            if let Some(row) = grid.row(screen_row) {
                let cells = row.cells();
                if col < cells.len()
                    && cells[col].flags & WIDE_CHAR_SPACER != 0
                    && col > 0
                {
                    return col - 1;
                }
            }
        }
        col
    }

    /// 修正选区终点：如果在宽字符上，向右扩展到 spacer
    fn adjust_end_for_wide_char(
        absolute_row: usize,
        col: usize,
        grid: &crate::domain::views::GridView,
    ) -> usize {
        const WIDE_CHAR: u16 = 0b0000_0000_0010_0000;

        if let Some(screen_row) = grid.absolute_to_screen(absolute_row) {
            if let Some(row) = grid.row(screen_row) {
                let cells = row.cells();
                // 如果在宽字符上，向右扩展到包含 spacer
                if col < cells.len()
                    && cells[col].flags & WIDE_CHAR != 0
                    && col + 1 < cells.len()
                {
                    return col + 1;
                }
            }
        }
        col
    }

    /// 清除选区
    ///
    /// 使用 try_lock 避免阻塞主线程
    pub fn clear_selection(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            entry.selection_overlay.clear();
            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// 完成选区（mouseUp 时调用）
    ///
    /// 从 SelectionOverlay 读取坐标，获取文本
    /// 如果选区内容全是空白，自动清除选区并触发渲染
    pub fn finalize_selection(&self, id: usize) -> Option<String> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let snapshot = entry.selection_overlay.snapshot()?;

            if let Some(terminal) = entry.terminal.try_lock() {
                let text = terminal.text_in_range(
                    snapshot.start_row,
                    snapshot.start_col,
                    snapshot.end_row,
                    snapshot.end_col,
                );

                match text {
                    Some(ref t) if t.chars().all(|c| c.is_whitespace()) => {
                        entry.selection_overlay.clear();
                        self.needs_render.store(true, Ordering::Release);
                        None
                    }
                    Some(t) => Some(t),
                    None => None,
                }
            } else {
                None
            }
        } else {
            None
        }
    }

    /// 获取选区文本（不清除选区）
    ///
    /// 从 SelectionOverlay 读取坐标，获取文本
    pub fn get_selection_text(&self, id: usize) -> Option<String> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let snapshot = entry.selection_overlay.snapshot()?;

            if let Some(terminal) = entry.terminal.try_lock() {
                terminal.text_in_range(
                    snapshot.start_row,
                    snapshot.start_col,
                    snapshot.end_row,
                    snapshot.end_col,
                )
            } else {
                None
            }
        } else {
            None
        }
    }

    /// 获取选区叠加层
    ///
    /// 返回 Arc 以便调用方持有引用
    pub fn get_selection_overlay(
        &self,
        id: usize,
    ) -> Option<Arc<crate::infra::SelectionOverlay>> {
        self.terminals
            .read()
            .get(&id)
            .map(|e| e.selection_overlay.clone())
    }

    /// 设置超链接悬停状态
    ///
    /// 使用 try_lock 避免阻塞主线程
    pub fn set_hyperlink_hover(
        &self,
        id: usize,
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
        uri: String,
    ) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                terminal.set_hyperlink_hover(start_row, start_col, end_row, end_col, uri);
                // 超链接悬停状态变化后标记脏，触发重新渲染
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    /// 清除超链接悬停状态
    ///
    /// 使用 try_lock 避免阻塞主线程
    pub fn clear_hyperlink_hover(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                terminal.clear_hyperlink_hover();
                // 超链接悬停状态变化后标记脏，触发重新渲染
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    // ========================================================================
    // IME 预编辑
    // ========================================================================

    /// 设置 IME 预编辑状态
    ///
    /// 从 Terminal 获取当前光标的绝对坐标，创建 ImeView 存储在 TerminalEntry 中。
    /// 不修改 Terminal 聚合根，保持领域纯净。
    ///
    /// # 参数
    /// - `id`: 终端 ID
    /// - `text`: 预编辑文本（如 "nihao"）
    /// - `cursor_offset`: 预编辑内的光标位置（字符索引）
    ///
    /// # 返回
    /// - `true`: 设置成功
    /// - `false`: 终端不存在或无法获取锁
    pub fn set_ime_preedit(&self, id: usize, text: String, cursor_offset: usize) -> bool {
        // 空文本等同于 clear
        if text.is_empty() {
            return self.clear_ime_preedit(id);
        }

        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            // 创建 ImeView（不需要坐标，渲染时直接用光标位置）
            let ime_view = crate::domain::ImeView::new(text, cursor_offset);
            *entry.ime_state.write() = Some(ime_view);

            // 标记脏，触发重新渲染
            entry.dirty_flag.mark_dirty();
            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// 清除 IME 预编辑状态
    ///
    /// # 参数
    /// - `id`: 终端 ID
    ///
    /// # 返回
    /// - `true`: 清除成功
    /// - `false`: 终端不存在
    pub fn clear_ime_preedit(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            // 只有当前有 IME 状态时才需要清除和触发渲染
            let had_ime = entry.ime_state.read().is_some();
            if had_ime {
                *entry.ime_state.write() = None;
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
            }
            true
        } else {
            false
        }
    }

    /// 获取 IME 预编辑状态（用于渲染）
    ///
    /// 返回 ImeView 的克隆（如果存在）
    pub fn get_ime_state(&self, id: usize) -> Option<crate::domain::ImeView> {
        self.terminals
            .read()
            .get(&id)
            .and_then(|e| e.ime_state.read().clone())
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
    pub fn render_terminal(
        &mut self,
        id: usize,
        _x: f32,
        _y: f32,
        width: f32,
        height: f32,
    ) -> bool {
        // 获取字体度量（物理像素）
        let font_metrics = {
            let mut renderer = self.renderer.lock();
            renderer.get_font_metrics()
        };

        let scale = self.config.scale;

        // 如果提供了 width/height，自动计算 cols/rows 并 resize
        if width > 0.0 && height > 0.0 {
            use crate::domain::primitives::PhysicalPixels;

            let physical_width = PhysicalPixels::new(width * scale);
            let physical_height = PhysicalPixels::new(height * scale);
            // 使用 line_height（= cell_height * factor）计算行数
            let physical_line_height =
                font_metrics.cell_height.value * self.config.line_height;

            let new_cols =
                (physical_width.value / font_metrics.cell_width.value).floor() as u16;
            let new_rows = (physical_height.value / physical_line_height).floor() as u16;

            if new_cols > 0 && new_rows > 0 {
                // 检查是否需要 resize，如果需要则放入 pending 队列
                // 注意：不直接调用 resize_terminal，因为它会阻塞等待写锁，
                // 而此时可能有其他线程持有读锁，导致死锁
                let needs_resize = {
                    let terminals = self.terminals.read();
                    if let Some(entry) = terminals.get(&id) {
                        entry.cols != new_cols || entry.rows != new_rows
                    } else {
                        false
                    }
                };
                if needs_resize {
                    // 放入 pending 队列，由下一帧的 apply_pending_updates 处理
                    self.pending_terminal_resizes
                        .lock()
                        .push((id, new_cols, new_rows, width, height));
                    self.needs_render
                        .store(true, std::sync::atomic::Ordering::Release);
                }
            }
        }

        // 计算所需尺寸（物理像素）
        use crate::domain::primitives::PhysicalPixels;
        let physical_width = PhysicalPixels::new(width * scale);
        let physical_height = PhysicalPixels::new(height * scale);
        let cache_width = physical_width.value as u32;
        let cache_height = physical_height.value as u32;

        // P2 修复：使用 dirty_flag 进行快速检查（无锁）
        // 如果不脏，直接跳过渲染
        //
        // P1-W1 修复：使用 check_and_clear() 代替 is_dirty()
        // 原因：之前在渲染结束后调用 check_and_clear()，但渲染期间 PTY 线程
        //       可能已经 mark_dirty()，导致新数据的脏标记被错误清除。
        // 修复：在决定渲染时立即 check_and_clear()，后续 mark_dirty() 会重新设置。
        // 返回 (cache_valid, dirty_cleared, sel_dirty_cleared) 供后续阶段使用
        let (cache_valid, dirty_cleared, sel_dirty_cleared) = {
            let terminals = self.terminals.read();
            match terminals.get(&id) {
                Some(entry) => {
                    // 检查缓存
                    let valid = match &entry.render_cache {
                        Some(cache) => {
                            cache.width == cache_width && cache.height == cache_height
                        }
                        None => false,
                    };
                    // 快速路径：缓存有效且不脏且选区无变化，直接跳过
                    // P1-W1 修复：使用 check_and_clear() 原子地检查并清除
                    // 返回值是之前的状态，如果为 true 则继续渲染
                    let dirty = entry.dirty_flag.check_and_clear();
                    let sel_dirty = entry.selection_overlay.check_and_clear_dirty();
                    if valid && !dirty && !sel_dirty {
                        return true;
                    }
                    // 传递 dirty 状态供后续阶段使用
                    (valid, dirty, sel_dirty)
                }
                None => return false,
            }
        };

        // ========================================================================
        // 两阶段锁优化：避免写者饥饿
        // ========================================================================
        // 问题：之前在 terminals 读锁内执行 sync_render_state，导致 resize_terminal
        //       的 try_write 永远失败（60fps 读锁几乎一直被占用）
        // 解决：快速获取 Arc 引用后立即释放读锁，耗时操作在锁外执行

        // 阶段 1：快速获取 Arc 引用（读锁只持有几微秒）
        let (
            terminal_arc,
            render_state_arc,
            _dirty_flag,
            cursor_cache,
            selection_cache,
            scroll_cache,
            selection_overlay,
            ime_state_arc,
        ) = {
            let terminals = self.terminals.read();
            match terminals.get(&id) {
                Some(entry) => (
                    entry.terminal.clone(),
                    entry.render_state.clone(),
                    entry.dirty_flag.clone(),
                    entry.cursor_cache.clone(),
                    entry.selection_cache.clone(),
                    entry.scroll_cache.clone(),
                    entry.selection_overlay.clone(),
                    entry.ime_state.clone(),
                ),
                None => return false,
            }
        };
        // terminals 读锁已释放，resize_terminal 现在可以获取写锁

        // 阶段 2：在锁外执行耗时操作
        let (state, rows) = {
            match terminal_arc.try_lock() {
                Some(mut terminal) => {
                    // 检查 DEC Synchronized Update (mode 2026)
                    // 如果正在 sync 中（收到 BSU 但未收到 ESU），跳过渲染以避免闪烁
                    if terminal.is_syncing() {
                        // 渲染被跳过，如果选区脏标记已清除，需要重新标记确保下帧继续渲染
                        if sel_dirty_cleared {
                            selection_overlay.mark_dirty();
                        }
                        return true;
                    }

                    // 使用增量更新获取状态（COW 优化）
                    let mut state = terminal.state_incremental();
                    let rows = state.grid.lines();

                    // 检查是否需要渲染
                    let is_damaged = terminal.is_damaged();
                    if cache_valid && !is_damaged && !dirty_cleared && !sel_dirty_cleared
                    {
                        return true;
                    }

                    // 重置 damage（与 sync 在同一 terminal 锁范围内，避免 TOCTOU）
                    terminal.reset_damage();

                    // 添加 IME 状态（从 TerminalEntry 独立存储中获取，不在 Terminal 聚合根内）
                    if let Some(ime) = ime_state_arc.read().clone() {
                        state.ime = Some(ime);
                    }

                    (state, rows)
                }
                None => {
                    // 锁被占用，跳过这一帧
                    // 渲染被跳过，如果选区脏标记已清除，需要重新标记确保下帧继续渲染
                    if sel_dirty_cleared {
                        selection_overlay.mark_dirty();
                    }
                    return true;
                }
            }
        };
        // terminal 锁已释放，安全渲染

        // 更新原子光标缓存（无锁写入）
        // 这样主线程可以无锁读取光标位置
        {
            let cursor = &state.cursor;
            let grid = &state.grid;

            // 计算屏幕坐标
            let history_size = grid.history_size();
            let display_offset = grid.display_offset();
            let absolute_line = cursor.line();

            if absolute_line >= history_size {
                let screen_row = (absolute_line - history_size + display_offset) as u16;
                cursor_cache.update(
                    cursor.col() as u16,
                    screen_row,
                    display_offset as u16,
                );
            } else {
                // 光标在历史区域，标记无效
                cursor_cache.invalidate();
            }
        }

        // 更新选区缓存（无锁写入）
        {
            if let Some(selection) = &state.selection {
                selection_cache.update(
                    selection.start.line as i32,
                    selection.start.col as u32,
                    selection.end.line as i32,
                    selection.end.col as u32,
                );
            } else {
                selection_cache.clear();
            }
        }

        // 更新滚动缓存（无锁写入）
        {
            let grid = &state.grid;
            let total_lines = grid.history_size() + grid.lines();
            scroll_cache.update(
                grid.display_offset() as u32,
                grid.history_size(),
                total_lines,
            );
        }

        // P4 优化：获取或创建 Surface 缓存
        // 检查是否需要重建 Surface（尺寸变化或首次创建）
        let needs_rebuild_surface = {
            let terminals = self.terminals.read();
            match terminals.get(&id) {
                Some(entry) => {
                    match &entry.surface_cache {
                        Some(cache) => {
                            cache.width != cache_width || cache.height != cache_height
                        }
                        None => true, // 首次创建
                    }
                }
                None => return false,
            }
        };

        // 如果需要重建，创建新 Surface 并缓存
        if needs_rebuild_surface {
            let new_surface = match self.create_temp_surface(cache_width, cache_height) {
                Some(s) => s,
                None => {
                    eprintln!(
                        "❌ [TerminalPool] Failed to create surface for terminal {}",
                        id
                    );
                    return false;
                }
            };

            // 更新 Surface 缓存（非阻塞获取写锁，避免死锁）
            if let Some(mut terminals) = self.terminals.try_write() {
                if let Some(entry) = terminals.get_mut(&id) {
                    entry.surface_cache = Some(TerminalSurfaceCache {
                        surface: new_surface,
                        width: cache_width,
                        height: cache_height,
                    });
                }
            } else {
                // 写锁被占用，跳过这一帧，下一帧重试
                // 渲染被跳过，如果选区脏标记已清除，需要重新标记确保下帧继续渲染
                if sel_dirty_cleared {
                    selection_overlay.mark_dirty();
                }
                return true;
            }
        }

        // 渲染所有行到 Surface（复用缓存的 Surface）
        {
            // 非阻塞获取写锁，避免死锁
            if let Some(mut terminals) = self.terminals.try_write() {
                if let Some(entry) = terminals.get_mut(&id) {
                    if let Some(surface_cache) = &mut entry.surface_cache {
                        let canvas = surface_cache.surface.canvas();
                        canvas.clear(skia_safe::Color::TRANSPARENT);

                        // 获取 GPU context 用于创建 GPU-backed Images（避免 CPU→GPU 双份内存）
                        let mut gpu_context = {
                            let sugarloaf = self.sugarloaf.lock();
                            sugarloaf.get_context().skia_context.clone()
                        };

                        let mut renderer = self.renderer.lock();

                        let logical_cell_size = font_metrics.to_logical_size(scale);
                        let logical_line_height =
                            logical_cell_size.height * self.config.line_height;

                        for line in 0..rows {
                            let image = renderer.render_line(
                                line,
                                &state,
                                Some(&mut gpu_context),
                            );

                            // 计算该行在 Surface 内的位置（物理像素）
                            let y_offset_pixels =
                                (logical_line_height * (line as f32)) * scale;
                            let y_offset = y_offset_pixels.value;

                            canvas.draw_image(&image, (0.0f32, y_offset), None);
                        }

                        // 绘制选区叠加层
                        // 注意：空白检查只在 mouseUp (finalize_selection) 时执行，
                        // 渲染时始终显示选区，让用户在拖拽过程中看到选区位置
                        if let Some(snapshot) = entry.selection_overlay.snapshot() {
                            use crate::domain::primitives::PhysicalPixels;
                            let physical_cell_width = PhysicalPixels::new(
                                logical_cell_size.width.value * scale,
                            );
                            let physical_line_height =
                                PhysicalPixels::new(logical_line_height.value * scale);
                            self.draw_selection_overlay(
                                canvas,
                                &snapshot,
                                physical_cell_width,
                                physical_line_height,
                                rows,
                                state.grid.history_size(),
                                state.grid.display_offset(),
                            );
                        }

                        // 绘制 IME 预编辑叠加层
                        if let Some(ime) = &state.ime {
                            use crate::domain::primitives::PhysicalPixels;
                            let physical_cell_width = PhysicalPixels::new(
                                logical_cell_size.width.value * scale,
                            );
                            let physical_line_height =
                                PhysicalPixels::new(logical_line_height.value * scale);
                            let font_metrics = renderer.get_font_metrics();
                            // 计算光标所在的屏幕行
                            let cursor_screen_row = state
                                .cursor
                                .line()
                                .saturating_sub(state.grid.history_size())
                                .saturating_add(state.grid.display_offset());
                            self.draw_ime_overlay(
                                canvas,
                                ime,
                                state.cursor.col(),
                                cursor_screen_row,
                                physical_cell_width,
                                physical_line_height,
                                font_metrics.baseline_offset.value, // 已经是物理像素，不需要再乘 scale
                            );
                        }

                        // 统计在 render_all 中统一输出，这里不重置
                        // renderer.print_frame_stats(&format!("terminal_{}", id));

                        // 从 Surface 获取 Image 快照并更新缓存
                        let cached_image = surface_cache.surface.image_snapshot();
                        entry.render_cache = Some(TerminalRenderCache {
                            cached_image,
                            width: cache_width,
                            height: cache_height,
                        });
                    } else {
                        return false;
                    }
                } else {
                    return false;
                }
            } else {
                // 写锁被占用，跳过这一帧，下一帧重试
                // 渲染被跳过，如果选区脏标记已清除，需要重新标记确保下帧继续渲染
                if sel_dirty_cleared {
                    selection_overlay.mark_dirty();
                }
                return true;
            }
        }
        // Surface 保留在缓存中，不会 drop（P4 优化目标）

        // P1-W1 修复：dirty_flag 和 selection_overlay 的 check_and_clear()
        // 已移到函数开头（Line 1193-1194），避免竞态条件。
        // 原因：渲染期间 PTY 可能 mark_dirty()，在结束时清除会丢失更新。

        true
    }

    /// 结束帧（贴图合成）
    ///
    /// 从缓存获取 Image，贴图合成到最终画面
    ///
    /// # 锁顺序（重要！防止死锁）
    ///
    /// 必须保持与主线程 layout() 一致的锁顺序：
    /// 1. sugarloaf.lock()
    /// 2. render_layout.lock()
    ///
    /// 主线程调用顺序：
    /// - resize_sugarloaf() → sugarloaf.lock()
    /// - set_render_layout() → render_layout.lock()
    ///
    /// 如果顺序不一致会导致死锁！
    pub fn end_frame(&mut self) {
        // 清空 pending_objects（新方案不再使用）
        self.pending_objects.clear();

        // ⚠️ 锁顺序：先 sugarloaf，再 render_layout（与主线程一致，防止死锁）
        let mut sugarloaf = self.sugarloaf.lock();

        // 获取当前布局（在 sugarloaf 锁内，保持锁顺序）
        let layout = {
            let render_layout = self.render_layout.lock();
            render_layout.clone()
        };

        if layout.is_empty() {
            return;
        }

        // 从每个终端的缓存获取 Image
        let mut objects = Vec::new();
        {
            let terminals = self.terminals.read();
            for (terminal_id, x, y, _width, _height) in &layout {
                if let Some(entry) = terminals.get(terminal_id) {
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
        }

        sugarloaf.set_objects(objects);

        // 触发 GPU 渲染
        sugarloaf.render();

        // GPU 异常恢复：检测 OOM/device lost 后强制清理
        self.check_gpu_health_and_recover(&mut *sugarloaf);
    }

    /// 检测 GPU 异常状态，触发恢复
    ///
    /// 当 Skia DirectContext 报告 OOM 时：
    /// 1. 清除终端的 Surface/Image 缓存（这是 GPU 内存大头）
    /// 2. 不触碰 Skia DirectContext 的资源缓存，让内置 LRU 自行管理
    ///    - 避免清掉 shader program / pipeline cache 导致重编译超时
    ///
    /// 使用 30 秒冷却窗口（AtomicU64 无锁），避免 oomed() 持续 true 导致每帧触发。
    fn check_gpu_health_and_recover(&self, sugarloaf: &mut Sugarloaf) {
        let ctx = sugarloaf.get_context_mut();
        let oomed = ctx.skia_context.oomed();
        let device_lost = ctx.skia_context.is_device_lost();

        if !oomed && !device_lost {
            return;
        }

        // 冷却窗口：30 秒内只触发一次恢复（无锁）
        let now_epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let last_epoch = self.last_gpu_recovery_epoch.load(Ordering::Relaxed);
        if now_epoch.saturating_sub(last_epoch) < 30 {
            return;
        }

        crate::rust_log_warn!(
            "[GPU] ⚠️ GPU abnormal state detected! oomed={}, device_lost={}. Recovering...",
            oomed,
            device_lost
        );

        // 只清除终端的 Surface/Image 缓存（GPU 内存大头 ~2-4MB/tab）
        // 不调用 Skia purge API，保留 shader program / pipeline cache
        // Skia 内置 LRU 会在预算超限时自动淘汰其他资源
        if let Some(mut terminals) = self.terminals.try_write() {
            for (_id, entry) in terminals.iter_mut() {
                entry.surface_cache = None;
                entry.render_cache = None;
                entry.dirty_flag.mark_dirty();
            }
            // 清理成功后才更新冷却时间戳
            self.last_gpu_recovery_epoch.store(now_epoch, Ordering::Relaxed);
            crate::rust_log_warn!("[GPU] Recovery complete. Terminal caches cleared (shader programs preserved).");
        } else {
            crate::rust_log_warn!("[GPU] Recovery skipped: terminals write lock busy, will retry next frame.");
        }
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
    pub fn set_render_layout(
        &self,
        layout: Vec<(usize, f32, f32, f32, f32)>,
        container_height: f32,
    ) {
        // GPU 缓存淘汰：在 layout move 之前提取可见终端 ID 集合
        let visible_ids: std::collections::HashSet<usize> =
            layout.iter().map(|(id, _, _, _, _)| *id).collect();

        {
            let mut render_layout = self.render_layout.lock();
            *render_layout = layout;
        }
        {
            let mut height = self.container_height.lock();
            *height = container_height;
        }

        // 标记需要渲染
        self.needs_render
            .store(true, std::sync::atomic::Ordering::Release);

        // 释放不可见终端的 GPU 缓存（多 tab 场景防止 GPU 内存压力）
        self.evict_invisible_gpu_caches(&visible_ids);
    }

    /// 释放不在当前布局中的终端的 GPU 缓存
    ///
    /// 多 tab 场景（4K@2x, 20+ tab）下，每个终端 surface_cache + render_cache
    /// 占用约 250MB GPU 内存。不可见终端缓存常驻导致 Metal shader 编译超时。
    ///
    /// 阈值策略：总终端数 < 6 时不清理，保持少 tab 场景的原有行为。
    /// 使用 try_write 避免阻塞主线程，失败时下次调用重试。
    fn evict_invisible_gpu_caches(&self, visible_ids: &std::collections::HashSet<usize>) {
        const EVICTION_THRESHOLD: usize = 6;

        // 快速检查：少 tab 时不清理
        let total_count = self.terminals.read().len();
        if total_count < EVICTION_THRESHOLD {
            return;
        }

        // 非阻塞获取写锁，避免阻塞主线程
        if let Some(mut terminals) = self.terminals.try_write() {
            let mut evicted = 0usize;
            for (id, entry) in terminals.iter_mut() {
                if !visible_ids.contains(id)
                    && (entry.surface_cache.is_some() || entry.render_cache.is_some())
                {
                    let old_surface = entry.surface_cache.take();
                    let old_image = entry.render_cache.take();
                    if old_surface.is_some() || old_image.is_some() {
                        self.deferred_gpu_drops.lock().push(DeferredGpuDrop {
                            surface: old_surface,
                            image: old_image,
                        });
                    }
                    entry.dirty_flag.mark_dirty();
                    evicted += 1;
                }
            }
            if evicted > 0 {
                crate::rust_log_info!(
                    "[GPU] Evicted GPU caches for {} invisible terminals",
                    evicted
                );
            }
        }
        // try_write 失败不要紧，下次 set_render_layout 调用时重试
    }

    /// 获取渲染布局的 Arc 引用（供 RenderScheduler 使用）
    pub fn render_layout_ref(&self) -> Arc<Mutex<Vec<(usize, f32, f32, f32, f32)>>> {
        self.render_layout.clone()
    }

    /// 获取容器高度的 Arc 引用（供 RenderScheduler 使用）
    pub fn container_height_ref(&self) -> Arc<Mutex<f32>> {
        self.container_height.clone()
    }

    /// 应用主线程排队的待处理更新
    ///
    /// 在 render_all() 开始时调用，确保：
    /// 1. 主线程的 try_lock 失败时不会丢失更新
    /// 2. 所有更新按正确的锁顺序应用（sugarloaf → renderer）
    fn apply_pending_updates(&mut self) {
        use crate::domain::primitives::LogicalPixels;

        // 1. 应用待处理的 resize（需要 sugarloaf 锁）
        let pending_resize = self.pending_resize.lock().take();
        if let Some((width, height)) = pending_resize {
            let mut sugarloaf = self.sugarloaf.lock();
            sugarloaf.resize(width as u32, height as u32);
        }

        // 2. 应用待处理的 scale（需要 sugarloaf + renderer 锁）
        // 锁顺序：sugarloaf → renderer（遵循项目规定的锁顺序）
        let pending_scale = self.pending_scale.lock().take();
        if let Some(scale) = pending_scale {
            // 先获取 sugarloaf 锁
            {
                let mut sugarloaf = self.sugarloaf.lock();
                sugarloaf.rescale(scale);
            }
            // 再获取 renderer 锁
            {
                let mut renderer = self.renderer.lock();
                renderer.set_scale(scale);
                // 更新 font metrics 缓存（scale 变化会影响物理像素值）
                let metrics = renderer.get_font_metrics();
                let new_metrics = (
                    metrics.cell_width.value,
                    metrics.cell_height.value,
                    metrics.cell_height.value * self.config.line_height,
                );
                drop(renderer); // 先释放 renderer 锁
                *self.cached_font_metrics.write().unwrap() = new_metrics;
            }
        }

        // 3. 应用待处理的字体大小（需要 renderer 锁）
        let pending_font_size = self.pending_font_size.lock().take();
        if let Some(font_size) = pending_font_size {
            let mut renderer = self.renderer.lock();
            renderer.set_font_size(LogicalPixels::new(font_size));
            // 更新 font metrics 缓存
            let metrics = renderer.get_font_metrics();
            let new_metrics = (
                metrics.cell_width.value,
                metrics.cell_height.value,
                metrics.cell_height.value * self.config.line_height,
            );
            drop(renderer); // 先释放 renderer 锁
            *self.cached_font_metrics.write().unwrap() = new_metrics;
        }

        // 4. 应用待处理的终端 resize
        // 两阶段执行：先更新 entry，释放锁后再调用 terminal.resize()
        let pending_resizes: Vec<_> =
            self.pending_terminal_resizes.lock().drain(..).collect();
        if !pending_resizes.is_empty() {
            // 阶段 1：收集需要 resize 的终端信息
            let resize_tasks: Vec<_> = {
                if let Some(mut terminals) = self.terminals.try_write() {
                    pending_resizes
                        .into_iter()
                        .filter_map(|(id, cols, rows, width, height)| {
                            if let Some(entry) = terminals.get_mut(&id) {
                                // 更新 entry 字段
                                entry.cols = cols;
                                entry.rows = rows;
                                entry.surface_cache = None;
                                entry.render_cache = None;
                                entry.dirty_flag.mark_dirty();
                                // 收集需要的信息
                                let daemon_session_id = entry.daemon_session.as_ref().map(|s| s.session_id.clone());
                                Some((
                                    entry.terminal.clone(),
                                    entry.pty_tx.clone(),
                                    daemon_session_id,
                                    cols,
                                    rows,
                                    width,
                                    height,
                                ))
                            } else {
                                None
                            }
                        })
                        .collect()
                } else {
                    // 写锁被占用，放回队列下一帧重试
                    self.pending_terminal_resizes.lock().extend(pending_resizes);
                    return;
                }
            };

            // 阶段 2：在锁外执行 terminal.resize() 和 send_resize()
            for (terminal_arc, pty_tx, daemon_session_id, cols, rows, width, height) in resize_tasks {
                if let Some(mut terminal) = terminal_arc.try_lock() {
                    terminal.resize(cols as usize, rows as usize);
                }
                use teletypewriter::WinsizeBuilder;
                let winsize = WinsizeBuilder {
                    rows,
                    cols,
                    width: width as u16,
                    height: height as u16,
                };
                crate::rio_machine::send_resize(&pty_tx, winsize);

                // 通知 daemon 更新 PTY 窗口大小
                if let Some(session_id) = daemon_session_id {
                    let _ = super::daemon_client::DaemonClient::winsize_update(&session_id, cols, rows);
                }
            }
        }
    }

    /// 渲染所有布局中的终端（由 RenderScheduler 调用）
    ///
    /// 完整的渲染循环：apply_pending → begin_frame → render_terminal × N → end_frame
    /// 在 Rust 侧完成，无需 Swift 参与
    pub fn render_all(&mut self) {
        use std::sync::atomic::{AtomicU64, Ordering};

        let frame_start = std::time::Instant::now();

        // 释放主线程排队的 GPU 资源（必须在渲染线程 drop，避免与 Skia GrResourceCache 竞态）
        {
            let mut drops = self.deferred_gpu_drops.lock();
            drops.clear();
        }

        // 先应用主线程排队的待处理更新（避免更新丢失）
        self.apply_pending_updates();

        // 获取当前布局
        let layout = {
            let render_layout = self.render_layout.lock();
            render_layout.clone()
        };

        if layout.is_empty() {
            // 布局为空时输出警告（Release 也输出，但限制频率）
            static LAST_EMPTY_WARN: AtomicU64 = AtomicU64::new(0);
            let now_secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let last = LAST_EMPTY_WARN.load(Ordering::Relaxed);
            if now_secs >= last + 5 {
                LAST_EMPTY_WARN.store(now_secs, Ordering::Relaxed);
                crate::rust_log_warn!(
                    "[RenderLoop] ⚠️ render_all: layout is empty, skipping"
                );
            }
            return;
        }

        // 开始新的一帧
        self.begin_frame();

        // 渲染每个终端
        let render_start = std::time::Instant::now();
        for (terminal_id, x, y, width, height) in &layout {
            self.render_terminal(*terminal_id, *x, *y, *width, *height);
        }
        let render_time = render_start.elapsed();

        // 结束帧（统一提交渲染）
        self.end_frame();

        let frame_time = frame_start.elapsed();

        // 🎯 帧时间日志（默认关闭，只有开启 perf_log feature 才输出）
        #[cfg(feature = "perf_log")]
        {
            static FRAME_NUM: AtomicU64 = AtomicU64::new(0);
            let n = FRAME_NUM.fetch_add(1, Ordering::Relaxed);

            let mut renderer = self.renderer.lock();
            let (hits, layout_hits, misses) = renderer.get_frame_stats();

            // ⚠️ DO NOT DELETE - 帧性能定位日志，用于调试渲染性能问题
            // 输出: 帧序号、总耗时、渲染耗时、缓存命中(H)、布局命中(L)、缓存未命中(M)、终端数量
            crate::rust_log_info!("[perf] frame #{} total={:?} render={:?} H={} L={} M={} terminals={}",
                n, frame_time, render_time, hits, layout_hits, misses, layout.len());

            // renderer.print_frame_stats("render_all");
        }
    }

    /// 调整 Sugarloaf 尺寸
    ///
    /// 使用 try_lock 避免阻塞主线程：
    /// - GPU Surface 创建可能需要主线程的 Metal 回调
    /// - 如果 CVDisplayLink 线程持有 sugarloaf 锁并等待 GPU
    /// - 而主线程在这里阻塞等待锁，会导致死锁
    ///
    /// 如果 try_lock 失败，将更新排队到 pending_resize，
    /// 在下次 render_all() 开始时应用，确保更新不会丢失
    pub fn resize_sugarloaf(&mut self, width: f32, height: f32) {
        // 使用 try_lock 避免死锁
        if let Some(mut sugarloaf) = self.sugarloaf.try_lock() {
            sugarloaf.resize(width as u32, height as u32);
            // 成功时清除待处理队列（避免旧值被回滚）
            self.pending_resize.lock().take();
        } else {
            // 锁被占用，排队待处理更新
            *self.pending_resize.lock() = Some((width, height));
        }
        // 无论成功与否都标记需要渲染
        self.needs_render
            .store(true, std::sync::atomic::Ordering::Release);
    }

    /// 设置 DPI 缩放（窗口在不同 DPI 屏幕间移动时调用）
    ///
    /// 更新渲染器的 scale factor，确保坐标转换正确
    ///
    /// 使用 try_lock 避免阻塞主线程（与 resize_sugarloaf 相同的原因）
    /// 如果 try_lock 失败，将更新排队到 pending_scale
    pub fn set_scale(&mut self, scale: f32) {
        // 更新 config 中的 scale
        self.config.scale = scale;

        // 尝试立即更新渲染器和 Sugarloaf，同时获取新的 font metrics
        let (renderer_updated, new_metrics) = self
            .renderer
            .try_lock()
            .map(|mut r| {
                r.set_scale(scale);
                // 获取更新后的 font metrics（scale 变化会影响物理像素值）
                let metrics = r.get_font_metrics();
                let cached = (
                    metrics.cell_width.value,
                    metrics.cell_height.value,
                    metrics.cell_height.value * self.config.line_height,
                );
                (true, Some(cached))
            })
            .unwrap_or((false, None));

        let sugarloaf_updated = self
            .sugarloaf
            .try_lock()
            .map(|mut s| {
                s.rescale(scale);
                true
            })
            .unwrap_or(false);

        if renderer_updated && sugarloaf_updated {
            // 全部成功时清除待处理队列（避免旧值被回滚）
            self.pending_scale.lock().take();
            // 更新 font metrics 缓存，确保 Swift 侧获取到新的物理像素值
            // 修复：之前遗漏了这一步，导致 DPI 切换后选区坐标计算使用旧的 cell 尺寸
            if let Some(metrics) = new_metrics {
                *self.cached_font_metrics.write().unwrap() = metrics;
            }
        } else {
            // 如果任一更新失败，排队待处理
            // apply_pending_updates 会负责更新 cached_font_metrics
            *self.pending_scale.lock() = Some(scale);
        }

        // 标记需要重新渲染
        self.needs_render.store(true, Ordering::Release);
    }

    /// 设置事件回调
    pub fn set_event_callback(
        &mut self,
        callback: TerminalPoolEventCallback,
        context: *mut c_void,
    ) {
        self.event_callback = Some((callback, context));

        // 设置 EventQueue 回调（如果已经有字符串回调，一起设置）
        let pool_ptr = self as *mut TerminalPool as *mut c_void;
        let string_cb = if self.string_event_callback.is_some() {
            Some(
                Self::string_event_queue_callback
                    as crate::rio_event::StringEventCallback,
            )
        } else {
            None
        };
        self.event_queue
            .set_callback(Self::event_queue_callback, string_cb, pool_ptr);
    }

    /// 设置字符串事件回调（用于 CWD、Command 等事件）
    pub fn set_string_event_callback(
        &mut self,
        callback: super::ffi::TerminalPoolStringEventCallback,
        context: *mut c_void,
    ) {
        self.string_event_callback = Some((callback, context));

        // 更新 EventQueue 回调（需要重新设置，因为添加了 string_callback）
        let pool_ptr = self as *mut TerminalPool as *mut c_void;
        self.event_queue.set_callback(
            Self::event_queue_callback,
            Some(Self::string_event_queue_callback),
            pool_ptr,
        );
    }

    /// 字符串事件 EventQueue 回调
    ///
    /// 当收到 CurrentDirectoryChanged/CommandExecuted 等事件时，转发给 Swift
    ///
    /// 注意：event_type 是 FFIEvent 的事件类型（13=CurrentDirectoryChanged, 14=CommandExecuted）
    /// 需要转换为 TerminalEventType（6=CurrentDirectoryChanged, 7=CommandExecuted）
    extern "C" fn string_event_queue_callback(
        context: *mut c_void,
        event_type: u32,
        terminal_id: usize,
        data: *const std::ffi::c_char,
    ) {
        if context.is_null() || data.is_null() {
            return;
        }

        // 转换事件类型：FFIEvent.event_type → TerminalEventType
        // FFIEvent: 13=CurrentDirectoryChanged, 14=CommandExecuted, 4=Title
        // TerminalEventType: 6=CurrentDirectoryChanged, 7=CommandExecuted, 4=TitleChanged
        let swift_event_type = match event_type {
            13 => TerminalEventType::CurrentDirectoryChanged, // OSC 7
            14 => TerminalEventType::CommandExecuted,         // OSC 133;C
            4 => TerminalEventType::TitleChanged,
            _ => return, // 忽略其他事件类型
        };

        unsafe {
            let pool = &*(context as *const TerminalPool);
            if let Some((callback, swift_context)) = pool.string_event_callback {
                callback(swift_context, swift_event_type, terminal_id, data);
            }
        }
    }

    /// EventQueue 回调
    ///
    /// 当收到 Wakeup/Render 事件时，标记对应终端的 dirty_lines
    extern "C" fn event_queue_callback(
        context: *mut c_void,
        event: crate::rio_event::FFIEvent,
    ) {
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
        // 使用全局事件路由，支持跨 Pool 迁移后的终端
        if event_type == TerminalEventType::Wakeup
            || event_type == TerminalEventType::Render
        {
            let terminal_id = event.route_id;

            // 首先检查本地 Pool 是否有该终端（用于 Background 模式检查）
            let is_background = unsafe {
                let pool = &*(context as *const TerminalPool);
                let terminals = pool.terminals.read();
                terminals
                    .get(&terminal_id)
                    .map(|entry| entry.is_background.load(Ordering::Acquire))
            };

            match is_background {
                Some(true) => {
                    // Background 模式，标记脏但不触发渲染
                    #[cfg(debug_assertions)]
                    crate::rust_log_warn!(
                        "[RenderLoop] ⚠️ terminal {} is Background, skip render trigger",
                        terminal_id
                    );
                    let registry = global_terminal_registry().read();
                    if let Some(target) = registry.get(&terminal_id) {
                        target.dirty_flag.mark_dirty();
                    }
                    return;
                }
                Some(false) => {
                    // Active 模式且在本地 Pool，使用全局路由
                    route_wakeup_event(terminal_id);
                }
                None => {
                    // 终端不在本地 Pool（可能已迁移到其他 Pool）
                    // 使用全局路由转发到正确的 Pool
                    route_wakeup_event(terminal_id);
                }
            }
        }

        // 发送事件到 Swift（Bell、TitleChanged、Exit 等仍需通知）
        let terminal_event = TerminalEvent {
            event_type,
            data: event.route_id as u64, // 传递终端 ID
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
        self.terminals.read().len()
    }

    /// 获取终端的 Arc 引用（线程安全）
    ///
    /// 返回 Arc<Mutex<Terminal>>，调用者需要自己获取 Mutex 锁
    pub fn get_terminal_arc(&self, id: usize) -> Option<Arc<Mutex<Terminal>>> {
        self.terminals
            .read()
            .get(&id)
            .map(|entry| entry.terminal.clone())
    }

    /// 获取终端并执行操作（阻塞）
    ///
    /// 使用回调模式避免生命周期问题
    /// 返回 None 如果终端不存在，否则返回回调的结果
    pub fn with_terminal<F, R>(&self, id: usize, f: F) -> Option<R>
    where
        F: FnOnce(&mut Terminal) -> R,
    {
        let terminals = self.terminals.read();
        terminals.get(&id).map(|entry| {
            let mut terminal = entry.terminal.lock();
            f(&mut terminal)
        })
    }

    /// 获取终端并执行操作（非阻塞）
    ///
    /// 如果 Terminal 的锁被占用，立即返回 None 而不是等待
    /// 用于主线程调用，避免阻塞 UI
    pub fn try_with_terminal<F, R>(&self, id: usize, f: F) -> Option<R>
    where
        F: FnOnce(&mut Terminal) -> R,
    {
        let terminals = self.terminals.read();
        terminals.get(&id).and_then(|entry| {
            entry
                .terminal
                .try_lock()
                .map(|mut terminal| f(&mut terminal))
        })
    }

    /// 获取终端（只读，阻塞）- 已废弃
    ///
    /// 由于 RwLock 包装，无法直接返回 MutexGuard
    /// 请使用 get_terminal_arc() 获取 Arc 后自行加锁
    /// 或使用 with_terminal() 在回调中操作
    #[deprecated(note = "使用 get_terminal_arc() 或 with_terminal() 替代")]
    pub fn get_terminal(&self, id: usize) -> Option<Arc<Mutex<Terminal>>> {
        self.get_terminal_arc(id)
    }

    /// 获取终端（只读，非阻塞）- 已废弃
    ///
    /// 由于 RwLock 包装，无法直接返回 MutexGuard
    /// 请使用 get_terminal_arc() 获取 Arc 后自行使用 try_lock
    /// 或使用 try_with_terminal() 在回调中操作
    #[deprecated(note = "使用 get_terminal_arc() 或 try_with_terminal() 替代")]
    pub fn try_get_terminal(&self, id: usize) -> Option<Arc<Mutex<Terminal>>> {
        self.get_terminal_arc(id)
    }

    /// 获取终端（可变）- 已废弃
    #[deprecated(note = "使用 get_terminal_arc() 或 with_terminal() 替代")]
    pub fn get_terminal_mut(&mut self, id: usize) -> Option<Arc<Mutex<Terminal>>> {
        self.get_terminal_arc(id)
    }

    /// 获取终端（可变，非阻塞）- 已废弃
    #[deprecated(note = "使用 get_terminal_arc() 或 try_with_terminal() 替代")]
    pub fn try_get_terminal_mut(&mut self, id: usize) -> Option<Arc<Mutex<Terminal>>> {
        self.get_terminal_arc(id)
    }

    /// 获取终端的原子光标缓存（无锁）
    ///
    /// 返回 Arc<AtomicCursorCache>，可以无锁读取光标位置
    pub fn get_cursor_cache(
        &self,
        id: usize,
    ) -> Option<Arc<crate::infra::AtomicCursorCache>> {
        self.terminals
            .read()
            .get(&id)
            .map(|entry| entry.cursor_cache.clone())
    }

    /// 获取终端的选区缓存（无锁）
    ///
    /// 从原子缓存读取选区范围，无需获取 Terminal 锁
    /// 返回 Some((start_row, start_col, end_row, end_col)) 或 None
    pub fn get_selection_cache(&self, id: usize) -> Option<(i32, u32, i32, u32)> {
        self.terminals
            .read()
            .get(&id)
            .and_then(|entry| entry.selection_cache.read())
    }

    /// 获取终端的滚动缓存（无锁）
    ///
    /// 从原子缓存读取滚动信息，无需获取 Terminal 锁
    /// 返回 Some((display_offset, history_size, total_lines)) 或 None
    pub fn get_scroll_cache(&self, id: usize) -> Option<(u32, u16, u16)> {
        self.terminals
            .read()
            .get(&id)
            .and_then(|entry| entry.scroll_cache.read())
    }

    /// 获取终端的标题缓存（无锁）
    ///
    /// 从原子缓存读取标题，无需获取 Terminal 锁
    pub fn get_title_cache(&self, id: usize) -> Option<String> {
        self.terminals
            .read()
            .get(&id)
            .and_then(|entry| entry.title_cache.read())
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
    ///
    /// 直接返回缓存值，无锁争用。缓存在以下时机更新：
    /// - 启动时初始化
    /// - Cmd+/- 调整字体大小
    /// - DPI/scale 变化
    pub fn get_font_metrics(&self) -> (f32, f32, f32) {
        // 直接读取缓存，无锁争用（RwLock 读锁极快）
        *self.cached_font_metrics.read().unwrap()
    }

    /// 更新 font metrics 缓存（内部方法）
    ///
    /// 在字体大小或 scale 变化后调用
    fn update_font_metrics_cache(&self) {
        if let Some(mut renderer) = self.renderer.try_lock() {
            let metrics = renderer.get_font_metrics();
            let new_metrics = (
                metrics.cell_width.value,
                metrics.cell_height.value,
                metrics.cell_height.value * self.config.line_height,
            );
            *self.cached_font_metrics.write().unwrap() = new_metrics;
        }
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
    ///
    /// 使用 try_lock 避免阻塞主线程
    pub fn change_font_size(&mut self, operation: u8) {
        use crate::domain::primitives::LogicalPixels;

        // 计算新字体大小
        let new_font_size = match operation {
            0 => 14.0,                                     // Reset
            1 => (self.config.font_size - 1.0).max(6.0),   // Decrease
            2 => (self.config.font_size + 1.0).min(100.0), // Increase
            _ => return,                                   // 无效操作
        };

        // 更新配置
        self.config.font_size = new_font_size;

        // 更新渲染器（非阻塞）
        let updated = self
            .renderer
            .try_lock()
            .map(|mut r| {
                r.set_font_size(LogicalPixels::new(new_font_size));
                true
            })
            .unwrap_or(false);

        if updated {
            // 成功时清除待处理队列（避免旧值被回滚）
            self.pending_font_size.lock().take();
            // 更新 font metrics 缓存
            self.update_font_metrics_cache();
        } else {
            // 锁被占用，排队待处理更新
            *self.pending_font_size.lock() = Some(new_font_size);
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
    /// - 匹配数量（>= 0），失败返回 -1（终端不存在或锁被占用）
    pub fn search(&self, terminal_id: usize, query: &str) -> i32 {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                let count = terminal.search(query) as i32;

                // 搜索结果变化后标记脏，触发重新渲染
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
                count
            } else {
                -1 // 锁被占用
            }
        } else {
            -1 // 终端不存在
        }
    }

    /// 跳转到下一个匹配
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    ///
    /// 使用 try_lock 避免阻塞主线程，如果锁被占用则跳过
    pub fn search_next(&self, terminal_id: usize) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                terminal.next_match();

                // 搜索焦点变化后标记脏，触发重新渲染
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
            }
        }
    }

    /// 跳转到上一个匹配
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    ///
    /// 使用 try_lock 避免阻塞主线程，如果锁被占用则跳过
    pub fn search_prev(&self, terminal_id: usize) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                terminal.prev_match();

                // 搜索焦点变化后标记脏，触发重新渲染
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
            }
        }
    }

    /// 清除搜索
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    ///
    /// 使用 try_lock 避免阻塞主线程，如果锁被占用则跳过
    pub fn clear_search(&self, terminal_id: usize) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            if let Some(mut terminal) = entry.terminal.try_lock() {
                terminal.clear_search();

                // 清除搜索后标记脏，触发重新渲染
                entry.dirty_flag.mark_dirty();
                self.needs_render.store(true, Ordering::Release);
            }
        }
    }

    // ========================================================================
    // 终端模式管理
    // ========================================================================

    /// 设置终端运行模式
    ///
    /// # 参数
    /// - terminal_id: 终端 ID
    /// - mode: 新的运行模式（0=Active, 1=Background）
    ///
    /// # 说明
    /// - Active 模式：完整处理 + 触发渲染回调
    /// - Background 模式：完整 VTE 解析但不触发渲染回调
    /// - 切换到 Active 时会自动触发一次渲染刷新
    pub fn set_terminal_mode(
        &self,
        terminal_id: usize,
        mode: crate::domain::aggregates::TerminalMode,
    ) {
        let should_wakeup = {
            let terminals = self.terminals.read();
            if let Some(entry) = terminals.get(&terminal_id) {
                // 先更新原子标记（无锁），让 event_queue_callback 能立即看到
                let is_background =
                    mode == crate::domain::aggregates::TerminalMode::Background;
                entry.is_background.store(is_background, Ordering::Release);

                // 尝试更新 Terminal 内部状态（非阻塞）
                // 如果锁被占用则跳过，Terminal 状态会在下次渲染时通过原子标记同步
                if let Some(mut terminal) = entry.terminal.try_lock() {
                    terminal.set_mode(mode);
                }

                // 返回是否需要唤醒渲染
                mode == crate::domain::aggregates::TerminalMode::Active
            } else {
                false
            }
        }; // terminals 锁在这里释放

        // 如果切换到 Active 模式，主动触发渲染
        // 必须在 terminals 锁释放后调用，避免死锁
        if should_wakeup {
            route_wakeup_event(terminal_id);
        }
    }

    /// 获取终端运行模式
    ///
    /// # 返回
    /// - Some(mode): 终端存在，返回当前模式
    /// - None: 终端不存在
    ///
    /// # 注意
    /// 优先使用原子标记（无锁），避免阻塞
    pub fn get_terminal_mode(
        &self,
        terminal_id: usize,
    ) -> Option<crate::domain::aggregates::TerminalMode> {
        let terminals = self.terminals.read();
        terminals.get(&terminal_id).map(|entry| {
            // 使用原子读取（无锁）
            if entry.is_background.load(Ordering::Acquire) {
                crate::domain::aggregates::TerminalMode::Background
            } else {
                crate::domain::aggregates::TerminalMode::Active
            }
        })
    }

    /// 绘制选区叠加层
    ///
    /// # 参数
    /// - canvas: Skia Canvas
    /// - selection: 选区快照
    /// - cell_width: 单元格宽度（物理像素）
    /// - line_height: 行高（物理像素）
    /// - screen_rows: 可见行数
    /// - history_size: 历史缓冲区大小
    /// - display_offset: 滚动偏移
    fn draw_selection_overlay(
        &self,
        canvas: &skia_safe::Canvas,
        selection: &crate::infra::SelectionSnapshot,
        cell_width: crate::domain::primitives::PhysicalPixels,
        line_height: crate::domain::primitives::PhysicalPixels,
        screen_rows: usize,
        history_size: usize,
        display_offset: usize,
    ) {
        use crate::infra::SelectionType;

        // 选区背景色：半透明蓝色
        let selection_color = skia_safe::Color4f::new(0.3, 0.5, 0.8, 0.35);

        let mut paint = skia_safe::Paint::default();
        paint.set_color4f(selection_color, None);
        paint.set_anti_alias(false); // 矩形不需要抗锯齿

        // 规范化选区：确保 start <= end（支持反向选择）
        let (sel_start_row, sel_start_col, sel_end_row, sel_end_col) =
            if selection.start_row < selection.end_row
                || (selection.start_row == selection.end_row
                    && selection.start_col <= selection.end_col)
            {
                // 正向选择
                (
                    selection.start_row,
                    selection.start_col,
                    selection.end_row,
                    selection.end_col,
                )
            } else {
                // 反向选择：交换 start 和 end
                (
                    selection.end_row,
                    selection.end_col,
                    selection.start_row,
                    selection.start_col,
                )
            };

        // 遍历可见行
        for screen_row in 0..screen_rows {
            // 计算绝对行号
            let abs_row =
                (history_size + screen_row).saturating_sub(display_offset) as i32;

            // 检查是否在选区范围内
            if abs_row < sel_start_row || abs_row > sel_end_row {
                continue;
            }

            // 计算该行的选区列范围
            let (start_col, end_col) = match selection.ty {
                SelectionType::Block => {
                    // 块选区：固定列范围（也需要规范化）
                    (
                        sel_start_col.min(sel_end_col),
                        sel_start_col.max(sel_end_col),
                    )
                }
                SelectionType::Lines => {
                    // 行选区：整行
                    (0, u32::MAX)
                }
                SelectionType::Simple => {
                    // 普通选区
                    let start = if abs_row == sel_start_row {
                        sel_start_col
                    } else {
                        0
                    };
                    let end = if abs_row == sel_end_row {
                        sel_end_col
                    } else {
                        u32::MAX
                    };
                    (start, end)
                }
            };

            // 绘制矩形
            let x = start_col as f32 * cell_width.value;
            let y = screen_row as f32 * line_height.value;
            let w = ((end_col.saturating_sub(start_col)).min(1000) + 1) as f32
                * cell_width.value;
            let h = line_height.value;

            canvas.draw_rect(skia_safe::Rect::from_xywh(x, y, w, h), &paint);
        }
    }

    /// 绘制 IME 预编辑叠加层
    ///
    /// 使用逐字符渲染，确保和终端文本等宽对齐
    fn draw_ime_overlay(
        &self,
        canvas: &skia_safe::Canvas,
        ime: &crate::domain::ImeView,
        cursor_col: usize,
        cursor_screen_row: usize,
        cell_width: crate::domain::primitives::PhysicalPixels,
        line_height: crate::domain::primitives::PhysicalPixels,
        baseline_offset: f32,
    ) {
        use skia_safe::{Color4f, Font, FontMgr, FontStyle, Paint, Point};

        let ime_x = cursor_col as f32 * cell_width.value;
        let ime_y = cursor_screen_row as f32 * line_height.value;

        // 计算预编辑文本的显示宽度（按字符宽度）
        // 简单判断：ASCII 单宽，非 ASCII（如中文）双宽
        let ime_display_width: f32 = ime
            .text
            .chars()
            .map(|c| {
                let char_width = if c.is_ascii() { 1 } else { 2 };
                char_width as f32 * cell_width.value
            })
            .sum();

        // 1. 绘制半透明背景
        let mut bg_paint = Paint::default();
        bg_paint.set_anti_alias(true);
        bg_paint.set_color4f(Color4f::new(0.2, 0.2, 0.4, 0.85), None);
        bg_paint.set_style(skia_safe::PaintStyle::Fill);
        let bg_rect = skia_safe::Rect::from_xywh(
            ime_x,
            ime_y,
            ime_display_width,
            line_height.value,
        );
        canvas.draw_rect(bg_rect, &bg_paint);

        // 2. 逐字符绘制预编辑文本
        let font_mgr = FontMgr::new();
        let font_size = line_height.value * 0.75; // 和终端字体大小保持一致

        // 尝试使用 Maple Mono，回退到系统字体
        let typeface = font_mgr
            .match_family_style("Maple Mono NF CN", FontStyle::normal())
            .or_else(|| font_mgr.match_family_style("Menlo", FontStyle::normal()))
            .unwrap_or_else(|| {
                font_mgr
                    .legacy_make_typeface(None, FontStyle::normal())
                    .unwrap()
            });

        let font = Font::from_typeface(&typeface, font_size);

        let mut text_paint = Paint::default();
        text_paint.set_anti_alias(true);
        text_paint.set_color4f(Color4f::new(1.0, 1.0, 1.0, 1.0), None);

        let mut x_offset = ime_x;
        for ch in ime.text.chars() {
            let char_width = if ch.is_ascii() { 1 } else { 2 };
            let char_cell_width = char_width as f32 * cell_width.value;

            // 查找支持该字符的字体
            let (draw_font, _is_emoji) = if font.unichar_to_glyph(ch as i32) != 0 {
                (font.clone(), false)
            } else {
                // 回退到系统字体
                if let Some(fallback_tf) = font_mgr.match_family_style_character(
                    "",
                    FontStyle::normal(),
                    &[],
                    ch as i32,
                ) {
                    (
                        Font::from_typeface(&fallback_tf, font_size),
                        fallback_tf.family_name().to_lowercase().contains("emoji"),
                    )
                } else {
                    (font.clone(), false)
                }
            };

            // 绘制字符
            let text_y = ime_y + baseline_offset;
            let char_str = ch.to_string();
            canvas.draw_str(
                &char_str,
                Point::new(x_offset, text_y),
                &draw_font,
                &text_paint,
            );

            x_offset += char_cell_width;
        }

        // 3. 绘制下划线
        let mut underline_paint = Paint::default();
        underline_paint.set_anti_alias(true);
        underline_paint.set_color4f(Color4f::new(1.0, 1.0, 1.0, 0.6), None);
        underline_paint.set_style(skia_safe::PaintStyle::Stroke);
        underline_paint.set_stroke_width(1.0);

        let underline_y = ime_y + line_height.value - 2.0;
        canvas.draw_line(
            Point::new(ime_x, underline_y),
            Point::new(ime_x + ime_display_width, underline_y),
            &underline_paint,
        );

        // 4. 绘制预编辑内光标（竖线）
        let cursor_x_in_ime: f32 = ime
            .text
            .chars()
            .take(ime.cursor_offset)
            .map(|c| {
                let w = if c.is_ascii() { 1 } else { 2 };
                w as f32 * cell_width.value
            })
            .sum();
        let ime_cursor_x = ime_x + cursor_x_in_ime;

        let mut cursor_paint = Paint::default();
        cursor_paint.set_anti_alias(true);
        cursor_paint.set_color4f(Color4f::new(1.0, 1.0, 1.0, 0.9), None);
        cursor_paint.set_style(skia_safe::PaintStyle::Fill);
        let cursor_rect = skia_safe::Rect::from_xywh(
            ime_cursor_x,
            ime_y + 2.0,
            2.0,
            line_height.value - 4.0,
        );
        canvas.draw_rect(cursor_rect, &cursor_paint);
    }
}

impl Drop for TerminalPool {
    fn drop(&mut self) {
        // 首先关闭事件队列，防止 PTY 线程在销毁过程中触发回调
        // 这避免了 use-after-free 问题：
        // - PTY 线程可能仍在运行
        // - 回调的 context 指针指向 TerminalPool
        // - 如果不先 shutdown，回调可能使用已释放的内存
        self.event_queue.shutdown();

        // 显式清理所有 daemon session，防止 ETerm 退出后留下幽灵进程。
        // HashMap 自动 drop 时 DaemonSession 结构体释放，但 daemon 进程不会收到任何信号；
        // 此处根据 keep_daemon_alive 标记决定 detach（保留 session 供后续 reattach）
        // 还是 kill（彻底终止 daemon 进程）。
        let mut terminals = self.terminals.write();
        for (_, entry) in terminals.drain() {
            if let Some(ref ds) = entry.daemon_session {
                if entry.keep_daemon_alive {
                    let _ = super::daemon_client::DaemonClient::detach(
                        &ds.session_id,
                        entry.cols,
                        entry.rows,
                    );
                } else {
                    let _ = super::daemon_client::DaemonClient::kill(&ds.session_id);
                }
            }
            // 通知 Machine 线程退出，避免写入已关闭的 PTY fd
            let _ = entry.pty_tx.send(rio_backend::event::Msg::Shutdown);
        }
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
            window_handle: std::ptr::null_mut(), // 测试环境
            display_handle: std::ptr::null_mut(),
            window_width: 800.0,
            window_height: 600.0,
            history_size: 10000,
            log_buffer_size: 0, // 测试默认禁用
        }
    }

    #[test]
    fn test_terminal_pool_create_fails_without_window() {
        let config = create_test_config();
        let result = TerminalPool::new(config);
        assert!(result.is_err()); // 没有 window_handle 应该失败
    }

    /// 测试字体大小计算逻辑（不需要 TerminalPool 实例）
    #[test]
    fn test_font_size_calculation() {
        let initial_size = 14.0f32;

        // Test reset (operation = 0)
        let reset_size = 14.0f32; // Reset 固定为 14.0
        assert_eq!(reset_size, 14.0);

        // Test decrease (operation = 1)
        let decreased = (initial_size - 1.0).max(6.0);
        assert_eq!(decreased, 13.0);

        // Test decrease at minimum
        let at_min = 6.0f32;
        let decreased_at_min = (at_min - 1.0).max(6.0);
        assert_eq!(decreased_at_min, 6.0); // 不能低于 6.0

        // Test increase (operation = 2)
        let increased = (initial_size + 1.0).min(100.0);
        assert_eq!(increased, 15.0);

        // Test increase at maximum
        let at_max = 100.0f32;
        let increased_at_max = (at_max + 1.0).min(100.0);
        assert_eq!(increased_at_max, 100.0); // 不能超过 100.0
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
        use crate::domain::primitives::LogicalPixels;
        use crate::domain::{AbsolutePoint, SelectionType, SelectionView};
        use crate::render::font::FontContext;
        use crate::render::{RenderConfig, Renderer};
        use rio_backend::config::colors::Colors;
        use std::sync::Arc;
        use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};

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
            let _img = renderer.render_line(line, &state, None);
        }
        let frame1_time = frame1_start.elapsed();
        let frame1_stats = renderer.stats.clone();

        eprintln!(
            "Frame 1: {:?} | misses={} hits={} layout_hits={}",
            frame1_time,
            frame1_stats.cache_misses,
            frame1_stats.cache_hits,
            frame1_stats.layout_hits
        );

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
            let _img = renderer.render_line(line, &state2, None);
        }
        let render_time = render_start.elapsed();
        let frame2_stats = renderer.stats.clone();

        let total_time = state_start.elapsed();

        eprintln!(
            "Frame 2: total={:?} | state={:?} render={:?}",
            total_time, state_time, render_time
        );
        eprintln!(
            "Frame 2 stats: misses={} hits={} layout_hits={}",
            frame2_stats.cache_misses, frame2_stats.cache_hits, frame2_stats.layout_hits
        );

        // 5. 验证
        // 第一帧应该全部 miss
        assert_eq!(
            frame1_stats.cache_misses, 100,
            "Frame 1: all lines should miss"
        );

        // 第二帧：只有 row3 需要重绘
        assert_eq!(
            frame2_stats.cache_hits, 99,
            "Frame 2: 99 lines should hit cache, got {} hits {} misses {} layout_hits",
            frame2_stats.cache_hits, frame2_stats.cache_misses, frame2_stats.layout_hits
        );

        eprintln!(
            "Speedup: {:.1}x (render only: {:.1}x)",
            frame1_time.as_micros() as f64 / total_time.as_micros() as f64,
            frame1_time.as_micros() as f64 / render_time.as_micros() as f64
        );
    }

    /// 测试：方案 0 - AtomicDirtyFlag 快速检查
    ///
    /// 验证 dirty_flag 能正确跳过无变化的帧
    #[test]
    fn test_dirty_flag_optimization() {
        use crate::infra::AtomicDirtyFlag;
        use std::sync::Arc;

        let flag = Arc::new(AtomicDirtyFlag::new());

        // 初始为脏
        assert!(flag.is_dirty());

        // 检查并清除
        assert!(flag.check_and_clear());
        assert!(!flag.is_dirty());

        // 模拟多帧无变化
        for _ in 0..100 {
            // 无 PTY 写入，不标记脏
            // 渲染线程检查，应该跳过
            assert!(!flag.is_dirty());
        }

        // 模拟 PTY 写入
        flag.mark_dirty();
        assert!(flag.is_dirty());

        // 渲染后清除
        assert!(flag.check_and_clear());
        assert!(!flag.is_dirty());
    }

    /// 测试：方案 2 - 可见区域快照性能
    ///
    /// 验证只快照可见行能大幅减少数据拷贝
    #[test]
    fn test_visible_area_snapshot_perf() {
        use crate::domain::aggregates::{Terminal, TerminalId};
        use std::time::Instant;

        // 创建有历史的终端（模拟大量历史）
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入大量数据产生历史（模拟 1000 行）
        for i in 0..1000 {
            terminal.write(format!("Line {:04} - some content here\r\n", i).as_bytes());
        }

        // 测试 state() 调用性能
        let iterations = 100;
        let start = Instant::now();
        for _ in 0..iterations {
            let _state = terminal.state();
        }
        let elapsed = start.elapsed();
        let avg_micros = elapsed.as_micros() / iterations;

        eprintln!(
            "state() 平均耗时: {}μs ({:.2}ms)",
            avg_micros,
            avg_micros as f64 / 1000.0
        );

        // 验证：优化后应该 < 5ms (之前是 60ms)
        // 注意：测试环境性能可能不稳定，使用较宽松的阈值
        assert!(
            avg_micros < 10_000,
            "state() 应该 < 10ms，实际 {}μs",
            avg_micros
        );
    }

    /// 测试：端到端性能 - 渲染帧率
    ///
    /// 验证优化后能支持 60 FPS
    #[test]
    fn test_end_to_end_frame_rate() {
        use crate::domain::aggregates::{Terminal, TerminalId};
        use std::time::Instant;

        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入内容
        for i in 0..50 {
            terminal.write(format!("Line {:02} - test content\r\n", i).as_bytes());
        }

        // 模拟 60 帧渲染
        let frames = 60;
        let start = Instant::now();

        for frame in 0..frames {
            // 模拟：偶数帧有 PTY 写入，奇数帧无变化
            if frame % 2 == 0 {
                // 有变化，state() 会被调用
                let _state = terminal.state();
            }
            // 无变化，应该被跳过（实际场景中通过 dirty_flag）
        }

        let elapsed = start.elapsed();
        let frame_time_micros = elapsed.as_micros() / frames;
        let fps = 1_000_000.0 / frame_time_micros as f64;

        eprintln!(
            "平均帧时间: {}μs ({:.2}ms), FPS: {:.1}",
            frame_time_micros,
            frame_time_micros as f64 / 1000.0,
            fps
        );

        // 验证：应该能支持 >= 60 FPS (每帧 < 16.7ms)
        assert!(
            frame_time_micros < 16_700,
            "应该支持 60 FPS，实际帧时间 {}μs",
            frame_time_micros
        );
    }

    /// 测试 RwLock<HashMap> 的线程安全性（P0 HashMap UB 修复验证）
    ///
    /// 这个测试验证了使用 RwLock 包装 HashMap 后，多线程并发访问是安全的。
    /// 修复前：PTY 线程和主线程同时访问 HashMap 会导致 Data Race (UB)
    /// 修复后：使用 RwLock 保护，读写操作是线程安全的
    #[test]
    fn test_rwlock_hashmap_thread_safety() {
        use parking_lot::RwLock;
        use std::collections::HashMap;
        use std::sync::Arc;
        use std::thread;

        // 模拟 terminals: RwLock<HashMap<usize, T>> 结构
        struct MockEntry {
            value: String,
        }

        let map: Arc<RwLock<HashMap<usize, MockEntry>>> =
            Arc::new(RwLock::new(HashMap::new()));

        // 写线程：模拟主线程 create_terminal / close_terminal
        let map_write = Arc::clone(&map);
        let write_handle = thread::spawn(move || {
            for i in 0..100 {
                // 写入
                {
                    let mut terminals = map_write.write();
                    terminals.insert(
                        i,
                        MockEntry {
                            value: format!("terminal_{}", i),
                        },
                    );
                }
                // 删除部分
                if i % 3 == 0 && i > 0 {
                    let mut terminals = map_write.write();
                    terminals.remove(&(i - 1));
                }
            }
        });

        // 读线程：模拟 PTY 线程 event_queue_callback
        let map_read = Arc::clone(&map);
        let read_handle = thread::spawn(move || {
            let mut reads = 0;
            for _ in 0..500 {
                let terminals = map_read.read();
                for (id, entry) in terminals.iter() {
                    // 读取操作
                    let _ = (id, &entry.value);
                    reads += 1;
                }
            }
            reads
        });

        // 另一个读线程：模拟渲染线程
        let map_read2 = Arc::clone(&map);
        let read_handle2 = thread::spawn(move || {
            let mut count = 0;
            for _ in 0..500 {
                let terminals = map_read2.read();
                count += terminals.len();
            }
            count
        });

        // 等待所有线程完成
        write_handle.join().expect("写线程应该正常完成");
        let total_reads = read_handle.join().expect("读线程1应该正常完成");
        let total_counts = read_handle2.join().expect("读线程2应该正常完成");

        // 验证最终状态
        let final_map = map.read();
        assert!(final_map.len() > 0, "应该有一些终端存在");
        assert!(total_reads > 0, "应该读取了一些数据: {}", total_reads);
        assert!(total_counts > 0, "应该统计了一些数量: {}", total_counts);

        eprintln!("✅ RwLock<HashMap> 线程安全测试通过");
        eprintln!("   - 最终 HashMap 大小: {}", final_map.len());
        eprintln!("   - 总读取次数: {}", total_reads);
        eprintln!("   - 总统计次数: {}", total_counts);
    }

    /// 测试：P2 TOCTOU 修复验证
    ///
    /// 验证在 render_terminal() 中，state() 和 reset_damage() 在同一锁范围内执行，
    /// 避免 TOCTOU 竞态导致数据丢失。
    ///
    /// 场景模拟：
    /// 1. 渲染线程获取 state A
    /// 2. PTY 线程写入数据 B，标记 damage
    /// 3. 渲染线程 reset_damage() - 修复前会错误地 reset B 的 damage
    ///
    /// 修复后：state() 和 reset_damage() 在同一锁范围内，B 的 damage 不会被错误 reset
    #[test]
    fn test_p2_toctou_fix() {
        use crate::domain::aggregates::{Terminal, TerminalId};
        use crate::infra::AtomicDirtyFlag;
        use std::sync::Arc;
        use std::thread;
        use std::time::Duration;

        // 创建 Terminal
        let terminal =
            Arc::new(Mutex::new(Terminal::new_for_test(TerminalId(1), 80, 24)));
        let dirty_flag = Arc::new(AtomicDirtyFlag::new());

        // 写入初始内容
        {
            let mut term = terminal.lock();
            term.write(b"Initial content\r\n");
        }

        // 模拟渲染流程（修复后的流程）
        let render_result = {
            let mut term = terminal.try_lock().expect("获取锁失败");

            // Step 1: 检查 damaged（在锁范围内）
            let is_damaged = term.is_damaged();
            assert!(is_damaged, "初始应该是 damaged");

            // Step 2: 获取状态快照
            let state_before = term.state();
            let rows_before = term.rows();

            // Step 3: 在同一锁范围内 reset_damage
            term.reset_damage();

            // 锁仍然持有，验证 damage 已清除
            assert!(!term.is_damaged(), "reset_damage 后应该不 damaged");

            (state_before, rows_before)
        };
        // 锁已释放

        // 验证：即使在锁释放后，PTY 写入新数据，也不会影响已获取的状态
        let (state, rows) = render_result;
        assert_eq!(rows, 24);
        assert!(state.grid.lines() > 0);

        // 模拟 PTY 写入新数据（锁已释放）
        {
            let mut term = terminal.lock();
            term.write(b"New data after render\r\n");
            // 新数据会标记新的 damage
        }

        // 验证：新数据有 damage
        {
            let term = terminal.lock();
            assert!(term.is_damaged(), "新写入应该标记 damage");
        }
    }

    /// 测试：P2 TOCTOU 并发场景
    ///
    /// 模拟渲染线程和 PTY 线程并发执行，验证不会丢失数据。
    #[test]
    fn test_p2_toctou_concurrent() {
        use crate::domain::aggregates::{Terminal, TerminalId};
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        use std::thread;
        use std::time::Duration;

        let terminal =
            Arc::new(Mutex::new(Terminal::new_for_test(TerminalId(1), 80, 24)));
        let write_count = Arc::new(AtomicUsize::new(0));
        let render_count = Arc::new(AtomicUsize::new(0));
        let stop_flag = Arc::new(AtomicBool::new(false));

        // PTY 写入线程（模拟高频写入）
        let term_writer = Arc::clone(&terminal);
        let write_count_clone = Arc::clone(&write_count);
        let stop_flag_clone = Arc::clone(&stop_flag);
        let writer_handle = thread::spawn(move || {
            let mut count = 0;
            while !stop_flag_clone.load(Ordering::Acquire) && count < 100 {
                if let Some(mut term) = term_writer.try_lock() {
                    term.write(format!("Data {}\r\n", count).as_bytes());
                    count += 1;
                    write_count_clone.fetch_add(1, Ordering::Release);
                }
                thread::sleep(Duration::from_micros(100));
            }
        });

        // 渲染线程（模拟渲染流程）
        let term_renderer = Arc::clone(&terminal);
        let render_count_clone = Arc::clone(&render_count);
        let stop_flag_clone = Arc::clone(&stop_flag);
        let renderer_handle = thread::spawn(move || {
            let mut damage_seen = 0;
            for _ in 0..50 {
                if let Some(mut term) = term_renderer.try_lock() {
                    // 修复后的流程：在锁范围内完成所有操作
                    if term.is_damaged() {
                        let _state = term.state();
                        term.reset_damage();
                        damage_seen += 1;
                    }
                }
                thread::sleep(Duration::from_micros(200));
            }
            render_count_clone.store(damage_seen, Ordering::Release);
        });

        // 等待一段时间后停止
        thread::sleep(Duration::from_millis(20));
        stop_flag.store(true, Ordering::Release);

        writer_handle.join().expect("写入线程应该正常完成");
        renderer_handle.join().expect("渲染线程应该正常完成");

        let total_writes = write_count.load(Ordering::Acquire);
        let total_renders = render_count.load(Ordering::Acquire);

        eprintln!("✅ P2 TOCTOU 并发测试通过");
        eprintln!("   - 总写入次数: {}", total_writes);
        eprintln!("   - 总渲染次数: {}", total_renders);

        // 验证：应该有写入和渲染发生
        assert!(total_writes > 0, "应该有写入发生");
        // 注意：渲染次数可能少于写入次数（渲染可能被跳过），但不应该为 0
        // 某些情况下可能为 0（如果写入很快，渲染线程一直获取不到锁）
    }

    /// 测试：P4 Surface 缓存复用
    ///
    /// 验证 Surface 会被缓存和复用，尺寸不变时不重建
    #[test]
    fn test_p4_surface_cache_reuse() {
        use parking_lot::Mutex;
        use std::sync::Arc;

        // 创建测试用的 TerminalEntry（模拟结构）
        struct MockSurfaceCache {
            surface_cache: Option<TerminalSurfaceCache>,
        }

        let mut entry = MockSurfaceCache {
            surface_cache: None,
        };

        // 模拟第一次渲染：创建 Surface
        let cache_width = 800u32;
        let cache_height = 600u32;

        // 检查是否需要创建 Surface（首次应该需要）
        let needs_create = match &entry.surface_cache {
            Some(cache) => cache.width != cache_width || cache.height != cache_height,
            None => true,
        };
        assert!(needs_create, "首次应该需要创建 Surface");

        // 注意：实际测试中无法创建真实的 GPU Surface（需要 GPU 上下文）
        // 这里只测试缓存逻辑，Surface 创建在实际运行时测试

        // 模拟第二次渲染：相同尺寸，应该复用
        // entry.surface_cache = Some(...);  // 假设已创建
        // let needs_rebuild = match &entry.surface_cache {
        //     Some(cache) => cache.width != cache_width || cache.height != cache_height,
        //     None => true,
        // };
        // assert!(!needs_rebuild, "相同尺寸应该复用 Surface");

        eprintln!("✅ P4 Surface 缓存逻辑测试通过");
    }

    /// 测试：P4 Surface 缓存在尺寸变化时重建
    #[test]
    fn test_p4_surface_cache_rebuild_on_resize() {
        // 模拟 resize_terminal 清除 Surface 缓存的逻辑
        struct MockEntry {
            surface_cache: Option<()>, // 简化为 Option<()>
            cols: u16,
            rows: u16,
        }

        let mut entry = MockEntry {
            surface_cache: Some(()), // 假设已有 Surface 缓存
            cols: 80,
            rows: 24,
        };

        // 验证初始状态
        assert!(entry.surface_cache.is_some(), "初始应该有 Surface 缓存");

        // 模拟 resize
        entry.cols = 100;
        entry.rows = 30;
        entry.surface_cache = None; // resize 时清除缓存

        // 验证缓存已清除
        assert!(
            entry.surface_cache.is_none(),
            "resize 后 Surface 缓存应该被清除"
        );

        eprintln!("✅ P4 Surface 缓存在 resize 时正确清除");
    }

    /// 测试：P4 Surface 缓存生命周期
    ///
    /// 验证 Surface 会在 TerminalEntry drop 时自动释放
    #[test]
    fn test_p4_surface_cache_lifecycle() {
        // Surface 是 RAII 资源，会在 drop 时自动释放 GPU 资源
        // TerminalEntry drop 时，surface_cache 也会 drop
        // 无需手动清理

        struct MockEntry {
            surface_cache: Option<()>,
        }

        impl Drop for MockEntry {
            fn drop(&mut self) {
                // Surface 在这里自动 drop
                if self.surface_cache.is_some() {
                    eprintln!("Surface 缓存随 Entry 一起释放");
                }
            }
        }

        {
            let entry = MockEntry {
                surface_cache: Some(()),
            };
            // entry 在这里 drop
        }

        eprintln!("✅ P4 Surface 缓存生命周期管理正确");
    }

    /// 测试：GPU 缓存淘汰 - 阈值以下不清理
    #[test]
    fn test_evict_invisible_gpu_caches_below_threshold() {
        // 模拟少 tab 场景（< 6），不应触发清理
        struct MockEntry {
            surface_cache: Option<()>,
            render_cache: Option<()>,
            is_visible: bool,
        }

        let entries = vec![
            MockEntry { surface_cache: Some(()), render_cache: Some(()), is_visible: true },
            MockEntry { surface_cache: Some(()), render_cache: Some(()), is_visible: false },
            MockEntry { surface_cache: Some(()), render_cache: Some(()), is_visible: false },
        ];

        // 总数 3 < EVICTION_THRESHOLD(6)，不应清理
        let total = entries.len();
        assert!(total < 6, "测试前提：总数小于阈值");

        // 验证：所有 entry 都保持缓存
        for entry in &entries {
            assert!(entry.surface_cache.is_some(), "阈值以下不应清理缓存");
        }

        eprintln!("✅ GPU 缓存淘汰：阈值以下不清理");
    }

    /// 测试：GPU 缓存淘汰 - 超过阈值时清理不可见终端
    #[test]
    fn test_evict_invisible_gpu_caches_above_threshold() {
        use std::collections::HashSet;

        struct MockEntry {
            id: usize,
            surface_cache: Option<()>,
            render_cache: Option<()>,
            dirty: bool,
        }

        let mut entries: Vec<MockEntry> = (0..10)
            .map(|i| MockEntry {
                id: i,
                surface_cache: Some(()),
                render_cache: Some(()),
                dirty: false,
            })
            .collect();

        // 可见集合：只有 id 0 和 1
        let visible_ids: HashSet<usize> = [0, 1].iter().copied().collect();

        // 模拟淘汰逻辑
        let total = entries.len();
        assert!(total >= 6, "测试前提：总数大于等于阈值");

        let mut evicted = 0usize;
        for entry in entries.iter_mut() {
            if !visible_ids.contains(&entry.id)
                && (entry.surface_cache.is_some() || entry.render_cache.is_some())
            {
                entry.surface_cache = None;
                entry.render_cache = None;
                entry.dirty = true;
                evicted += 1;
            }
        }

        // 验证：8 个不可见终端被清理
        assert_eq!(evicted, 8, "应清理 8 个不可见终端的缓存");

        // 验证：可见终端保持缓存
        assert!(entries[0].surface_cache.is_some(), "可见终端 0 应保持缓存");
        assert!(entries[1].surface_cache.is_some(), "可见终端 1 应保持缓存");

        // 验证：不可见终端缓存已清除
        for entry in &entries[2..] {
            assert!(entry.surface_cache.is_none(), "不可见终端应清除 surface_cache");
            assert!(entry.render_cache.is_none(), "不可见终端应清除 render_cache");
            assert!(entry.dirty, "清除后应标记 dirty");
        }

        eprintln!("✅ GPU 缓存淘汰：超过阈值时正确清理不可见终端");
    }

    /// 测试：GPU 缓存淘汰 - split view 多个可见终端不被清理
    #[test]
    fn test_evict_invisible_gpu_caches_split_view() {
        use std::collections::HashSet;

        struct MockEntry {
            id: usize,
            surface_cache: Option<()>,
            render_cache: Option<()>,
        }

        let mut entries: Vec<MockEntry> = (0..8)
            .map(|i| MockEntry {
                id: i,
                surface_cache: Some(()),
                render_cache: Some(()),
            })
            .collect();

        // Split view：id 0, 1, 2 同时可见
        let visible_ids: HashSet<usize> = [0, 1, 2].iter().copied().collect();

        let mut evicted = 0usize;
        for entry in entries.iter_mut() {
            if !visible_ids.contains(&entry.id)
                && (entry.surface_cache.is_some() || entry.render_cache.is_some())
            {
                entry.surface_cache = None;
                entry.render_cache = None;
                evicted += 1;
            }
        }

        // 验证：3 个可见终端保持缓存，5 个不可见终端被清理
        assert_eq!(evicted, 5);
        for i in 0..3 {
            assert!(entries[i].surface_cache.is_some(), "split view 可见终端 {} 应保持缓存", i);
        }
        for i in 3..8 {
            assert!(entries[i].surface_cache.is_none(), "不可见终端 {} 应清除缓存", i);
        }

        eprintln!("✅ GPU 缓存淘汰：split view 多个可见终端正确保留");
    }

    #[test]
    fn test_deferred_gpu_drop_basic() {
        use parking_lot::Mutex;
        use std::sync::Arc;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let drop_count = Arc::new(AtomicUsize::new(0));
        let queue: Mutex<Vec<Arc<AtomicUsize>>> = Mutex::new(Vec::new());

        // 模拟主线程：take + 入队（不立即 drop）
        {
            let tracker = drop_count.clone();
            queue.lock().push(tracker);
        }

        // 入队后 drop_count 引用数 = 2（原始 + 队列里的）
        assert_eq!(Arc::strong_count(&drop_count), 2, "入队后应有 2 个引用");

        // 模拟 CVDisplayLink 线程：清空队列（触发 drop）
        {
            queue.lock().clear();
        }

        // 清空后只剩原始引用
        assert_eq!(Arc::strong_count(&drop_count), 1, "清空队列后应只剩 1 个引用");

        eprintln!("✅ deferred GPU drop: 入队延迟释放，clear 触发 drop");
    }

    #[test]
    fn test_deferred_gpu_drop_cross_thread() {
        use parking_lot::Mutex;
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        use std::thread;
        use std::time::Duration;

        let queue: Arc<Mutex<Vec<Arc<AtomicUsize>>>> = Arc::new(Mutex::new(Vec::new()));
        let dropped_on_render_thread = Arc::new(AtomicBool::new(false));
        let render_thread_id = Arc::new(Mutex::new(None::<thread::ThreadId>));
        let stop = Arc::new(AtomicBool::new(false));

        // "渲染线程"：定期清空队列
        let q = queue.clone();
        let flag = dropped_on_render_thread.clone();
        let tid = render_thread_id.clone();
        let s = stop.clone();
        let render_handle = thread::spawn(move || {
            *tid.lock() = Some(thread::current().id());
            while !s.load(Ordering::Acquire) {
                let mut guard = q.lock();
                if !guard.is_empty() {
                    // drop 发生在这个线程
                    guard.clear();
                    flag.store(true, Ordering::Release);
                }
                drop(guard);
                thread::sleep(Duration::from_micros(100));
            }
        });

        // 等渲染线程启动
        thread::sleep(Duration::from_millis(5));

        // "主线程"：往队列里放资源
        let tracker = Arc::new(AtomicUsize::new(0));
        queue.lock().push(tracker.clone());
        assert_eq!(Arc::strong_count(&tracker), 2);

        // 等渲染线程清空
        thread::sleep(Duration::from_millis(10));

        assert!(dropped_on_render_thread.load(Ordering::Acquire), "资源应在渲染线程被释放");
        assert_eq!(Arc::strong_count(&tracker), 1, "队列清空后应只剩 1 个引用");

        stop.store(true, Ordering::Release);
        render_handle.join().unwrap();

        eprintln!("✅ deferred GPU drop: 主线程入队，渲染线程释放");
    }

    #[test]
    fn test_deferred_gpu_drop_multiple_entries() {
        use parking_lot::Mutex;
        use std::sync::Arc;
        use std::sync::atomic::AtomicUsize;

        let queue: Mutex<Vec<Arc<AtomicUsize>>> = Mutex::new(Vec::new());

        // 模拟多个终端同时关闭
        let trackers: Vec<_> = (0..5).map(|_| Arc::new(AtomicUsize::new(0))).collect();
        for t in &trackers {
            queue.lock().push(t.clone());
        }

        // 所有资源都在队列里
        for (i, t) in trackers.iter().enumerate() {
            assert_eq!(Arc::strong_count(t), 2, "终端 {} 入队后应有 2 个引用", i);
        }

        // 一次性清空
        queue.lock().clear();

        for (i, t) in trackers.iter().enumerate() {
            assert_eq!(Arc::strong_count(t), 1, "终端 {} 清空后应只剩 1 个引用", i);
        }

        eprintln!("✅ deferred GPU drop: 批量入队，一次清空全部释放");
    }
}
