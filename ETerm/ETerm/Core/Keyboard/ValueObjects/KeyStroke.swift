//
//  KeyStroke.swift
//  ETerm
//
//  领域层 - 按键值对象

import AppKit

/// 按键 - 不可变值对象
///
/// 表示一次按键操作，包含键码、字符和修饰键
struct KeyStroke: Hashable {
    let keyCode: UInt16
    /// 用于快捷键匹配的基础字符（忽略修饰键影响）
    let character: String?
    /// 用于终端输入的实际字符（包含修饰键影响，如 Shift+2 = @）
    let actualCharacter: String?
    let modifiers: KeyModifiers

    // MARK: - KeyCode 到字符的映射（用于 Shift 组合键）

    /// macOS 键盘 keyCode 到基础字符的映射
    private static let keyCodeToChar: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        33: "[", 30: "]",
        39: "'", 41: ";", 43: ",", 47: ".", 44: "/",
        27: "-", 24: "=", 50: "`", 42: "\\",
    ]

    // MARK: - 从 NSEvent 构造

    static func from(_ event: NSEvent) -> KeyStroke {
        let keyCode = event.keyCode
        let modifiers = KeyModifiers.from(event.modifierFlags)

        // 对于 Cmd+Shift 和 Option 组合键，使用 keyCode 映射获取基础字符
        // 因为 charactersIgnoringModifiers 在 Shift 时会返回 Shift 后的字符（如 ! 而不是 1）
        // Option+数字 在某些键盘布局下会产生特殊字符（如 Option+2 = ™）
        // 但纯 Shift 组合（如 Shift+2 输入 @）不应该被映射
        var character: String?

        let isCmdShift = modifiers.contains(.command) && modifiers.contains(.shift)
        let isOption = modifiers.contains(.option)

        if (isCmdShift || isOption), let baseChar = keyCodeToChar[keyCode] {
            // Cmd+Shift 或 Option 组合键：使用 keyCode 映射（用于快捷键匹配）
            character = baseChar
        } else {
            // 其他情况：使用 charactersIgnoringModifiers
            character = event.charactersIgnoringModifiers
        }

        // actualCharacter 用于终端输入，包含 Shift 等修饰键的影响
        let actualCharacter = event.characters

        return KeyStroke(
            keyCode: keyCode,
            character: character,
            actualCharacter: actualCharacter,
            modifiers: modifiers
        )
    }

    // MARK: - 便捷构造器

    /// Cmd + 字符
    static func cmd(_ char: String) -> KeyStroke {
        KeyStroke(keyCode: 0, character: char.lowercased(), actualCharacter: nil, modifiers: .command)
    }

    /// Cmd + Shift + 字符
    static func cmdShift(_ char: String) -> KeyStroke {
        KeyStroke(keyCode: 0, character: char.lowercased(), actualCharacter: nil, modifiers: [.command, .shift])
    }

    /// Ctrl + 字符
    static func ctrl(_ char: String) -> KeyStroke {
        KeyStroke(keyCode: 0, character: char.lowercased(), actualCharacter: nil, modifiers: .control)
    }

    /// Option + 字符
    static func option(_ char: String) -> KeyStroke {
        KeyStroke(keyCode: 0, character: char.lowercased(), actualCharacter: nil, modifiers: .option)
    }

    /// 纯字符（无修饰键）
    static func char(_ char: String) -> KeyStroke {
        KeyStroke(keyCode: 0, character: char, actualCharacter: char, modifiers: [])
    }

    /// 特殊键
    static func key(_ keyCode: UInt16, modifiers: KeyModifiers = []) -> KeyStroke {
        KeyStroke(keyCode: keyCode, character: nil, actualCharacter: nil, modifiers: modifiers)
    }

    // MARK: - 常用键码

    static let escape = key(53)
    static let `return` = key(36)
    static let tab = key(48)
    static let delete = key(51)
    static let forwardDelete = key(117)
    static let insert = key(114)
    static let leftArrow = key(123)
    static let rightArrow = key(124)
    static let downArrow = key(125)
    static let upArrow = key(126)

    // MARK: - 匹配

    /// 检查是否匹配（忽略 keyCode 为 0 的情况，用于字符匹配）
    func matches(_ other: KeyStroke) -> Bool {
        // 修饰键必须完全匹配
        guard modifiers == other.modifiers else { return false }

        // 如果都有字符，比较字符
        if let c1 = character?.lowercased(), let c2 = other.character?.lowercased() {
            return c1 == c2
        }

        // 如果都有 keyCode 且不为 0，比较 keyCode
        if keyCode != 0 && other.keyCode != 0 {
            return keyCode == other.keyCode
        }

        // 一个有字符一个有 keyCode，不匹配
        return false
    }

    // MARK: - 转换为终端序列

    /// 转换为终端序列（使用 Xterm 编码）
    func toTerminalSequence() -> String {
        return toTerminalSequence(kittyMode: false)
    }

    /// 转换为终端序列（可选 Kitty 键盘协议）
    ///
    /// - Parameter kittyMode: 是否使用 Kitty 键盘协议
    ///   - true: 使用 Kitty 协议编码（CSI u 格式），支持更多修饰键组合
    ///   - false: 使用传统 Xterm 编码
    func toTerminalSequence(kittyMode: Bool) -> String {
        // 尝试使用 Rust FFI 处理特殊键
        let rustModifiers = modifiers.toRustFlags()
        let mode: UInt8 = kittyMode ? 1 : 0  // KeyboardMode_Xterm = 0, KeyboardMode_Kitty = 1

        if let seq = key_to_escape_sequence_with_mode(keyCode, rustModifiers, mode) {
            defer { free_key_sequence(seq) }
            return String(cString: seq)
        }

        // Rust 返回 NULL，说明不是特殊键，使用字符处理

        // Ctrl 组合键
        if modifiers.contains(.control), let char = character?.lowercased() {
            if let ascii = char.first?.asciiValue, ascii >= 97, ascii <= 122 {
                // Ctrl+A = 0x01, Ctrl+B = 0x02, etc.
                return String(UnicodeScalar(ascii - 96))
            }
        }

        // 普通字符：优先使用 actualCharacter（包含 Shift 等修饰键的影响）
        // 例如 Shift+2 会返回 "@" 而不是 "2"
        return actualCharacter ?? character ?? ""
    }

    // MARK: - 显示字符串（用于 UI 显示）

    /// 将快捷键转换为可读的显示格式（如 "⌘⇧T"）
    var displayString: String {
        var result = ""

        // 修饰键符号
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }

        // 特殊键名称
        switch keyCode {
        case 53: return result + "Esc"
        case 36, 76: return result + "↩"
        case 48: return result + "⇥"
        case 51: return result + "⌫"
        case 114: return result + "Ins"
        case 117: return result + "Del"
        case 123: return result + "←"
        case 124: return result + "→"
        case 125: return result + "↓"
        case 126: return result + "↑"
        default: break
        }

        // 普通字符
        if let char = character {
            result += char.uppercased()
        }

        return result
    }
}
