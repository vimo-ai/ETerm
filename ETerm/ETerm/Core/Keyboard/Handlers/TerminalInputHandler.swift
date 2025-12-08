//
//  TerminalInputHandler.swift
//  ETerm
//
//  应用层 - 终端输入处理器
//
//  职责：
//  - 只处理特殊键（方向键、Delete、Tab、Enter、Escape）
//  - 只处理 Ctrl 组合键（Ctrl+C 等）
//  - 普通字符输入交给 IME 系统处理

import Foundation

/// 终端输入处理器
///
/// 只处理特殊键和 Ctrl 组合键，普通字符交给 IME
final class TerminalInputHandler {
    private weak var coordinator: TerminalWindowCoordinator?

    /// 需要直接处理的特殊键 keyCode
    private let specialKeyCodes: Set<UInt16> = [
        36,   // Return
        48,   // Tab
        51,   // Delete (Backspace)
        53,   // Escape
        114,  // Insert
        117,  // Forward Delete (Del)
        123,  // Left Arrow
        124,  // Right Arrow
        125,  // Down Arrow
        126,  // Up Arrow
        115,  // Home
        119,  // End
        116,  // Page Up
        121,  // Page Down
    ]

    init(coordinator: TerminalWindowCoordinator) {
        self.coordinator = coordinator
    }

    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult {
        guard let terminalId = context.terminalId,
              let coordinator = coordinator else {
            return .unhandled
        }

        // 特殊处理：Option+Delete 分词删除
        // 发送 Ctrl+W (0x17) - Readline/Shell 标准的删除前一个单词
        if keyStroke.keyCode == 51 && keyStroke.modifiers.contains(.option) {
            coordinator.writeInput(terminalId: terminalId, data: "\u{17}")
            return .handled
        }

        // 特殊处理：Cmd+Delete 删除到行首
        // 发送 Ctrl+U (0x15) - Readline/Shell 标准的删除到行首
        if keyStroke.keyCode == 51 && keyStroke.modifiers.contains(.command) {
            coordinator.writeInput(terminalId: terminalId, data: "\u{15}")
            return .handled
        }

        // 判断是否应该直接处理
        if shouldHandleDirectly(keyStroke) {
            // 特殊键或 Ctrl 组合键：直接发送到终端
            let sequence = keyStroke.toTerminalSequence()
            if !sequence.isEmpty {
                coordinator.writeInput(terminalId: terminalId, data: sequence)
            }
            return .handled
        }

        // 普通字符：交给 IME 处理
        return .unhandled
    }

    /// 判断是否应该直接处理（不经过 IME）
    private func shouldHandleDirectly(_ keyStroke: KeyStroke) -> Bool {
        // 1. 特殊键（方向键、Delete、Tab 等）
        if specialKeyCodes.contains(keyStroke.keyCode) {
            return true
        }

        // 2. Ctrl 组合键（Ctrl+C, Ctrl+D 等）
        if keyStroke.modifiers.contains(.control) {
            return true
        }

        // 3. Option 组合键（用于特殊字符输入，如 Option+8 = •）
        // 这些也应该直接发送，因为是特殊字符而非中文输入
        if keyStroke.modifiers.contains(.option) && !keyStroke.modifiers.contains(.shift) {
            return true
        }

        // 4. Cmd+Arrow 组合键（跳到行首/行尾）
        // 确保 Cmd+Left/Right 能够被正确处理
        if keyStroke.modifiers.contains(.command) {
            switch keyStroke.keyCode {
            case 123, 124:  // Left Arrow, Right Arrow
                return true
            default:
                break
            }
        }

        // 其他情况（普通字符、Shift+字符）交给 IME
        return false
    }
}
