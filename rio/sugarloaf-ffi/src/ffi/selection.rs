//! Selection FFI - 选区相关

use crate::app::TerminalPool;
use crate::domain::primitives::AbsolutePoint;
use crate::domain::views::SelectionType;
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

    if let Some(terminal) = pool.get_terminal(terminal_id) {
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
    } else {
        ScreenToAbsoluteResult { absolute_row: 0, col: 0, success: false }
    }
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

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    if let Some(mut terminal) = pool.get_terminal_mut(terminal_id) {
        // 使用 start_selection + update_selection 来设置选区
        let start_pos = AbsolutePoint::new(start_absolute_row as usize, start_col);
        let end_pos = AbsolutePoint::new(end_absolute_row as usize, end_col);

        terminal.start_selection(start_pos, SelectionType::Simple);
        terminal.update_selection(end_pos);

        true
    } else {
        false
    }
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

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    if let Some(mut terminal) = pool.get_terminal_mut(terminal_id) {
        terminal.clear_selection();
        true
    } else {
        false
    }
}
