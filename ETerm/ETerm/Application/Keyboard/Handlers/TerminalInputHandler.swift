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

/// 终端输入处理器
///
/// 只处理特殊键和 Ctrl 组合键，普通字符交给 IME
final class TerminalInputHandler: KeyboardEventHandler {
    let identifier = "terminal.input"
    let phase = EventPhase.terminalInput
    let priority = 0

    private weak var coordinator: TerminalWindowCoordinator?

    /// 需要直接处理的特殊键 keyCode
    private let specialKeyCodes: Set<UInt16> = [
        36,   // Return
        48,   // Tab
        51,   // Delete
        53,   // Escape
        123,  // Left Arrow
        124,  // Right Arrow
        125,  // Down Arrow
        126,  // Up Arrow
        115,  // Home
        119,  // End
        116,  // Page Up
        121,  // Page Down
        117,  // Forward Delete
    ]

    init(coordinator: TerminalWindowCoordinator) {
        self.coordinator = coordinator
    }

    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult {
        guard let terminalId = context.terminalId,
              let coordinator = coordinator else {
            return .ignored
        }

        // 判断是否应该直接处理
        let shouldHandle = shouldHandleDirectly(keyStroke)

        if shouldHandle {
            // 特殊键或 Ctrl 组合键：直接发送到终端
            let sequence = keyStroke.toTerminalSequence()
            if !sequence.isEmpty {
                coordinator.writeInput(terminalId: terminalId, data: sequence)
            }
            return .consumed
        }

        // 普通字符：交给 IME 处理
        return .ignored
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

        // 其他情况（普通字符、Shift+字符）交给 IME
        return false
    }
}
