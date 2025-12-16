//! 键盘序列转换模块 - 将键盘事件转换为终端转义序列
//!
//! 实现标准的 xterm/VT 转义序列生成，支持修饰键组合。
//!
//! CSI 序列格式：
//! - 无修饰键：ESC [ <code> <suffix>
//! - 有修饰键：ESC [ <code> ; <modifier> <suffix>
//!
//! 修饰键参数计算：1 + shift*1 + alt*2 + ctrl*4 + meta*8

use std::ffi::{c_char, CString};
use std::ptr;
use super::ffi_boundary;

// ============================================================================
// macOS KeyCode 常量（与 Swift NSEvent.keyCode 对应）
// ============================================================================

const KEY_RETURN: u16 = 36;
const KEY_TAB: u16 = 48;
const KEY_DELETE: u16 = 51;      // Backspace
const KEY_ESCAPE: u16 = 53;
const KEY_ENTER: u16 = 76;       // Numpad Enter
const KEY_INSERT: u16 = 114;     // Help/Insert
const KEY_FORWARD_DELETE: u16 = 117;
const KEY_HOME: u16 = 115;
const KEY_END: u16 = 119;
const KEY_PAGE_UP: u16 = 116;
const KEY_PAGE_DOWN: u16 = 121;
const KEY_LEFT: u16 = 123;
const KEY_RIGHT: u16 = 124;
const KEY_DOWN: u16 = 125;
const KEY_UP: u16 = 126;

// Function keys
const KEY_F1: u16 = 122;
const KEY_F2: u16 = 120;
const KEY_F3: u16 = 99;
const KEY_F4: u16 = 118;
const KEY_F5: u16 = 96;
const KEY_F6: u16 = 97;
const KEY_F7: u16 = 98;
const KEY_F8: u16 = 100;
const KEY_F9: u16 = 101;
const KEY_F10: u16 = 109;
const KEY_F11: u16 = 103;
const KEY_F12: u16 = 111;

// ============================================================================
// 修饰键位标志（与 Swift KeyModifiers 对应）
// ============================================================================

const MOD_SHIFT: u32 = 1 << 0;
const MOD_CONTROL: u32 = 1 << 1;
const MOD_OPTION: u32 = 1 << 2;   // Alt
const MOD_COMMAND: u32 = 1 << 3;  // Meta/Super

// ============================================================================
// 核心转换逻辑
// ============================================================================

/// 计算 CSI 序列的修饰键参数
///
/// 标准格式：1 + shift*1 + alt*2 + ctrl*4 + meta*8
fn modifier_param(modifiers: u32) -> u32 {
    let mut param = 1;
    if modifiers & MOD_SHIFT != 0 { param += 1; }
    if modifiers & MOD_OPTION != 0 { param += 2; }
    if modifiers & MOD_CONTROL != 0 { param += 4; }
    if modifiers & MOD_COMMAND != 0 { param += 8; }
    param
}

/// 生成 CSI 序列
///
/// - `code`: 基础代码（如方向键的 "1"，PageUp 的 "5"）
/// - `suffix`: 终止符（如方向键的 "A"/"B"/"C"/"D"，PageUp 的 "~"）
/// - `modifiers`: 修饰键位标志
fn build_csi_sequence(code: &str, suffix: &str, modifiers: u32) -> String {
    let mod_param = modifier_param(modifiers);
    if mod_param > 1 {
        // 有修饰键：ESC [ <code> ; <mod> <suffix>
        if code.is_empty() {
            format!("\x1b[1;{}{}", mod_param, suffix)
        } else {
            format!("\x1b[{};{}{}", code, mod_param, suffix)
        }
    } else {
        // 无修饰键：ESC [ <code> <suffix> 或 ESC [ <suffix>
        if code.is_empty() {
            format!("\x1b[{}", suffix)
        } else {
            format!("\x1b[{}{}", code, suffix)
        }
    }
}

/// 将 macOS keyCode + modifiers 转换为终端转义序列
///
/// 返回 None 表示该键不是特殊键，应使用字符输入
fn key_to_sequence(key_code: u16, modifiers: u32) -> Option<String> {
    // 过滤纯 Command 组合键（通常由应用层处理，不发送到终端）
    // 但 Cmd+方向键 在 macOS 终端中有特殊含义（跳到行首/行尾）
    let is_cmd_only = modifiers == MOD_COMMAND;

    match key_code {
        // Return / Enter
        KEY_RETURN | KEY_ENTER => Some("\r".to_string()),

        // Tab
        KEY_TAB => {
            if modifiers & MOD_SHIFT != 0 {
                Some("\x1b[Z".to_string())  // Shift+Tab: CSI Z (Backtab)
            } else {
                Some("\t".to_string())
            }
        }

        // Escape
        KEY_ESCAPE => Some("\x1b".to_string()),

        // Delete (Backspace)
        KEY_DELETE => {
            if modifiers & MOD_OPTION != 0 {
                Some("\x17".to_string())  // Option+Delete: Ctrl+W
            } else if modifiers & MOD_COMMAND != 0 {
                Some("\x15".to_string())  // Cmd+Delete: Ctrl+U
            } else {
                Some("\x7f".to_string())
            }
        }

        // Forward Delete
        KEY_FORWARD_DELETE => Some(build_csi_sequence("3", "~", modifiers)),

        // Insert
        KEY_INSERT => Some(build_csi_sequence("2", "~", modifiers)),

        // Home / End
        KEY_HOME => Some(build_csi_sequence("", "H", modifiers)),
        KEY_END => Some(build_csi_sequence("", "F", modifiers)),

        // Page Up / Down
        KEY_PAGE_UP => Some(build_csi_sequence("5", "~", modifiers)),
        KEY_PAGE_DOWN => Some(build_csi_sequence("6", "~", modifiers)),

        // Arrow keys
        KEY_UP => {
            if is_cmd_only {
                None  // Cmd+Up 通常由应用层处理
            } else {
                Some(build_csi_sequence("", "A", modifiers))
            }
        }
        KEY_DOWN => {
            if is_cmd_only {
                None
            } else {
                Some(build_csi_sequence("", "B", modifiers))
            }
        }
        KEY_RIGHT => {
            if modifiers & MOD_OPTION != 0 && modifiers & MOD_COMMAND == 0 {
                Some("\x1bf".to_string())  // Option+Right: ESC f (forward word)
            } else if is_cmd_only {
                Some("\x05".to_string())  // Cmd+Right: Ctrl+E (end of line)
            } else {
                Some(build_csi_sequence("", "C", modifiers))
            }
        }
        KEY_LEFT => {
            if modifiers & MOD_OPTION != 0 && modifiers & MOD_COMMAND == 0 {
                Some("\x1bb".to_string())  // Option+Left: ESC b (backward word)
            } else if is_cmd_only {
                Some("\x01".to_string())  // Cmd+Left: Ctrl+A (beginning of line)
            } else {
                Some(build_csi_sequence("", "D", modifiers))
            }
        }

        // Function keys (F1-F12)
        // F1-F4 使用 SS3 序列 (ESC O P/Q/R/S)，F5+ 使用 CSI 序列
        KEY_F1 => Some(build_f_key_sequence(1, modifiers)),
        KEY_F2 => Some(build_f_key_sequence(2, modifiers)),
        KEY_F3 => Some(build_f_key_sequence(3, modifiers)),
        KEY_F4 => Some(build_f_key_sequence(4, modifiers)),
        KEY_F5 => Some(build_f_key_sequence(5, modifiers)),
        KEY_F6 => Some(build_f_key_sequence(6, modifiers)),
        KEY_F7 => Some(build_f_key_sequence(7, modifiers)),
        KEY_F8 => Some(build_f_key_sequence(8, modifiers)),
        KEY_F9 => Some(build_f_key_sequence(9, modifiers)),
        KEY_F10 => Some(build_f_key_sequence(10, modifiers)),
        KEY_F11 => Some(build_f_key_sequence(11, modifiers)),
        KEY_F12 => Some(build_f_key_sequence(12, modifiers)),

        _ => None,
    }
}

/// 生成功能键序列
///
/// F1-F4: ESC O P/Q/R/S (无修饰键) 或 ESC [1;mod P/Q/R/S (有修饰键)
/// F5-F12: ESC [15~, ESC [17~, ... (标准 CSI 序列)
fn build_f_key_sequence(f_num: u8, modifiers: u32) -> String {
    let mod_param = modifier_param(modifiers);

    match f_num {
        1..=4 => {
            let suffix = match f_num {
                1 => "P",
                2 => "Q",
                3 => "R",
                4 => "S",
                _ => unreachable!(),
            };
            if mod_param > 1 {
                format!("\x1b[1;{}{}", mod_param, suffix)
            } else {
                format!("\x1bO{}", suffix)  // SS3 序列
            }
        }
        5..=12 => {
            let code = match f_num {
                5 => "15",
                6 => "17",
                7 => "18",
                8 => "19",
                9 => "20",
                10 => "21",
                11 => "23",
                12 => "24",
                _ => unreachable!(),
            };
            build_csi_sequence(code, "~", modifiers)
        }
        _ => String::new(),
    }
}

// ============================================================================
// FFI 接口
// ============================================================================

/// 将键盘事件转换为终端转义序列
///
/// # 参数
/// - `key_code`: macOS keyCode (NSEvent.keyCode)
/// - `modifiers`: 修饰键位标志
///   - bit 0: Shift
///   - bit 1: Control
///   - bit 2: Option (Alt)
///   - bit 3: Command (Meta)
///
/// # 返回值
/// - 成功：指向转义序列字符串的指针（调用方负责用 `free_key_sequence` 释放）
/// - 失败/非特殊键：null
///
/// # 示例
/// ```c
/// const char* seq = key_to_escape_sequence(126, 1);  // Shift+Up
/// if (seq) {
///     write(pty_fd, seq, strlen(seq));
///     free_key_sequence(seq);
/// }
/// ```
#[no_mangle]
pub extern "C" fn key_to_escape_sequence(key_code: u16, modifiers: u32) -> *const c_char {
    ffi_boundary(ptr::null(), || {
        match key_to_sequence(key_code, modifiers) {
            Some(seq) => {
                match CString::new(seq) {
                    Ok(c_str) => c_str.into_raw() as *const c_char,
                    Err(_) => ptr::null(),
                }
            }
            None => ptr::null(),
        }
    })
}

/// 释放 `key_to_escape_sequence` 返回的字符串
///
/// # Safety
/// - `ptr` 必须是由 `key_to_escape_sequence` 返回的指针
/// - 每个指针只能释放一次
#[no_mangle]
pub extern "C" fn free_key_sequence(ptr: *const c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr as *mut c_char));
        }
    }
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tab() {
        assert_eq!(key_to_sequence(KEY_TAB, 0), Some("\t".to_string()));
        assert_eq!(key_to_sequence(KEY_TAB, MOD_SHIFT), Some("\x1b[Z".to_string()));
    }

    #[test]
    fn test_arrows() {
        // 无修饰键
        assert_eq!(key_to_sequence(KEY_UP, 0), Some("\x1b[A".to_string()));
        assert_eq!(key_to_sequence(KEY_DOWN, 0), Some("\x1b[B".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, 0), Some("\x1b[C".to_string()));
        assert_eq!(key_to_sequence(KEY_LEFT, 0), Some("\x1b[D".to_string()));

        // Shift+Arrow
        assert_eq!(key_to_sequence(KEY_UP, MOD_SHIFT), Some("\x1b[1;2A".to_string()));

        // Ctrl+Arrow
        assert_eq!(key_to_sequence(KEY_UP, MOD_CONTROL), Some("\x1b[1;5A".to_string()));

        // Ctrl+Shift+Arrow
        assert_eq!(key_to_sequence(KEY_UP, MOD_CONTROL | MOD_SHIFT), Some("\x1b[1;6A".to_string()));
    }

    #[test]
    fn test_option_arrows() {
        // Option+Left/Right 是 macOS 标准的按单词移动
        assert_eq!(key_to_sequence(KEY_LEFT, MOD_OPTION), Some("\x1bb".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, MOD_OPTION), Some("\x1bf".to_string()));
    }

    #[test]
    fn test_cmd_arrows() {
        // Cmd+Left/Right 是 macOS 标准的跳到行首/行尾
        assert_eq!(key_to_sequence(KEY_LEFT, MOD_COMMAND), Some("\x01".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, MOD_COMMAND), Some("\x05".to_string()));
    }

    #[test]
    fn test_function_keys() {
        // F1 无修饰键：SS3 序列
        assert_eq!(key_to_sequence(KEY_F1, 0), Some("\x1bOP".to_string()));

        // F1 有修饰键：CSI 序列
        assert_eq!(key_to_sequence(KEY_F1, MOD_SHIFT), Some("\x1b[1;2P".to_string()));

        // F5：CSI 序列
        assert_eq!(key_to_sequence(KEY_F5, 0), Some("\x1b[15~".to_string()));
        assert_eq!(key_to_sequence(KEY_F5, MOD_SHIFT), Some("\x1b[15;2~".to_string()));
    }

    #[test]
    fn test_page_keys() {
        assert_eq!(key_to_sequence(KEY_PAGE_UP, 0), Some("\x1b[5~".to_string()));
        assert_eq!(key_to_sequence(KEY_PAGE_DOWN, 0), Some("\x1b[6~".to_string()));
        assert_eq!(key_to_sequence(KEY_HOME, 0), Some("\x1b[H".to_string()));
        assert_eq!(key_to_sequence(KEY_END, 0), Some("\x1b[F".to_string()));
    }

    #[test]
    fn test_modifier_param() {
        assert_eq!(modifier_param(0), 1);
        assert_eq!(modifier_param(MOD_SHIFT), 2);
        assert_eq!(modifier_param(MOD_OPTION), 3);
        assert_eq!(modifier_param(MOD_CONTROL), 5);
        assert_eq!(modifier_param(MOD_SHIFT | MOD_CONTROL), 6);
        assert_eq!(modifier_param(MOD_SHIFT | MOD_OPTION | MOD_CONTROL), 8);
    }
}
