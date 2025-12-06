//! TerminalPool FFI - 多终端管理 + 统一渲染

use crate::app::{TerminalPool, AppConfig};
use crate::app::ffi::TerminalAppEventCallback;
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

/// 获取终端的当前工作目录
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

/// 设置事件回调
#[no_mangle]
pub extern "C" fn terminal_pool_set_event_callback(
    handle: *mut TerminalPoolHandle,
    callback: TerminalAppEventCallback,
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
