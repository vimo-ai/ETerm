//
//  KeyboardSystem.swift
//  ETerm
//
//  应用层 - 键盘系统统一入口

import AppKit

/// 按键处理结果
enum KeyEventResult {
    case handled
    case passToIME
}

/// 键盘系统 - 统一入口
final class KeyboardSystem {

    // MARK: - Components

    let imeCoordinator: IMECoordinator
    private let pipeline: KeyboardEventPipeline
    private let bindingRegistry: KeyBindingRegistry
    private weak var coordinator: TerminalWindowCoordinator?

    // MARK: - State

    private var currentMode: KeyboardMode = .normal

    // MARK: - Initialization

    init(coordinator: TerminalWindowCoordinator) {
        self.coordinator = coordinator
        self.imeCoordinator = IMECoordinator()
        self.pipeline = KeyboardEventPipeline()
        self.bindingRegistry = KeyBindingRegistry()

        setupHandlers()
    }

    private func setupHandlers() {
        guard let coordinator = coordinator else { return }

        // Phase 0: IME 劫持
        pipeline.register(IMEInterceptHandler(imeCoordinator: imeCoordinator))

        // Phase 1: 全局快捷键（Page）
        pipeline.register(GlobalShortcutHandler(coordinator: coordinator, bindingRegistry: bindingRegistry))

        // Phase 2: Panel 快捷键（Tab）
        pipeline.register(PanelShortcutHandler(coordinator: coordinator, bindingRegistry: bindingRegistry))

        // Phase 3: 编辑（复制粘贴）
        pipeline.register(EditHandler(coordinator: coordinator, bindingRegistry: bindingRegistry))

        // Phase 4: 终端输入（兜底）
        pipeline.register(TerminalInputHandler(coordinator: coordinator))
    }

    // MARK: - Public API

    /// 处理键盘事件
    func handleKeyDown(_ event: NSEvent) -> KeyEventResult {
        let keyStroke = KeyStroke.from(event)
        let context = buildContext()

        let result = pipeline.process(keyStroke, context: context)

        switch result {
        case .handled:
            return .handled

        case .intercepted(let action):
            switch action {
            case .passToIME:
                return .passToIME
            }

        case .unhandled:
            // 未被任何 Handler 处理的按键，交给 IME 系统
            // 这样普通字符输入可以通过 interpretKeyEvents 进入输入法
            return .passToIME
        }
    }

    /// 设置键盘模式
    func setMode(_ mode: KeyboardMode) {
        currentMode = mode
    }

    // MARK: - Private

    private func buildContext() -> KeyboardContext {
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
