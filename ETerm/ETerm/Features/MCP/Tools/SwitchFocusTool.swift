//
//  SwitchFocusTool.swift
//  ETerm
//
//  MCP switch_focus 工具实现
//

import AppKit
import Foundation

/// switch_focus 工具实现
///
/// 支持切换到指定的 Page 或 Tab
enum SwitchFocusTool {

    /// 执行 switch_focus
    @MainActor
    static func execute(target: MCPFocusTarget) -> MCPFocusResponse {
        // 验证参数
        if case .failure(let error) = target.validate() {
            return .failure(message: error.localizedDescription ?? "Invalid parameters")
        }

        let windowManager = WindowManager.shared

        // 查找目标窗口
        guard let window = windowManager.windows.first(where: { $0.windowNumber == target.windowNumber }),
              let coordinator = windowManager.getCoordinator(for: target.windowNumber) else {
            return .failure(message: MCPFocusError.windowNotFound(target.windowNumber).localizedDescription ?? "Window not found")
        }

        switch target.type {
        case .page:
            return switchToPage(
                pageIdString: target.pageId!,
                coordinator: coordinator,
                window: window
            )

        case .tab:
            return switchToTab(
                panelIdString: target.panelId!,
                tabIdString: target.tabId!,
                coordinator: coordinator,
                window: window
            )
        }
    }

    // MARK: - Private

    @MainActor
    private static func switchToPage(
        pageIdString: String,
        coordinator: TerminalWindowCoordinator,
        window: KeyableWindow
    ) -> MCPFocusResponse {
        guard let pageId = UUID(uuidString: pageIdString) else {
            return .failure(message: "Invalid page ID format")
        }

        // 检查 page 是否存在
        guard coordinator.terminalWindow.pages.contains(where: { $0.pageId == pageId }) else {
            return .failure(message: MCPFocusError.pageNotFound(pageIdString).localizedDescription ?? "Page not found")
        }

        // 执行切换
        let success = coordinator.switchToPage(pageId)

        if success {
            // 激活窗口
            window.makeKeyAndOrderFront(nil)

            return .success(
                message: "Switched to page",
                element: MCPFocusResponse.FocusedElement(
                    windowNumber: window.windowNumber,
                    pageId: pageIdString,
                    panelId: coordinator.activePanelId?.uuidString,
                    tabId: nil
                )
            )
        } else {
            return .failure(message: "Failed to switch to page")
        }
    }

    @MainActor
    private static func switchToTab(
        panelIdString: String,
        tabIdString: String,
        coordinator: TerminalWindowCoordinator,
        window: KeyableWindow
    ) -> MCPFocusResponse {
        guard let panelId = UUID(uuidString: panelIdString),
              let tabId = UUID(uuidString: tabIdString) else {
            return .failure(message: "Invalid panel or tab ID format")
        }

        // 查找 panel
        guard let panel = coordinator.terminalWindow.getPanel(panelId) else {
            return .failure(message: MCPFocusError.panelNotFound(panelIdString).localizedDescription ?? "Panel not found")
        }

        // 检查 tab 是否存在
        guard panel.tabs.contains(where: { $0.tabId == tabId }) else {
            return .failure(message: MCPFocusError.tabNotFound(tabIdString).localizedDescription ?? "Tab not found")
        }

        // 执行切换
        let success = panel.switchToTab(tabId)

        if success {
            // 设置激活的 panel
            coordinator.setActivePanel(panelId)

            // 激活窗口
            window.makeKeyAndOrderFront(nil)

            return .success(
                message: "Switched to tab",
                element: MCPFocusResponse.FocusedElement(
                    windowNumber: window.windowNumber,
                    pageId: coordinator.terminalWindow.activePageId?.uuidString,
                    panelId: panelIdString,
                    tabId: tabIdString
                )
            )
        } else {
            return .failure(message: "Failed to switch to tab")
        }
    }

    /// 将响应编码为 JSON 字符串
    static func responseToJSON(_ response: MCPFocusResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        do {
            let jsonData = try encoder.encode(response)
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"success\": false, \"message\": \"\(error.localizedDescription)\"}"
        }
    }
}
