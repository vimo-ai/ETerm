//! Hyperlink FFI - 超链接相关

use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;
use std::ffi::c_char;

/// 超链接查询结果（C ABI 兼容）
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FFIHyperlink {
    /// 超链接起始行（绝对坐标）
    pub start_row: i64,
    /// 超链接起始列
    pub start_col: u16,
    /// 超链接结束行（绝对坐标）
    pub end_row: i64,
    /// 超链接结束列
    pub end_col: u16,
    /// URI 指针（需要调用者使用 terminal_pool_free_hyperlink 释放）
    pub uri_ptr: *mut c_char,
    /// URI 长度（字节）
    pub uri_len: usize,
    /// 是否有效（true = 有超链接）
    pub valid: bool,
}

impl Default for FFIHyperlink {
    fn default() -> Self {
        Self {
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 0,
            uri_ptr: std::ptr::null_mut(),
            uri_len: 0,
            valid: false,
        }
    }
}

/// 获取指定位置的超链接
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
/// - `screen_row`: 屏幕行（0-based）
/// - `screen_col`: 屏幕列（0-based）
///
/// # 返回
/// - `FFIHyperlink`: 超链接信息，无超链接时 valid=false
///
/// # 注意
/// - 返回的 uri_ptr 需要调用者使用 `terminal_pool_free_hyperlink` 释放
/// - 如果 valid=false，uri_ptr 为 null，不需要释放
#[no_mangle]
pub extern "C" fn terminal_pool_get_hyperlink_at(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
    screen_row: i32,
    screen_col: i32,
) -> FFIHyperlink {
    if handle.is_null() || screen_row < 0 || screen_col < 0 {
        return FFIHyperlink::default();
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    pool.try_with_terminal(terminal_id as usize, |terminal| {
        // 使用 Terminal 的 get_hyperlink_at 方法
        if let Some((start_col, end_col, uri)) = terminal.get_hyperlink_at(
            screen_row as usize,
            screen_col as usize,
        ) {
            // 转换为绝对行号
            let state = terminal.state();
            let absolute_row = state.grid.screen_to_absolute(screen_row as usize, 0).line as i64;

            // 分配 C 字符串
            match std::ffi::CString::new(uri.as_bytes()) {
                Ok(c_string) => {
                    let ptr = c_string.into_raw();
                    FFIHyperlink {
                        start_row: absolute_row,
                        start_col: start_col as u16,
                        end_row: absolute_row,
                        end_col: end_col as u16,
                        uri_ptr: ptr,
                        uri_len: uri.len(),
                        valid: true,
                    }
                }
                Err(_) => FFIHyperlink::default(),
            }
        } else {
            FFIHyperlink::default()
        }
    }).unwrap_or(FFIHyperlink::default())
}

/// 释放超链接资源
///
/// # 参数
/// - `hyperlink`: 由 `terminal_pool_get_hyperlink_at` 返回的超链接
///
/// # 安全性
/// - 只应该对 valid=true 的超链接调用此函数
/// - 不要对同一个超链接重复释放
#[no_mangle]
pub extern "C" fn terminal_pool_free_hyperlink(hyperlink: FFIHyperlink) {
    if hyperlink.valid && !hyperlink.uri_ptr.is_null() {
        unsafe {
            let _ = std::ffi::CString::from_raw(hyperlink.uri_ptr);
        }
    }
}

/// 设置超链接悬停状态
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
/// - `start_row`: 起始行（绝对坐标）
/// - `start_col`: 起始列
/// - `end_row`: 结束行（绝对坐标）
/// - `end_col`: 结束列
/// - `uri`: 超链接 URI（C 字符串）
///
/// # 返回
/// - `true`: 设置成功
/// - `false`: 设置失败
#[no_mangle]
pub extern "C" fn terminal_pool_set_hyperlink_hover(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
    start_row: i64,
    start_col: u16,
    end_row: i64,
    end_col: u16,
    uri: *const c_char,
) -> bool {
    if handle.is_null() || uri.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    let uri_str = unsafe {
        match std::ffi::CStr::from_ptr(uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return false,
        }
    };

    pool.try_with_terminal(terminal_id as usize, |terminal| {
        terminal.set_hyperlink_hover(
            start_row as usize,
            start_col as usize,
            end_row as usize,
            end_col as usize,
            uri_str.clone(),
        );
        true
    }).unwrap_or(false)
}

/// 清除超链接悬停状态
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
///
/// # 返回
/// - `true`: 清除成功
/// - `false`: 清除失败
#[no_mangle]
pub extern "C" fn terminal_pool_clear_hyperlink_hover(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    pool.try_with_terminal(terminal_id as usize, |terminal| {
        terminal.clear_hyperlink_hover();
        true
    }).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_hyperlink_default() {
        let hyperlink = FFIHyperlink::default();
        assert_eq!(hyperlink.start_row, 0);
        assert_eq!(hyperlink.start_col, 0);
        assert_eq!(hyperlink.end_row, 0);
        assert_eq!(hyperlink.end_col, 0);
        assert!(hyperlink.uri_ptr.is_null());
        assert_eq!(hyperlink.uri_len, 0);
        assert!(!hyperlink.valid);
    }

    #[test]
    fn test_terminal_pool_get_hyperlink_at_null_handle() {
        let result = terminal_pool_get_hyperlink_at(std::ptr::null_mut(), 0, 0, 0);
        assert!(!result.valid);
        assert!(result.uri_ptr.is_null());
    }

    #[test]
    fn test_terminal_pool_free_hyperlink_invalid() {
        // 释放无效超链接不应该崩溃
        let hyperlink = FFIHyperlink::default();
        terminal_pool_free_hyperlink(hyperlink);
    }
}
