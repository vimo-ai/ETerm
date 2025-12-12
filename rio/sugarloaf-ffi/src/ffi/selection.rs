//! Selection FFI - 选区相关

use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;

/// 屏幕坐标转绝对坐标结果
#[repr(C)]
pub struct ScreenToAbsoluteResult {
    pub absolute_row: i64,
    pub col: usize,
    pub success: bool,
}

/// 屏幕坐标转绝对坐标
///
/// 将屏幕坐标（相对于可见区域）转换为绝对坐标（含历史缓冲区）
///
/// 坐标系说明：
/// - 屏幕坐标：screen_row=0 是屏幕顶部，screen_row=screen_lines-1 是屏幕底部
/// - 绝对坐标：从 0 开始，0 是历史缓冲区最开始（最旧的行）
///   - 当 history_size=0 时，absolute_row 范围是 [0, screen_lines-1]
///   - 当 history_size>0 时，absolute_row 范围是 [0, history_size+screen_lines-1]
///
/// 转换公式（考虑滚动偏移）：
/// absolute_row = history_size - display_offset + screen_row
///
/// 注意：这里的 absolute_row 总是非负数，因为：
/// - history_size >= display_offset（display_offset 不能超过历史大小）
/// - screen_row >= 0
#[no_mangle]
pub extern "C" fn terminal_pool_screen_to_absolute(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    screen_row: usize,
    screen_col: usize,
) -> ScreenToAbsoluteResult {
    if handle.is_null() {
        return ScreenToAbsoluteResult { absolute_row: 0, col: 0, success: false };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 使用 try_with_terminal 避免阻塞主线程
    pool.try_with_terminal(terminal_id, |terminal| {
        // 从 state() 获取 grid 信息
        let state = terminal.state();
        let history_size = state.grid.history_size();
        let display_offset = state.grid.display_offset();

        // 绝对行号 = history_size - display_offset + screen_row
        // 这保证结果是非负数
        let absolute_row = (history_size + screen_row).saturating_sub(display_offset) as i64;

        ScreenToAbsoluteResult {
            absolute_row,
            col: screen_col,
            success: true,
        }
    }).unwrap_or(ScreenToAbsoluteResult { absolute_row: 0, col: 0, success: false })
}

/// 设置选区
#[no_mangle]
pub extern "C" fn terminal_pool_set_selection(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    start_absolute_row: i64,
    start_col: usize,
    end_absolute_row: i64,
    end_col: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 使用 TerminalPool 的方法，会自动标记 dirty_flag
    pool.set_selection(
        terminal_id,
        start_absolute_row as usize,
        start_col,
        end_absolute_row as usize,
        end_col,
    )
}

/// 清除选区
#[no_mangle]
pub extern "C" fn terminal_pool_clear_selection(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 使用 TerminalPool 的方法，会自动标记 dirty_flag
    pool.clear_selection(terminal_id)
}

/// 完成选区结果
#[repr(C)]
pub struct FinalizeSelectionResult {
    /// 选中的文本（UTF-8，调用者负责释放）
    pub text: *mut std::os::raw::c_char,
    /// 文本长度（不含 null 终止符）
    pub text_len: usize,
    /// 是否有有效选区（非空白内容）
    pub has_selection: bool,
}

/// 完成选区（mouseUp 时调用）
///
/// 业务逻辑：
/// - 检查选区内容是否全为空白
/// - 如果全是空白，自动清除选区，返回 has_selection=false
/// - 如果有内容，保留选区，返回选中的文本
///
/// 调用者需要用 `terminal_pool_free_string` 释放返回的文本
#[no_mangle]
pub extern "C" fn terminal_pool_finalize_selection(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> FinalizeSelectionResult {
    if handle.is_null() {
        return FinalizeSelectionResult {
            text: std::ptr::null_mut(),
            text_len: 0,
            has_selection: false,
        };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 使用 TerminalPool 的方法，会自动标记 dirty_flag（如果清除了选区）
    match pool.finalize_selection(terminal_id) {
        Some(text) => {
            let text_len = text.len();
            let c_string = std::ffi::CString::new(text).unwrap_or_default();
            FinalizeSelectionResult {
                text: c_string.into_raw(),
                text_len,
                has_selection: true,
            }
        }
        None => FinalizeSelectionResult {
            text: std::ptr::null_mut(),
            text_len: 0,
            has_selection: false,
        },
    }
}

/// 释放 finalize_selection 返回的字符串
#[no_mangle]
pub extern "C" fn terminal_pool_free_string(ptr: *mut std::os::raw::c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = std::ffi::CString::from_raw(ptr);
        }
    }
}

/// 获取选中文本结果
#[repr(C)]
pub struct GetSelectionTextResult {
    /// 选中的文本（UTF-8，调用者负责释放）
    pub text: *mut std::os::raw::c_char,
    /// 文本长度（不含 null 终止符）
    pub text_len: usize,
    /// 是否成功
    pub success: bool,
}

/// 获取选中的文本（不清除选区）
///
/// 用于 Cmd+C 复制等场景
///
/// 调用者需要用 `terminal_pool_free_string` 释放返回的文本
#[no_mangle]
pub extern "C" fn terminal_pool_get_selection_text(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> GetSelectionTextResult {
    if handle.is_null() {
        return GetSelectionTextResult {
            text: std::ptr::null_mut(),
            text_len: 0,
            success: false,
        };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 使用 try_with_terminal 避免阻塞主线程
    pool.try_with_terminal(terminal_id, |terminal| {
        match terminal.selection_text() {
            Some(text) => {
                let text_len = text.len();
                let c_string = std::ffi::CString::new(text).unwrap_or_default();
                GetSelectionTextResult {
                    text: c_string.into_raw(),
                    text_len,
                    success: true,
                }
            }
            None => GetSelectionTextResult {
                text: std::ptr::null_mut(),
                text_len: 0,
                success: false,
            },
        }
    }).unwrap_or(GetSelectionTextResult {
        text: std::ptr::null_mut(),
        text_len: 0,
        success: false,
    })
}

// ============================================================================
// 无锁 FFI 函数（从原子缓存读取）
// ============================================================================

/// 选区范围结果（无锁读取）
#[repr(C)]
pub struct SelectionRange {
    /// 起始行（绝对行号）
    pub start_row: i32,
    /// 起始列
    pub start_col: u32,
    /// 结束行（绝对行号）
    pub end_row: i32,
    /// 结束列
    pub end_col: u32,
    /// 是否有有效选区
    pub has_selection: bool,
}

/// 获取选区范围（无锁）
///
/// 从原子缓存读取选区范围，无需获取 Terminal 锁
/// 主线程可以安全调用，永不阻塞
///
/// 注意：返回的是上次渲染时的快照，可能与实时状态有微小差异
#[no_mangle]
pub extern "C" fn terminal_pool_get_selection_range(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> SelectionRange {
    if handle.is_null() {
        return SelectionRange {
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 0,
            has_selection: false,
        };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 从原子缓存读取（无锁）
    if let Some((start_row, start_col, end_row, end_col)) = pool.get_selection_cache(terminal_id) {
        SelectionRange {
            start_row,
            start_col,
            end_row,
            end_col,
            has_selection: true,
        }
    } else {
        SelectionRange {
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 0,
            has_selection: false,
        }
    }
}
