//! IME FFI - 输入法预编辑相关
//!
//! 提供 IME 预编辑状态的设置和清除接口。
//! 预编辑文本会在光标位置渲染，支持中日韩等需要组合输入的语言。

use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;
use std::ffi::c_char;

/// 设置 IME 预编辑状态
///
/// 在当前光标位置显示预编辑文本（如拼音 "nihao"）。
/// Rust 侧会从 Terminal 获取当前光标的绝对坐标。
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
/// - `text`: 预编辑文本（UTF-8 C 字符串）
/// - `cursor_offset`: 预编辑内的光标位置（字符索引，非字节）
///
/// # 返回
/// - `true`: 设置成功
/// - `false`: 设置失败（句柄无效、终端不存在、或无法获取锁）
///
/// # 示例
/// ```c
/// // Swift 调用示例
/// terminal_pool_set_ime_preedit(handle, terminalId, "nihao", 5);
/// ```
#[no_mangle]
pub extern "C" fn terminal_pool_set_ime_preedit(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
    text: *const c_char,
    cursor_offset: u32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    // 空文本指针等同于 clear
    if text.is_null() {
        return terminal_pool_clear_ime_preedit(handle, terminal_id);
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 解析 C 字符串
    let text_str = unsafe {
        match std::ffi::CStr::from_ptr(text).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return false,
        }
    };

    // 空字符串等同于 clear
    if text_str.is_empty() {
        return pool.clear_ime_preedit(terminal_id as usize);
    }

    pool.set_ime_preedit(terminal_id as usize, text_str, cursor_offset as usize)
}

/// 清除 IME 预编辑状态
///
/// 清除当前终端的预编辑文本。应在以下情况调用：
/// - 用户确认输入（commitText）
/// - 用户取消输入（cancelComposition）
/// - 终端切换
/// - 终端失去焦点
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
///
/// # 返回
/// - `true`: 清除成功
/// - `false`: 清除失败（句柄无效或终端不存在）
#[no_mangle]
pub extern "C" fn terminal_pool_clear_ime_preedit(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    pool.clear_ime_preedit(terminal_id as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_ime_preedit_null_handle() {
        let result = terminal_pool_set_ime_preedit(
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
            0,
        );
        assert!(!result);
    }

    #[test]
    fn test_clear_ime_preedit_null_handle() {
        let result = terminal_pool_clear_ime_preedit(std::ptr::null_mut(), 0);
        assert!(!result);
    }
}
