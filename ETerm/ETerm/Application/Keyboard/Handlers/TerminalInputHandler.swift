//
//  TerminalInputHandler.swift
//  ETerm
//
//  应用层 - 终端输入处理器（兜底）

/// 终端输入处理器（兜底）
final class TerminalInputHandler: KeyboardEventHandler {
    let identifier = "terminal.input"
    let phase = EventPhase.terminalInput
    let priority = 0

    private weak var coordinator: TerminalWindowCoordinator?

    init(coordinator: TerminalWindowCoordinator) {
        self.coordinator = coordinator
    }

    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult {
        guard let terminalId = context.terminalId,
              let coordinator = coordinator else {
            return .ignored
        }

        // 转换为终端序列
        let sequence = keyStroke.toTerminalSequence()

        if !sequence.isEmpty {
            coordinator.writeInput(terminalId: terminalId, data: sequence)
        }

        return .consumed
    }
}
