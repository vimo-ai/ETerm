//
//  InputCoordinator.swift
//  ETerm
//
//  应用层 - 输入协调器
//
//  统一处理所有键盘输入，协调命令系统和终端输入

import AppKit

/// 输入协调器
///
/// 负责统一分派键盘输入到命令系统或终端
/// 替代原有的 KeyboardEventPipeline 复杂逻辑
final class InputCoordinator {
    private let keyboardService: KeyboardServiceImpl
    private let commandRegistry: CommandRegistry
    private let imeInterceptHandler: IMEInterceptHandler
    private let terminalInputHandler: TerminalInputHandler
    private let imeCoordinator: IMECoordinator

    private weak var coordinator: TerminalWindowCoordinator?
    private var currentMode: KeyboardMode = .normal

    init(coordinator: TerminalWindowCoordinator, imeCoordinator: IMECoordinator) {
        self.coordinator = coordinator
        self.imeCoordinator = imeCoordinator
        self.keyboardService = KeyboardServiceImpl.shared
        self.commandRegistry = CommandRegistry.shared
        self.imeInterceptHandler = IMEInterceptHandler(imeCoordinator: imeCoordinator)
        self.terminalInputHandler = TerminalInputHandler(coordinator: coordinator)
    }

    /// 处理键盘输入
    /// - Parameter event: 键盘事件
    /// - Returns: 处理结果
    func handleKeyDown(_ event: NSEvent) -> KeyEventResult {
        let keyStroke = KeyStroke.from(event)

        // 1. IME 劫持（最高优先级）
        let imeContext = buildKeyboardContext()
        let imeResult = imeInterceptHandler.handle(keyStroke, context: imeContext)

        switch imeResult {
        case .handled:
            return .handled
        case .intercepted(let action):
            switch action {
            case .passToIME:
                return .passToIME
            }
        case .unhandled:
            break  // 继续后续处理
        }

        // 2. 命令系统（插件和核心命令）
        let whenContext = buildWhenClauseContext()
        let commandContext = buildCommandContext()

        if keyboardService.handleKeyStroke(
            keyStroke,
            whenContext: whenContext,
            commandContext: commandContext
        ) {
            return .handled
        }

        // 3. 终端输入（特殊键和 Ctrl 组合）
        let terminalContext = buildKeyboardContext()
        let terminalResult = terminalInputHandler.handle(keyStroke, context: terminalContext)

        switch terminalResult {
        case .handled:
            return .handled
        case .intercepted:
            return .handled
        case .unhandled:
            break
        }

        // 4. 默认：交给 IME 处理普通字符输入
        return .passToIME
    }

    /// 设置键盘模式
    func setMode(_ mode: KeyboardMode) {
        currentMode = mode
    }

    // MARK: - Private

    private func buildWhenClauseContext() -> WhenClauseContext {
        let commandContext = buildCommandContext()
        return WhenClauseContext(
            mode: currentMode,
            hasSelection: commandContext.hasSelection,
            imeActive: imeCoordinator.isComposing
        )
    }

    private func buildCommandContext() -> CommandContext {
        return CommandContext(
            coordinator: coordinator,
            window: nil
        )
    }

    private func buildKeyboardContext() -> KeyboardContext {
        guard let coordinator = coordinator else {
            return KeyboardContext(
                mode: currentMode,
                activePanelId: nil,
                activeTabId: nil,
                hasSelection: false,
                terminalId: nil
            )
        }

        let activePanelId = coordinator.activePanelId
        let panel = activePanelId.flatMap { coordinator.terminalWindow.getPanel($0) }
        let activeTab = panel?.activeTab
        let terminalId = activeTab?.rustTerminalId

        return KeyboardContext(
            mode: currentMode,
            activePanelId: activePanelId,
            activeTabId: activeTab?.tabId,
            hasSelection: activeTab?.hasSelection() ?? false,
            terminalId: terminalId
        )
    }
}
