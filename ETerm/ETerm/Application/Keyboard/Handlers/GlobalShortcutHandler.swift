//
//  GlobalShortcutHandler.swift
//  ETerm
//
//  应用层 - 全局快捷键处理器（Page 级别）

import Foundation

/// 全局快捷键处理器（Page 级别）
final class GlobalShortcutHandler: KeyboardEventHandler {
    let identifier = "global.shortcut"
    let phase = EventPhase.globalShortcut
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
        case .switchToPage(let index):
            return handleSwitchToPage(index: index)

        case .nextPage:
            return coordinator?.switchToNextPage() == true ? .consumed : .ignored

        case .previousPage:
            return coordinator?.switchToPreviousPage() == true ? .consumed : .ignored

        case .createPage:
            coordinator?.createPage()
            return .consumed

        case .closePage:
            return coordinator?.closeCurrentPage() == true ? .consumed : .ignored

        case .increaseFontSize:
            coordinator?.changeFontSize(operation: .increase)
            return .consumed

        case .decreaseFontSize:
            coordinator?.changeFontSize(operation: .decrease)
            return .consumed

        case .resetFontSize:
            coordinator?.changeFontSize(operation: .reset)
            return .consumed

        case .toggleTranslationMode:
            Task { @MainActor in
                TranslationModeStore.shared.toggle()
            }
            return .consumed

        case .toggleSidebar:
            // 发送通知给 ContentView
            NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
            return .consumed

        default:
            return .ignored
        }
    }

    private func handleSwitchToPage(index: Int) -> EventHandleResult {
        guard let coordinator = coordinator else { return .ignored }

        let pages = coordinator.allPages
        guard index < pages.count else { return .ignored }

        let targetPageId = pages[index].pageId
        return coordinator.switchToPage(targetPageId) ? .consumed : .ignored
    }
}
