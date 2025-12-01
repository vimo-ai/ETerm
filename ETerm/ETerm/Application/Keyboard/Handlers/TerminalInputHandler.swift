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

        // 特殊处理：Option+Delete 分词删除
        if keyStroke.keyCode == 51 && keyStroke.modifiers.contains(.option) {
            return handleWordDelete(terminalId: terminalId, coordinator: coordinator)
        }

        // 特殊处理：Cmd+Delete 删除整行（光标前到行首）
        if keyStroke.keyCode == 51 && keyStroke.modifiers.contains(.command) {
            return handleDeleteToLineStart(terminalId: terminalId, coordinator: coordinator)
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

    // MARK: - 删除操作

    /// 处理 Cmd+Delete 删除整行（光标前到行首）
    ///
    /// 实现逻辑：
    /// 1. 获取光标当前列位置
    /// 2. 计算需要删除的字符数（光标前所有内容）
    /// 3. 发送对应数量的 Backspace 序列到终端
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - coordinator: 终端协调器
    /// - Returns: 处理结果
    private func handleDeleteToLineStart(
        terminalId: UInt32,
        coordinator: TerminalWindowCoordinator
    ) -> EventHandleResult {
        // 获取终端管理器
        let terminalManager = GlobalTerminalManager.shared

        // 获取终端快照
        guard let snapshot = terminalManager.getSnapshot(terminalId: Int(terminalId)) else {
            // 降级：发送单个 Delete
            coordinator.writeInput(terminalId: terminalId, data: "\u{7F}")
            return .consumed
        }

        let col = Int(snapshot.cursor_col)

        // 光标在行首，无需删除
        guard col > 0 else {
            return .consumed
        }

        // 生成删除序列（删除光标前所有字符）
        let deleteSequence = String(repeating: "\u{7F}", count: col)
        coordinator.writeInput(terminalId: terminalId, data: deleteSequence)

        return .consumed
    }

    /// 处理 Option+Delete 分词删除
    ///
    /// 实现逻辑：
    /// 1. 获取光标所在行的文本
    /// 2. 使用 WordBoundaryDetector 找到光标前一个词的边界
    /// 3. 计算需要删除的字符数
    /// 4. 发送对应数量的 Backspace 序列到终端
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - coordinator: 终端协调器
    /// - Returns: 处理结果
    private func handleWordDelete(
        terminalId: UInt32,
        coordinator: TerminalWindowCoordinator
    ) -> EventHandleResult {
        // 获取终端管理器
        let terminalManager = GlobalTerminalManager.shared

        // 获取终端快照
        guard let snapshot = terminalManager.getSnapshot(terminalId: Int(terminalId)) else {
            // 降级：发送单个 Delete
            coordinator.writeInput(terminalId: terminalId, data: "\u{7F}")
            return .consumed
        }

        let row = Int(snapshot.cursor_row)
        let col = Int(snapshot.cursor_col)

        // 光标在行首，无法删除
        guard col > 0 else {
            return .consumed
        }

        // 获取当前行的文本（转换为绝对行号）
        let absoluteRow = Int64(snapshot.scrollback_lines) + Int64(row)
        let cells = terminalManager.getRowCells(terminalId: Int(terminalId), absoluteRow: absoluteRow, maxCells: 500)
        let lineText = cells.map { cell in
            guard let scalar = UnicodeScalar(cell.character) else { return " " }
            return String(Character(scalar))
        }.joined()

        // 使用 WordBoundaryDetector 查找光标前一个位置的词边界
        let detector = WordBoundaryDetector()
        guard let boundary = detector.findBoundary(in: lineText, at: col - 1) else {
            // 降级：发送单个 Delete
            coordinator.writeInput(terminalId: terminalId, data: "\u{7F}")
            return .consumed
        }

        // 计算需要删除的字符数（从词的起始到光标位置）
        let deleteCount = col - boundary.startIndex
        guard deleteCount > 0 else {
            return .consumed
        }

        // 生成删除序列（多个 Backspace）
        let deleteSequence = String(repeating: "\u{7F}", count: deleteCount)
        coordinator.writeInput(terminalId: terminalId, data: deleteSequence)

        return .consumed
    }
}
