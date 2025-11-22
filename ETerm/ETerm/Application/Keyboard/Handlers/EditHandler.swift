//
//  EditHandler.swift
//  ETerm
//
//  应用层 - 编辑处理器（复制粘贴）

import AppKit

/// 编辑处理器（复制粘贴）
final class EditHandler: KeyboardEventHandler {
    let identifier = "edit"
    let phase = EventPhase.edit
    let priority = 100

    private weak var coordinator: TerminalWindowCoordinator?
    private let bindingRegistry: KeyBindingRegistry

    init(coordinator: TerminalWindowCoordinator, bindingRegistry: KeyBindingRegistry) {
        self.coordinator = coordinator
        self.bindingRegistry = bindingRegistry
    }

    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult {
        guard let event = bindingRegistry.find(keyStroke: keyStroke, mode: context.mode) else {
            return .ignored
        }

        switch event {
        case .copy:
            return handleCopy(context: context)

        case .paste:
            return handlePaste(context: context)

        case .clearSelection:
            return handleClearSelection(context: context)

        default:
            return .ignored
        }
    }

    private func handleCopy(context: KeyboardContext) -> EventHandleResult {
        guard context.hasSelection,
              let terminalId = context.terminalId,
              let coordinator = coordinator,
              let panelId = context.activePanelId,
              let panel = coordinator.terminalWindow.getPanel(panelId),
              let tab = panel.activeTab,
              let selection = tab.textSelection else {
            // 无选中，不处理，让后续 Handler 发送 Ctrl+C
            return .ignored
        }

        // 获取选中文本
        guard let text = coordinator.getSelectedText(terminalId: terminalId, selection: selection) else {
            return .ignored
        }

        // 复制到剪贴板
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        return .consumed
    }

    private func handlePaste(context: KeyboardContext) -> EventHandleResult {
        guard let text = NSPasteboard.general.string(forType: .string),
              let terminalId = context.terminalId,
              let coordinator = coordinator else {
            return .ignored
        }

        coordinator.writeInput(terminalId: terminalId, data: text)
        return .consumed
    }

    private func handleClearSelection(context: KeyboardContext) -> EventHandleResult {
        guard let terminalId = context.terminalId,
              let coordinator = coordinator else {
            return .ignored
        }

        _ = coordinator.clearSelection(terminalId: terminalId)
        return .consumed
    }
}
