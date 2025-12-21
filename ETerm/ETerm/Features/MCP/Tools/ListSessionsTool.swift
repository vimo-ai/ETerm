//
//  ListSessionsTool.swift
//  ETerm
//
//  MCP list_sessions 工具实现
//

import AppKit
import Foundation

/// list_sessions 工具实现
///
/// 遍历 WindowManager 获取所有窗口、页面、面板、标签的层级结构
enum ListSessionsTool {

    /// 执行 list_sessions，返回完整的会话信息
    @MainActor
    static func execute() -> MCPSessionInfo {
        let windowManager = WindowManager.shared

        let windowInfos: [MCPSessionInfo.WindowInfo] = windowManager.windows.compactMap { window in
            guard let coordinator = windowManager.getCoordinator(for: window.windowNumber) else {
                return nil
            }

            let terminalWindow = coordinator.terminalWindow

            let pageInfos: [MCPSessionInfo.PageInfo] = terminalWindow.pages.all.map { page in
                let panelInfos: [MCPSessionInfo.PanelInfo] = page.allPanels.map { panel in
                    let tabInfos: [MCPSessionInfo.TabInfo] = panel.tabs.map { tab in
                        MCPSessionInfo.TabInfo(
                            tabId: tab.tabId.uuidString,
                            title: tab.title,
                            isActive: tab.isActive,
                            type: tab.isTerminal ? .terminal : .view,
                            terminalId: tab.rustTerminalId
                        )
                    }

                    let bounds = panel.bounds
                    let boundsInfo = MCPSessionInfo.BoundsInfo(
                        x: bounds.origin.x,
                        y: bounds.origin.y,
                        width: bounds.width,
                        height: bounds.height
                    )

                    return MCPSessionInfo.PanelInfo(
                        panelId: panel.panelId.uuidString,
                        isActive: coordinator.activePanelId == panel.panelId,
                        bounds: boundsInfo,
                        tabs: tabInfos,
                        activeTabId: panel.activeTabId?.uuidString
                    )
                }

                return MCPSessionInfo.PageInfo(
                    pageId: page.pageId.uuidString,
                    title: page.title,
                    isActive: page.pageId == terminalWindow.active.pageId,
                    panels: panelInfos
                )
            }

            return MCPSessionInfo.WindowInfo(
                windowNumber: window.windowNumber,
                windowId: terminalWindow.windowId.uuidString,
                isKeyWindow: window.isKeyWindow,
                pages: pageInfos,
                activePageId: terminalWindow.active.pageId?.uuidString
            )
        }

        return MCPSessionInfo(windows: windowInfos)
    }

    /// 将结果编码为 JSON 字符串
    @MainActor
    static func executeAsJSON() -> String {
        let sessionInfo = execute()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let jsonData = try encoder.encode(sessionInfo)
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }
}
