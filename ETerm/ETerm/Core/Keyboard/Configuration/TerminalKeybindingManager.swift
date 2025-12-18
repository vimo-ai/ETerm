//
//  TerminalKeybindingManager.swift
//  ETerm
//
//  终端按键映射管理器
//
//  提供类似 iTerm2 的 keybinding 功能，允许用户配置特定按键组合
//  发送自定义的终端序列。这解决了传统 Xterm 协议无法区分某些按键组合的问题
//  （如 Shift+Enter 和 Enter 在 Xterm 模式下都是 \r）。

import Foundation

/// 终端按键映射配置
struct TerminalKeybinding: Codable, Equatable, Identifiable {
    var id: String { "\(keyCode)-\(modifiers)" }

    /// macOS keyCode
    let keyCode: UInt16

    /// 修饰键（位标志）
    let modifiers: UInt

    /// 要发送的序列（支持转义字符如 \x1b）
    let sequence: String

    /// 描述（用于 UI 显示）
    let description: String

    /// 是否启用
    var enabled: Bool

    /// 将配置的序列转换为实际的字节序列
    func resolvedSequence() -> String {
        // 解析转义序列
        var result = ""
        var chars = sequence.makeIterator()

        while let char = chars.next() {
            if char == "\\" {
                if let next = chars.next() {
                    switch next {
                    case "x":
                        // \xHH 格式
                        var hex = ""
                        if let h1 = chars.next() { hex.append(h1) }
                        if let h2 = chars.next() { hex.append(h2) }
                        if let value = UInt8(hex, radix: 16) {
                            result.append(Character(UnicodeScalar(value)))
                        }
                    case "e", "E":
                        // \e = ESC
                        result.append("\u{1b}")
                    case "n":
                        result.append("\n")
                    case "r":
                        result.append("\r")
                    case "t":
                        result.append("\t")
                    case "\\":
                        result.append("\\")
                    default:
                        result.append("\\")
                        result.append(next)
                    }
                }
            } else {
                result.append(char)
            }
        }

        return result
    }
}

/// 终端按键映射管理器
final class TerminalKeybindingManager {
    static let shared = TerminalKeybindingManager()

    private let userDefaultsKey = "TerminalKeybindings"

    /// 当前的按键映射配置
    private(set) var keybindings: [TerminalKeybinding] = []

    /// 快速查找表：(keyCode, modifiers) -> sequence
    private var lookupTable: [String: String] = [:]

    private init() {
        migrateIfNeeded()
        loadKeybindings()
        buildLookupTable()
    }

    /// 迁移旧配置
    private func migrateIfNeeded() {
        let migrationKey = "TerminalKeybindings_v2_migrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        // 清除旧配置，使用新默认值
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    // MARK: - 默认配置

    /// 默认的按键映射
    static var defaultKeybindings: [TerminalKeybinding] {
        // KeyModifiers 位格式: command=0, shift=1, control=2, option=3
        let shiftBit: UInt = 1 << 1      // = 2
        let controlBit: UInt = 1 << 2    // = 4

        return [
            // Shift+Enter: 发送换行符
            // 用于 Claude Code 等需要区分 Enter（提交）和 Shift+Enter（换行）的应用
            TerminalKeybinding(
                keyCode: 36,  // Return
                modifiers: shiftBit,
                sequence: "\\n",
                description: "Shift+Enter → 换行",
                enabled: true
            ),

            // Ctrl+Shift+Enter: 发送 Kitty 协议格式（供支持的应用使用）
            TerminalKeybinding(
                keyCode: 36,
                modifiers: shiftBit | controlBit,
                sequence: "\\x1b[13;6u",
                description: "Ctrl+Shift+Enter (Kitty)",
                enabled: true
            ),
        ]
    }

    // MARK: - 查询

    /// 查找按键对应的自定义序列
    ///
    /// - Parameters:
    ///   - keyCode: macOS keyCode
    ///   - modifiers: 修饰键
    /// - Returns: 自定义序列，如果没有配置则返回 nil
    func findSequence(keyCode: UInt16, modifiers: KeyModifiers) -> String? {
        let key = makeKey(keyCode: keyCode, modifiers: modifiers.rawValue)
        return lookupTable[key]
    }

    /// 检查是否有该按键的自定义映射
    func hasKeybinding(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        return findSequence(keyCode: keyCode, modifiers: modifiers) != nil
    }

    // MARK: - 配置管理

    /// 添加或更新按键映射
    func setKeybinding(_ keybinding: TerminalKeybinding) {
        // 移除已存在的相同按键映射
        keybindings.removeAll { $0.keyCode == keybinding.keyCode && $0.modifiers == keybinding.modifiers }
        keybindings.append(keybinding)
        saveKeybindings()
        buildLookupTable()
    }

    /// 移除按键映射
    func removeKeybinding(keyCode: UInt16, modifiers: UInt) {
        keybindings.removeAll { $0.keyCode == keyCode && $0.modifiers == modifiers }
        saveKeybindings()
        buildLookupTable()
    }

    /// 启用/禁用按键映射
    func setEnabled(_ enabled: Bool, keyCode: UInt16, modifiers: UInt) {
        if let index = keybindings.firstIndex(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) {
            keybindings[index].enabled = enabled
            saveKeybindings()
            buildLookupTable()
        }
    }

    /// 重置为默认配置
    func resetToDefaults() {
        keybindings = Self.defaultKeybindings
        saveKeybindings()
        buildLookupTable()
    }

    // MARK: - 持久化

    private func loadKeybindings() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([TerminalKeybinding].self, from: data) {
            keybindings = decoded
        } else {
            // 首次运行，使用默认配置
            keybindings = Self.defaultKeybindings
            saveKeybindings()
        }
    }

    private func saveKeybindings() {
        if let data = try? JSONEncoder().encode(keybindings) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func buildLookupTable() {
        lookupTable.removeAll()
        for keybinding in keybindings where keybinding.enabled {
            let key = makeKey(keyCode: keybinding.keyCode, modifiers: keybinding.modifiers)
            lookupTable[key] = keybinding.resolvedSequence()
        }
    }

    private func makeKey(keyCode: UInt16, modifiers: UInt) -> String {
        return "\(keyCode)-\(modifiers)"
    }
}

