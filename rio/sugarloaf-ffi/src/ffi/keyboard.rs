//! 键盘序列转换模块 - 将键盘事件转换为终端转义序列
//!
//! 使用 terminput 库实现标准的 xterm/VT 和 Kitty 协议转义序列生成。
//! 同时保留 macOS 特定的快捷键行为（如 Option+Arrow 按单词移动）。
//!
//! ## 编码模式
//!
//! - **Xterm**: 传统终端协议，某些组合键（如 Shift+Enter）无法区分
//! - **Kitty**: 现代协议，所有按键+修饰键组合都有唯一序列
//!
//! ## Kitty 协议协商
//!
//! 应用通过发送以下序列来启用/禁用 Kitty 模式：
//! - `CSI > flags u`: 启用 Kitty 键盘模式
//! - `CSI < u`: 禁用 Kitty 键盘模式
//! - `CSI ? u`: 查询当前模式

use std::ffi::{c_char, CString};
use std::ptr;
use super::ffi_boundary;
use terminput::{Event, KeyCode, KeyEvent, KeyModifiers, Encoding, KittyFlags};

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
// 键盘编码模式
// ============================================================================

/// 键盘编码模式
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KeyboardMode {
    /// Xterm 传统模式（默认）
    #[default]
    Xterm = 0,
    /// Kitty 键盘协议
    Kitty = 1,
}

impl From<u8> for KeyboardMode {
    fn from(value: u8) -> Self {
        match value {
            1 => KeyboardMode::Kitty,
            _ => KeyboardMode::Xterm,
        }
    }
}

// ============================================================================
// 转换辅助函数
// ============================================================================

/// 将 macOS keyCode 转换为 terminput KeyCode
fn macos_to_keycode(key_code: u16) -> Option<KeyCode> {
    match key_code {
        KEY_RETURN | KEY_ENTER => Some(KeyCode::Enter),
        KEY_TAB => Some(KeyCode::Tab),
        KEY_DELETE => Some(KeyCode::Backspace),
        KEY_ESCAPE => Some(KeyCode::Esc),
        KEY_INSERT => Some(KeyCode::Insert),
        KEY_FORWARD_DELETE => Some(KeyCode::Delete),
        KEY_HOME => Some(KeyCode::Home),
        KEY_END => Some(KeyCode::End),
        KEY_PAGE_UP => Some(KeyCode::PageUp),
        KEY_PAGE_DOWN => Some(KeyCode::PageDown),
        KEY_LEFT => Some(KeyCode::Left),
        KEY_RIGHT => Some(KeyCode::Right),
        KEY_DOWN => Some(KeyCode::Down),
        KEY_UP => Some(KeyCode::Up),
        KEY_F1 => Some(KeyCode::F(1)),
        KEY_F2 => Some(KeyCode::F(2)),
        KEY_F3 => Some(KeyCode::F(3)),
        KEY_F4 => Some(KeyCode::F(4)),
        KEY_F5 => Some(KeyCode::F(5)),
        KEY_F6 => Some(KeyCode::F(6)),
        KEY_F7 => Some(KeyCode::F(7)),
        KEY_F8 => Some(KeyCode::F(8)),
        KEY_F9 => Some(KeyCode::F(9)),
        KEY_F10 => Some(KeyCode::F(10)),
        KEY_F11 => Some(KeyCode::F(11)),
        KEY_F12 => Some(KeyCode::F(12)),
        _ => None,
    }
}

/// 将我们的修饰键标志转换为 terminput KeyModifiers
fn to_key_modifiers(modifiers: u32) -> KeyModifiers {
    let mut result = KeyModifiers::empty();
    if modifiers & MOD_SHIFT != 0 { result |= KeyModifiers::SHIFT; }
    if modifiers & MOD_CONTROL != 0 { result |= KeyModifiers::CTRL; }
    if modifiers & MOD_OPTION != 0 { result |= KeyModifiers::ALT; }
    if modifiers & MOD_COMMAND != 0 { result |= KeyModifiers::META; }
    result
}

/// 使用 terminput 编码按键事件
fn encode_key_event(key_code: KeyCode, modifiers: KeyModifiers, mode: KeyboardMode) -> Option<String> {
    let key_event = KeyEvent::new(key_code).modifiers(modifiers);
    let event = Event::Key(key_event);
    let mut buf = [0u8; 32];

    let encoding = match mode {
        KeyboardMode::Xterm => Encoding::Xterm,
        KeyboardMode::Kitty => Encoding::Kitty(KittyFlags::all()),
    };

    match event.encode(&mut buf, encoding) {
        Ok(len) => String::from_utf8(buf[..len].to_vec()).ok(),
        Err(_) => None,
    }
}

// ============================================================================
// 核心转换逻辑
// ============================================================================

/// 将 macOS keyCode + modifiers 转换为终端转义序列
///
/// 返回 None 表示该键不是特殊键，应使用字符输入
fn key_to_sequence(key_code: u16, modifiers: u32, mode: KeyboardMode) -> Option<String> {
    let is_cmd_only = modifiers == MOD_COMMAND;
    let has_option = modifiers & MOD_OPTION != 0;
    let has_command = modifiers & MOD_COMMAND != 0;

    // macOS 特定快捷键（这些是 macOS 终端的惯例，优先处理）
    // 注意：这些在 Kitty 模式下也保持一致，因为是 macOS 用户期望的行为
    match key_code {
        // Option+Delete → Ctrl+W (删除前一个单词)
        KEY_DELETE if has_option && !has_command => {
            return Some("\x17".to_string());
        }
        // Cmd+Delete → Ctrl+U (删除到行首)
        KEY_DELETE if has_command => {
            return Some("\x15".to_string());
        }
        // Option+Left → ESC b (后退一个单词)
        KEY_LEFT if has_option && !has_command => {
            return Some("\x1bb".to_string());
        }
        // Option+Right → ESC f (前进一个单词)
        KEY_RIGHT if has_option && !has_command => {
            return Some("\x1bf".to_string());
        }
        // Cmd+Left → Ctrl+A (行首)
        KEY_LEFT if is_cmd_only => {
            return Some("\x01".to_string());
        }
        // Cmd+Right → Ctrl+E (行尾)
        KEY_RIGHT if is_cmd_only => {
            return Some("\x05".to_string());
        }
        // Cmd+Up/Down 通常由应用层处理，不发送到终端
        KEY_UP | KEY_DOWN if is_cmd_only => {
            return None;
        }
        _ => {}
    }

    // 使用 terminput 编码标准按键
    let key_code_enum = macos_to_keycode(key_code)?;
    let key_modifiers = to_key_modifiers(modifiers);

    encode_key_event(key_code_enum, key_modifiers, mode)
}

// ============================================================================
// FFI 接口
// ============================================================================

/// 将键盘事件转换为终端转义序列（Xterm 模式）
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
#[no_mangle]
pub extern "C" fn key_to_escape_sequence(key_code: u16, modifiers: u32) -> *const c_char {
    key_to_escape_sequence_with_mode(key_code, modifiers, KeyboardMode::Xterm as u8)
}

/// 将键盘事件转换为终端转义序列（指定编码模式）
///
/// # 参数
/// - `key_code`: macOS keyCode (NSEvent.keyCode)
/// - `modifiers`: 修饰键位标志
/// - `mode`: 编码模式 (0 = Xterm, 1 = Kitty)
///
/// # 返回值
/// - 成功：指向转义序列字符串的指针（调用方负责用 `free_key_sequence` 释放）
/// - 失败/非特殊键：null
///
/// # 示例
/// ```c
/// // Xterm 模式
/// const char* seq = key_to_escape_sequence_with_mode(36, 1, 0);  // Shift+Enter (Xterm)
///
/// // Kitty 模式
/// const char* seq = key_to_escape_sequence_with_mode(36, 1, 1);  // Shift+Enter (Kitty)
/// // 返回 "\x1b[13;2u"
/// ```
#[no_mangle]
pub extern "C" fn key_to_escape_sequence_with_mode(
    key_code: u16,
    modifiers: u32,
    mode: u8,
) -> *const c_char {
    ffi_boundary(ptr::null(), || {
        let keyboard_mode = KeyboardMode::from(mode);
        match key_to_sequence(key_code, modifiers, keyboard_mode) {
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

    // ========== Xterm 模式测试 ==========

    #[test]
    fn test_enter_xterm() {
        // Enter 无修饰键
        assert_eq!(key_to_sequence(KEY_RETURN, 0, KeyboardMode::Xterm), Some("\r".to_string()));

        // Shift+Enter (Xterm 标准：和 Enter 相同)
        assert_eq!(key_to_sequence(KEY_RETURN, MOD_SHIFT, KeyboardMode::Xterm), Some("\r".to_string()));
    }

    #[test]
    fn test_tab_xterm() {
        assert_eq!(key_to_sequence(KEY_TAB, 0, KeyboardMode::Xterm), Some("\t".to_string()));
        // Shift+Tab 应该是 CSI Z
        assert_eq!(key_to_sequence(KEY_TAB, MOD_SHIFT, KeyboardMode::Xterm), Some("\x1b[Z".to_string()));
    }

    #[test]
    fn test_arrows_xterm() {
        // 无修饰键
        assert_eq!(key_to_sequence(KEY_UP, 0, KeyboardMode::Xterm), Some("\x1b[A".to_string()));
        assert_eq!(key_to_sequence(KEY_DOWN, 0, KeyboardMode::Xterm), Some("\x1b[B".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, 0, KeyboardMode::Xterm), Some("\x1b[C".to_string()));
        assert_eq!(key_to_sequence(KEY_LEFT, 0, KeyboardMode::Xterm), Some("\x1b[D".to_string()));
    }

    // ========== Kitty 模式测试 ==========

    #[test]
    fn test_enter_kitty() {
        // Enter 无修饰键 - Kitty 模式下也是 \r
        let enter = key_to_sequence(KEY_RETURN, 0, KeyboardMode::Kitty);
        assert!(enter.is_some());

        // Shift+Enter - Kitty 模式下可以区分！
        let shift_enter = key_to_sequence(KEY_RETURN, MOD_SHIFT, KeyboardMode::Kitty);
        assert!(shift_enter.is_some());
        // 应该是 CSI 13 ; 2 u
        assert_eq!(shift_enter, Some("\x1b[13;2u".to_string()));

        // Ctrl+Enter
        let ctrl_enter = key_to_sequence(KEY_RETURN, MOD_CONTROL, KeyboardMode::Kitty);
        assert!(ctrl_enter.is_some());
        // 应该是 CSI 13 ; 5 u
        assert_eq!(ctrl_enter, Some("\x1b[13;5u".to_string()));
    }

    #[test]
    fn test_tab_kitty() {
        // Shift+Tab - Kitty 模式
        let shift_tab = key_to_sequence(KEY_TAB, MOD_SHIFT, KeyboardMode::Kitty);
        assert!(shift_tab.is_some());
        // Kitty 可能使用 CSI 9 ; 2 u
        assert_eq!(shift_tab, Some("\x1b[9;2u".to_string()));
    }

    #[test]
    fn test_arrows_kitty() {
        // Shift+Up - Kitty 模式
        let shift_up = key_to_sequence(KEY_UP, MOD_SHIFT, KeyboardMode::Kitty);
        assert!(shift_up.is_some());

        // Ctrl+Shift+Up
        let ctrl_shift_up = key_to_sequence(KEY_UP, MOD_CONTROL | MOD_SHIFT, KeyboardMode::Kitty);
        assert!(ctrl_shift_up.is_some());
    }

    // ========== macOS 特定快捷键测试（两种模式下都应一致）==========

    #[test]
    fn test_macos_option_arrows() {
        // Option+Left/Right 是 macOS 标准的按单词移动
        assert_eq!(key_to_sequence(KEY_LEFT, MOD_OPTION, KeyboardMode::Xterm), Some("\x1bb".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, MOD_OPTION, KeyboardMode::Xterm), Some("\x1bf".to_string()));

        // Kitty 模式下也保持一致
        assert_eq!(key_to_sequence(KEY_LEFT, MOD_OPTION, KeyboardMode::Kitty), Some("\x1bb".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, MOD_OPTION, KeyboardMode::Kitty), Some("\x1bf".to_string()));
    }

    #[test]
    fn test_macos_cmd_arrows() {
        // Cmd+Left/Right 是 macOS 标准的跳到行首/行尾
        assert_eq!(key_to_sequence(KEY_LEFT, MOD_COMMAND, KeyboardMode::Xterm), Some("\x01".to_string()));
        assert_eq!(key_to_sequence(KEY_RIGHT, MOD_COMMAND, KeyboardMode::Xterm), Some("\x05".to_string()));

        // Cmd+Up/Down 不发送到终端
        assert_eq!(key_to_sequence(KEY_UP, MOD_COMMAND, KeyboardMode::Xterm), None);
        assert_eq!(key_to_sequence(KEY_DOWN, MOD_COMMAND, KeyboardMode::Xterm), None);
    }

    #[test]
    fn test_macos_delete_shortcuts() {
        // Option+Delete → Ctrl+W
        assert_eq!(key_to_sequence(KEY_DELETE, MOD_OPTION, KeyboardMode::Xterm), Some("\x17".to_string()));
        // Cmd+Delete → Ctrl+U
        assert_eq!(key_to_sequence(KEY_DELETE, MOD_COMMAND, KeyboardMode::Xterm), Some("\x15".to_string()));
    }

    #[test]
    fn test_function_keys() {
        // F1 无修饰键 (Xterm)
        let f1_xterm = key_to_sequence(KEY_F1, 0, KeyboardMode::Xterm);
        assert!(f1_xterm.is_some());

        // F1 无修饰键 (Kitty)
        let f1_kitty = key_to_sequence(KEY_F1, 0, KeyboardMode::Kitty);
        assert!(f1_kitty.is_some());
    }

    #[test]
    fn test_page_keys() {
        assert!(key_to_sequence(KEY_PAGE_UP, 0, KeyboardMode::Xterm).is_some());
        assert!(key_to_sequence(KEY_PAGE_DOWN, 0, KeyboardMode::Xterm).is_some());
        assert!(key_to_sequence(KEY_HOME, 0, KeyboardMode::Xterm).is_some());
        assert!(key_to_sequence(KEY_END, 0, KeyboardMode::Xterm).is_some());
    }
}
