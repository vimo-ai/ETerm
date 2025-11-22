//
//  PanelShortcutHandler.swift
//  ETerm
//
//  应用层 - Panel 快捷键处理器（Tab 级别）

import Foundation
import AppKit

/// Panel 快捷键处理器（Tab 级别）
final class PanelShortcutHandler: KeyboardEventHandler {
    let identifier = "panel.shortcut"
    let phase = EventPhase.panelShortcut
    let priority = 100

    private weak var coordinator: TerminalWindowCoordinator?
    private let bindingRegistry: KeyBindingRegistry

    init(coordinator: TerminalWindowCoordinator, bindingRegistry: KeyBindingRegistry) {
        self.coordinator = coordinator
        self.bindingRegistry = bindingRegistry
    }

    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult {
        guard let event = bindingRegistry.find(keyStroke: keyStroke, mode: context.mode),
              let panelId = context.activePanelId else {
            return .ignored
        }

        switch event {
        case .switchToTab(let index):
            return handleSwitchToTab(index: index, panelId: panelId)

        case .nextTab:
            return handleNextTab(panelId: panelId)

        case .previousTab:
            return handlePreviousTab(panelId: panelId)

        case .createTab:
            coordinator?.handleAddTab(panelId: panelId)
            return .consumed

        case .closeTab:
            return handleSmartClose()

        case .splitHorizontal:
            coordinator?.handleSplitPanel(panelId: panelId, direction: .horizontal)
            return .consumed

        case .splitVertical:
            coordinator?.handleSplitPanel(panelId: panelId, direction: .vertical)
            return .consumed

        default:
            return .ignored
        }
    }

    private func handleSwitchToTab(index: Int, panelId: UUID) -> EventHandleResult {
        guard let coordinator = coordinator,
              let panel = coordinator.terminalWindow.getPanel(panelId) else {
            return .ignored
        }

        let tabs = panel.tabs
        guard index < tabs.count else { return .ignored }

        let targetTabId = tabs[index].tabId
        coordinator.handleTabClick(panelId: panelId, tabId: targetTabId)
        return .consumed
    }

    private func handleNextTab(panelId: UUID) -> EventHandleResult {
        guard let coordinator = coordinator,
              let panel = coordinator.terminalWindow.getPanel(panelId),
              let currentTabId = panel.activeTabId,
              let currentIndex = panel.tabs.firstIndex(where: { $0.tabId == currentTabId }) else {
            return .ignored
        }

        let nextIndex = (currentIndex + 1) % panel.tabs.count
        let nextTabId = panel.tabs[nextIndex].tabId
        coordinator.handleTabClick(panelId: panelId, tabId: nextTabId)
        return .consumed
    }

    private func handlePreviousTab(panelId: UUID) -> EventHandleResult {
        guard let coordinator = coordinator,
              let panel = coordinator.terminalWindow.getPanel(panelId),
              let currentTabId = panel.activeTabId,
              let currentIndex = panel.tabs.firstIndex(where: { $0.tabId == currentTabId }) else {
            return .ignored
        }

        let previousIndex = (currentIndex - 1 + panel.tabs.count) % panel.tabs.count
        let previousTabId = panel.tabs[previousIndex].tabId
        coordinator.handleTabClick(panelId: panelId, tabId: previousTabId)
        return .consumed
    }

    // MARK: - Smart Close

    /// 智能关闭（Cmd+W）
    ///
    /// 关闭逻辑：
    /// 1. 如果当前 Panel 有多个 Tab → 关闭当前 Tab
    /// 2. 如果当前 Page 有多个 Panel → 关闭当前 Panel
    /// 3. 如果当前 Window 有多个 Page → 关闭当前 Page
    /// 4. 如果只剩最后一个 → 弹出确认对话框
    private func handleSmartClose() -> EventHandleResult {
        guard let coordinator = coordinator else {
            return .ignored
        }

        let result = coordinator.handleSmartClose()

        switch result {
        case .closedTab, .closedPanel, .closedPage:
            return .consumed

        case .shouldQuitApp:
            showQuitConfirmation()
            return .consumed

        case .nothingToClose:
            return .ignored
        }
    }

    /// 显示退出确认对话框
    private func showQuitConfirmation() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "确定要退出 ETerm 吗？"
            alert.informativeText = "这是最后一个终端会话，关闭后将退出应用程序。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "取消")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
