//! Cursor FFI - 光标相关

use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;

/// 光标位置结果
#[repr(C)]
pub struct FFICursorPosition {
    /// 光标列（从 0 开始）
    pub col: u16,
    /// 光标行（从 0 开始，相对于可见区域）
    pub row: u16,
    /// 是否有效（terminal_id 无效时为 false）
    pub valid: bool,
}

/// 获取终端光标位置（无锁）
///
/// 返回光标的屏幕坐标（相对于可见区域）
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
///
/// # 返回
/// - FFICursorPosition，失败时 valid=false, col=0, row=0
///
/// # 注意
/// - 返回的是**屏幕坐标**（相对于可见区域），不是绝对坐标
/// - row=0 表示屏幕第一行，row=rows-1 表示屏幕最后一行
/// - 如果终端正在滚动查看历史，光标可能不在可见区域
/// - **无锁**：使用原子缓存读取，永不阻塞主线程
#[no_mangle]
pub extern "C" fn terminal_pool_get_cursor(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> FFICursorPosition {
    if handle.is_null() {
        return FFICursorPosition { col: 0, row: 0, valid: false };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 优先使用原子缓存（无锁读取）
    if let Some(cursor_cache) = pool.get_cursor_cache(terminal_id) {
        if let Some((col, row, _display_offset)) = cursor_cache.read() {
            // 从原子缓存读取成功
            return FFICursorPosition {
                col,
                row,
                valid: true,
            };
        }
    }

    // 回退：使用 try_with_terminal 避免阻塞主线程
    // 如果锁被渲染线程或 PTY 线程占用，立即返回无效位置
    pool.try_with_terminal(terminal_id, |terminal| {
        // 从 state() 获取光标位置
        let state = terminal.state();
        let cursor = &state.cursor;

        // cursor.position 是绝对坐标，需要转换为屏幕坐标
        // 屏幕坐标 = 绝对坐标 - history_size + display_offset
        let grid = &state.grid;
        let history_size = grid.history_size();
        let display_offset = grid.display_offset();

        // 计算屏幕行
        // absolute_line = cursor.line()
        // screen_row = absolute_line - history_size + display_offset
        let absolute_line = cursor.line();
        let screen_row = if absolute_line >= history_size {
            // 正常情况：光标在可见区域或下方
            (absolute_line - history_size + display_offset) as i64
        } else {
            // 光标在历史缓冲区（不应该发生，但为了安全）
            -1
        };

        // 验证光标是否在可见区域
        let rows = terminal.rows();
        let valid = screen_row >= 0 && screen_row < rows as i64;

        FFICursorPosition {
            col: cursor.col() as u16,
            row: if valid { screen_row as u16 } else { 0 },
            valid,
        }
    }).unwrap_or(FFICursorPosition { col: 0, row: 0, valid: false })
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_cursor_position() {
        let valid_cursor = FFICursorPosition {
            col: 10,
            row: 5,
            valid: true,
        };

        assert_eq!(valid_cursor.col, 10);
        assert_eq!(valid_cursor.row, 5);
        assert!(valid_cursor.valid);

        let invalid_cursor = FFICursorPosition {
            col: 0,
            row: 0,
            valid: false,
        };

        assert_eq!(invalid_cursor.col, 0);
        assert_eq!(invalid_cursor.row, 0);
        assert!(!invalid_cursor.valid);
    }

    #[test]
    fn test_terminal_pool_get_cursor_null_handle() {
        let result = terminal_pool_get_cursor(std::ptr::null_mut(), 0);

        assert_eq!(result.col, 0);
        assert_eq!(result.row, 0);
        assert!(!result.valid);
    }

    #[test]
    fn test_ffi_cursor_position_size_and_alignment() {
        use std::mem::{size_of, align_of};

        let size = size_of::<FFICursorPosition>();
        assert!(size >= 5 && size <= 8, "FFICursorPosition size is {}, expected 5-8 bytes", size);

        let alignment = align_of::<FFICursorPosition>();
        assert!(alignment >= 2, "FFICursorPosition alignment is {}, expected >= 2", alignment);
    }
}
