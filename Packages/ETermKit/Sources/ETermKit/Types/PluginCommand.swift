//
//  PluginCommand.swift
//  ETermKit
//
//  插件命令定义
//

import Foundation

/// 插件命令
///
/// 用于注册可通过快捷键或菜单调用的命令
public struct PluginCommand: Sendable, Codable, Equatable {

    /// 命令 ID（插件范围内唯一）
    public let id: String

    /// 命令标题（用于菜单显示）
    public let title: String

    /// 命令图标（SF Symbols 名称，可选）
    public let icon: String?

    public init(id: String, title: String, icon: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// 快捷键配置
public struct KeyboardShortcut: Sendable, Codable, Equatable, Hashable {

    /// 按键字符（如 "k", "enter", "escape"）
    public let key: String

    /// 修饰键
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// 修饰键
    public struct Modifiers: OptionSet, Sendable, Codable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    // MARK: - 便捷构造

    /// Cmd + 键
    public static func cmd(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key: key, modifiers: .command)
    }

    /// Cmd + Shift + 键
    public static func cmdShift(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key: key, modifiers: [.command, .shift])
    }

    /// Cmd + Option + 键
    public static func cmdOption(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key: key, modifiers: [.command, .option])
    }

    /// Ctrl + 键
    public static func ctrl(_ key: String) -> KeyboardShortcut {
        KeyboardShortcut(key: key, modifiers: .control)
    }
}
