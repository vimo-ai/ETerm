//! TerminalPool FFI - 多终端管理 + 统一渲染

use crate::app::{TerminalPool, AppConfig};
use crate::app::ffi::TerminalPoolEventCallback;
use crate::SugarloafFontMetrics;
use std::ffi::c_void;

/// TerminalPool 句柄（不透明指针）
#[repr(C)]
pub struct TerminalPoolHandle {
    _private: [u8; 0],
}

/// 创建 TerminalPool
#[no_mangle]
pub extern "C" fn terminal_pool_create(config: AppConfig) -> *mut TerminalPoolHandle {
    match TerminalPool::new(config) {
        Ok(pool) => {
            let boxed = Box::new(pool);
            Box::into_raw(boxed) as *mut TerminalPoolHandle
        }
        Err(e) => {
            eprintln!("[TerminalPool FFI] Create failed: {:?}", e);
            std::ptr::null_mut()
        }
    }
}

/// 销毁 TerminalPool
#[no_mangle]
pub extern "C" fn terminal_pool_destroy(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(handle as *mut TerminalPool);
    }
}

/// 创建新终端
///
/// 返回终端 ID（>= 1），失败返回 -1
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal(
    handle: *mut TerminalPoolHandle,
    cols: u16,
    rows: u16,
) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.create_terminal(cols, rows)
}

/// 创建新终端（指定工作目录）
///
/// 返回终端 ID（>= 1），失败返回 -1
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal_with_cwd(
    handle: *mut TerminalPoolHandle,
    cols: u16,
    rows: u16,
    working_dir: *const std::ffi::c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    let working_dir_opt = if working_dir.is_null() {
        None
    } else {
        unsafe { std::ffi::CStr::from_ptr(working_dir).to_str().ok().map(|s| s.to_string()) }
    };

    pool.create_terminal_with_cwd(cols, rows, working_dir_opt)
}

/// 创建新终端（使用 Swift 传入的 ID）
///
/// 用于 Session 恢复，确保 ID 在重启后保持一致
/// 返回终端 ID，失败返回 -1
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal_with_id(
    handle: *mut TerminalPoolHandle,
    id: i64,
    cols: u16,
    rows: u16,
) -> i64 {
    if handle.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.create_terminal_with_id(id as usize, cols, rows)
}

/// 创建新终端（使用 Swift 传入的 ID + 指定工作目录）
///
/// 用于 Session 恢复，确保 ID 在重启后保持一致
/// 返回终端 ID，失败返回 -1
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal_with_id_and_cwd(
    handle: *mut TerminalPoolHandle,
    id: i64,
    cols: u16,
    rows: u16,
    working_dir: *const std::ffi::c_char,
) -> i64 {
    if handle.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    let working_dir_opt = if working_dir.is_null() {
        None
    } else {
        unsafe { std::ffi::CStr::from_ptr(working_dir).to_str().ok().map(|s| s.to_string()) }
    };

    pool.create_terminal_with_id_and_cwd(id as usize, cols, rows, working_dir_opt)
}

/// 关闭终端
#[no_mangle]
pub extern "C" fn terminal_pool_close_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.close_terminal(terminal_id)
}

/// 获取终端的当前工作目录（通过 proc_pidinfo 系统调用）
///
/// 注意：此方法获取的是前台进程的 CWD，如果有子进程运行（如 vim、claude），
/// 可能返回子进程的 CWD 而非 shell 的 CWD。
/// 推荐使用 `terminal_pool_get_cached_cwd` 获取 OSC 7 缓存的 CWD。
///
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[no_mangle]
pub extern "C" fn terminal_pool_get_cwd(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> *mut std::ffi::c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let pool = unsafe { &*(handle as *mut TerminalPool) };

    if let Some(cwd) = pool.get_cwd(terminal_id) {
        match std::ffi::CString::new(cwd.to_string_lossy().as_bytes()) {
            Ok(c_str) => c_str.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    } else {
        std::ptr::null_mut()
    }
}

/// 获取终端的缓存工作目录（通过 OSC 7）
///
/// Shell 通过 OSC 7 转义序列主动上报 CWD。此方法比 `terminal_pool_get_cwd` 更可靠：
/// - 不受子进程（如 vim、claude）干扰
/// - Shell 自己最清楚当前目录
/// - 每次 cd 后立即更新
///
/// 如果 OSC 7 缓存为空（shell 未配置或刚启动），返回 NULL。
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[no_mangle]
pub extern "C" fn terminal_pool_get_cached_cwd(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> *mut std::ffi::c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let pool = unsafe { &*(handle as *mut TerminalPool) };

    if let Some(cwd) = pool.get_cached_cwd(terminal_id) {
        match std::ffi::CString::new(cwd.to_string_lossy().as_bytes()) {
            Ok(c_str) => c_str.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    } else {
        std::ptr::null_mut()
    }
}

/// 获取终端的前台进程名称
///
/// 返回当前前台进程的名称（如 "vim", "cargo", "python" 等）
/// 如果前台进程就是 shell 本身，返回 shell 名称（如 "zsh", "bash"）
///
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[no_mangle]
pub extern "C" fn terminal_pool_get_foreground_process_name(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> *mut std::ffi::c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let pool = unsafe { &*(handle as *mut TerminalPool) };

    if let Some(name) = pool.get_foreground_process_name(terminal_id) {
        match std::ffi::CString::new(name) {
            Ok(c_str) => c_str.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    } else {
        std::ptr::null_mut()
    }
}

/// 检查终端是否有正在运行的子进程（非 shell）
///
/// 返回 true 如果前台进程不是 shell 本身（如正在运行 vim, cargo, python 等）
#[no_mangle]
pub extern "C" fn terminal_pool_has_running_process(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *mut TerminalPool) };
    pool.has_running_process(terminal_id)
}

/// 检查终端是否启用了 Bracketed Paste Mode
///
/// 当启用时（应用程序发送了 \x1b[?2004h），粘贴时应该用转义序列包裹内容。
/// 当未启用时，直接发送原始文本。
///
/// # 返回
/// - true: 启用了 Bracketed Paste Mode，粘贴时需要添加 \x1b[200~ 和 \x1b[201~
/// - false: 未启用，直接发送原始文本
#[no_mangle]
pub extern "C" fn terminal_pool_is_bracketed_paste_enabled(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.is_bracketed_paste_enabled(terminal_id)
}

/// 调整终端大小
#[no_mangle]
pub extern "C" fn terminal_pool_resize_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    cols: u16,
    rows: u16,
    width: f32,
    height: f32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.resize_terminal(terminal_id, cols, rows, width, height)
}

/// 发送输入到终端
#[no_mangle]
pub extern "C" fn terminal_pool_input(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    data: *const u8,
    len: usize,
) -> bool {
    if handle.is_null() || data.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    let data_slice = unsafe { std::slice::from_raw_parts(data, len) };
    pool.input(terminal_id, data_slice)
}

/// 滚动终端
#[no_mangle]
pub extern "C" fn terminal_pool_scroll(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    delta: i32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.scroll(terminal_id, delta)
}

// ===== 渲染流程（统一提交）=====

/// 开始新的一帧（清空待渲染列表）
#[no_mangle]
pub extern "C" fn terminal_pool_begin_frame(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.begin_frame();
}

/// 渲染终端到指定位置（累积到待渲染列表）
///
/// # 参数
/// - terminal_id: 终端 ID
/// - x, y: 渲染位置（逻辑坐标）
/// - width, height: 终端区域大小（逻辑坐标）
///   - 如果 > 0，会自动计算 cols/rows 并 resize
///   - 如果 = 0，不执行 resize（保持当前尺寸）
#[no_mangle]
pub extern "C" fn terminal_pool_render_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.render_terminal(terminal_id, x, y, width, height)
}

/// 结束帧（统一提交渲染）
#[no_mangle]
pub extern "C" fn terminal_pool_end_frame(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.end_frame();
}

/// 调整 Sugarloaf 渲染表面大小
#[no_mangle]
pub extern "C" fn terminal_pool_resize_sugarloaf(
    handle: *mut TerminalPoolHandle,
    width: f32,
    height: f32,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.resize_sugarloaf(width, height);
}

/// 设置 DPI 缩放（窗口在不同 DPI 屏幕间移动时调用）
///
/// 当窗口从一个屏幕移动到另一个 DPI 不同的屏幕时，Swift 端需要调用此函数
/// 更新 Rust 端的 scale factor，确保：
/// - 字体度量计算正确
/// - 选区坐标转换正确
/// - 渲染位置计算正确
#[no_mangle]
pub extern "C" fn terminal_pool_set_scale(
    handle: *mut TerminalPoolHandle,
    scale: f32,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.set_scale(scale);
}

/// 设置事件回调
#[no_mangle]
pub extern "C" fn terminal_pool_set_event_callback(
    handle: *mut TerminalPoolHandle,
    callback: TerminalPoolEventCallback,
    context: *mut c_void,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.set_event_callback(callback, context);
}

/// 获取终端数量
#[no_mangle]
pub extern "C" fn terminal_pool_terminal_count(handle: *mut TerminalPoolHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.terminal_count()
}

/// 检查是否需要渲染
#[no_mangle]
pub extern "C" fn terminal_pool_needs_render(handle: *mut TerminalPoolHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.needs_render()
}

/// 清除渲染标记
#[no_mangle]
pub extern "C" fn terminal_pool_clear_render_flag(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.clear_render_flag();
}

/// 获取字体度量（物理像素）
///
/// 返回与渲染一致的字体度量：
/// - cell_width: 单元格宽度（物理像素）
/// - cell_height: 基础单元格高度（物理像素，不含 line_height_factor）
/// - line_height: 实际行高（物理像素，= cell_height * line_height_factor）
///
/// 注意：鼠标坐标转换应使用 line_height（而非 cell_height）
#[no_mangle]
pub extern "C" fn terminal_pool_get_font_metrics(
    handle: *mut TerminalPoolHandle,
    out_metrics: *mut SugarloafFontMetrics,
) -> bool {
    if handle.is_null() || out_metrics.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    let (cell_width, cell_height, line_height) = pool.get_font_metrics();

    unsafe {
        (*out_metrics).cell_width = cell_width;
        (*out_metrics).cell_height = cell_height;
        (*out_metrics).line_height = line_height;
    }

    true
}

/// 调整字体大小
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - operation: 0=重置(14pt), 1=减小(-1pt), 2=增大(+1pt)
///
/// # 返回
/// - true: 成功
/// - false: 句柄无效
#[no_mangle]
pub extern "C" fn terminal_pool_change_font_size(
    handle: *mut TerminalPoolHandle,
    operation: u8,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.change_font_size(operation);
    true
}

/// 获取当前字体大小
///
/// # 参数
/// - handle: TerminalPool 句柄
///
/// # 返回
/// - 当前字体大小（pt），如果句柄无效返回 0.0
#[no_mangle]
pub extern "C" fn terminal_pool_get_font_size(
    handle: *mut TerminalPoolHandle,
) -> f32 {
    if handle.is_null() {
        return 0.0;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.get_font_size()
}

// ===== 搜索功能 =====

/// 搜索文本
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
/// - query: 搜索关键词（C 字符串）
///
/// # 返回
/// - 匹配数量（>= 0），失败返回 -1
#[no_mangle]
pub extern "C" fn terminal_pool_search(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    query: *const std::ffi::c_char,
) -> i32 {
    if handle.is_null() || query.is_null() {
        return -1;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 转换 C 字符串为 Rust 字符串
    let query_str = match unsafe { std::ffi::CStr::from_ptr(query).to_str() } {
        Ok(s) => s,
        Err(_) => return -1,
    };

    pool.search(terminal_id, query_str)
}

/// 跳转到下一个匹配
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
#[no_mangle]
pub extern "C" fn terminal_pool_search_next(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.search_next(terminal_id);
}

/// 跳转到上一个匹配
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
#[no_mangle]
pub extern "C" fn terminal_pool_search_prev(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.search_prev(terminal_id);
}

/// 清除搜索
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
#[no_mangle]
pub extern "C" fn terminal_pool_clear_search(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.clear_search(terminal_id);
}

// ===== 渲染布局（新架构） =====

/// 渲染布局信息
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TerminalRenderLayout {
    pub terminal_id: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// 设置渲染布局（新架构）
///
/// Swift 侧在布局变化时调用（Tab 切换、窗口 resize 等）
/// Rust 侧在 VSync 时使用此布局进行渲染
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - layout: 布局数组
/// - count: 布局数量
/// - container_height: 容器高度（用于坐标转换）
///
/// # 注意
/// 坐标应已转换为 Rust 坐标系（Y 从顶部开始）
#[no_mangle]
pub extern "C" fn terminal_pool_set_render_layout(
    handle: *mut TerminalPoolHandle,
    layout: *const TerminalRenderLayout,
    count: usize,
    container_height: f32,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    let layouts = if layout.is_null() || count == 0 {
        Vec::new()
    } else {
        let slice = unsafe { std::slice::from_raw_parts(layout, count) };
        slice
            .iter()
            .map(|l| (l.terminal_id, l.x, l.y, l.width, l.height))
            .collect()
    };

    pool.set_render_layout(layouts, container_height);
}

/// 触发一次完整渲染（新架构）
///
/// 通常不需要手动调用，RenderScheduler 会自动在 VSync 时调用
/// 此接口用于特殊情况（如初始化、强制刷新）
#[no_mangle]
pub extern "C" fn terminal_pool_render_all(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.render_all();
}

// ===== 终端模式管理 =====

/// 设置终端运行模式
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
/// - mode: 运行模式（0=Active, 1=Background）
///
/// # 说明
/// - Active 模式：完整处理 + 触发渲染回调
/// - Background 模式：完整 VTE 解析但不触发渲染回调（节省 CPU/GPU）
/// - 切换到 Active 时会自动触发一次渲染刷新
#[no_mangle]
pub extern "C" fn terminal_pool_set_mode(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    mode: u8,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 转换 mode 值
    let terminal_mode = match mode {
        0 => crate::domain::aggregates::TerminalMode::Active,
        1 => crate::domain::aggregates::TerminalMode::Background,
        _ => return, // 无效模式，忽略
    };

    pool.set_terminal_mode(terminal_id, terminal_mode);
}

/// 获取终端运行模式
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
///
/// # 返回
/// - 0: Active 模式
/// - 1: Background 模式
/// - 255: 终端不存在或句柄无效
#[no_mangle]
pub extern "C" fn terminal_pool_get_mode(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> u8 {
    if handle.is_null() {
        return 255;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    match pool.get_terminal_mode(terminal_id) {
        Some(mode) => mode as u8,
        None => 255,
    }
}

// ============================================================================
// 无锁 FFI 函数（从原子缓存读取）
// ============================================================================

/// 滚动信息结果（无锁读取）
#[repr(C)]
pub struct ScrollInfo {
    /// 当前显示偏移（滚动位置）
    pub display_offset: u32,
    /// 历史行数
    pub history_size: u16,
    /// 总行数
    pub total_lines: u16,
    /// 是否有效
    pub valid: bool,
}

/// 获取滚动信息（无锁）
///
/// 从原子缓存读取滚动信息，无需获取 Terminal 锁
/// 主线程可以安全调用，永不阻塞
///
/// 注意：返回的是上次渲染时的快照，可能与实时状态有微小差异
#[no_mangle]
pub extern "C" fn terminal_pool_get_scroll_info(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> ScrollInfo {
    if handle.is_null() {
        return ScrollInfo {
            display_offset: 0,
            history_size: 0,
            total_lines: 0,
            valid: false,
        };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 从原子缓存读取（无锁）
    if let Some((display_offset, history_size, total_lines)) = pool.get_scroll_cache(terminal_id) {
        ScrollInfo {
            display_offset,
            history_size,
            total_lines,
            valid: true,
        }
    } else {
        ScrollInfo {
            display_offset: 0,
            history_size: 0,
            total_lines: 0,
            valid: false,
        }
    }
}

// ============================================================================
// 终端迁移 API（跨窗口移动）
// ============================================================================

/// DetachedTerminal 句柄（不透明指针）
///
/// 用于在池之间传递分离的终端
#[repr(C)]
pub struct DetachedTerminalHandle {
    _private: [u8; 0],
}

/// 分离终端（用于跨池迁移）
///
/// 将终端从当前池中移除，返回 DetachedTerminal 句柄。
/// PTY 连接保持活跃，终端状态完整保留。
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 要分离的终端 ID
///
/// # 返回
/// - 成功: DetachedTerminal 句柄（非空）
/// - 失败: 空指针（终端不存在）
///
/// # 注意
/// - 返回的句柄必须使用 `terminal_pool_attach_terminal` 接收
/// - 或使用 `detached_terminal_destroy` 销毁
#[no_mangle]
pub extern "C" fn terminal_pool_detach_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> *mut DetachedTerminalHandle {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    match pool.detach_terminal(terminal_id) {
        Some(detached) => {
            let boxed = Box::new(detached);
            Box::into_raw(boxed) as *mut DetachedTerminalHandle
        }
        None => std::ptr::null_mut(),
    }
}

/// 接收分离的终端（用于跨池迁移）
///
/// 将 DetachedTerminal 添加到当前池。
///
/// # 参数
/// - handle: TerminalPool 句柄（目标池）
/// - detached: DetachedTerminal 句柄
///
/// # 返回
/// - 成功: 终端在目标池中的 ID（>= 1）
/// - 失败: -1（句柄无效）
///
/// # 注意
/// - 调用后，detached 句柄不再有效
/// - 终端会使用原来的 ID（如果不冲突）或新 ID
#[no_mangle]
pub extern "C" fn terminal_pool_attach_terminal(
    handle: *mut TerminalPoolHandle,
    detached: *mut DetachedTerminalHandle,
) -> i64 {
    if handle.is_null() || detached.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    let detached_terminal = unsafe { Box::from_raw(detached as *mut crate::app::DetachedTerminal) };

    let id = pool.attach_terminal(*detached_terminal);
    id as i64
}

/// 销毁分离的终端（不迁移，直接关闭）
///
/// 如果分离的终端不需要迁移，使用此函数释放资源。
///
/// # 参数
/// - detached: DetachedTerminal 句柄
#[no_mangle]
pub extern "C" fn detached_terminal_destroy(detached: *mut DetachedTerminalHandle) {
    if detached.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(detached as *mut crate::app::DetachedTerminal);
        // DetachedTerminal 会被 drop，PTY 连接关闭
    }
}

/// 获取分离终端的原始 ID
///
/// # 参数
/// - detached: DetachedTerminal 句柄
///
/// # 返回
/// - 成功: 终端的原始 ID
/// - 失败: -1（句柄无效）
#[no_mangle]
pub extern "C" fn detached_terminal_get_id(detached: *mut DetachedTerminalHandle) -> i64 {
    if detached.is_null() {
        return -1;
    }

    let detached_terminal = unsafe { &*(detached as *mut crate::app::DetachedTerminal) };
    detached_terminal.id as i64
}
