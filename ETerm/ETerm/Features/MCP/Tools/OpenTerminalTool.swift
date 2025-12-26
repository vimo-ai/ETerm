//
//  OpenTerminalTool.swift
//  ETerm
//
//  MCP open_terminal tool - 打开新终端 tab
//

import Foundation
import AppKit

/// open_terminal tool
enum OpenTerminalTool {

    /// 目标位置
    enum Target: String, Codable {
        case currentPanel = "current_panel"
        case splitHorizontal = "split_horizontal"
        case splitVertical = "split_vertical"
        case newWindow = "new_window"
    }

    struct Response: Codable {
        let success: Bool
        let message: String
        let terminalId: Int?
        let panelId: String?
    }

    /// 执行 open_terminal
    ///
    /// - Parameters:
    ///   - workingDirectory: 工作目录（nil 继承当前目录）
    ///   - target: 目标位置，默认 current_panel
    ///   - windowNumber: 指定窗口（nil 使用当前活跃窗口）
    ///   - panelId: 指定 panel（nil 使用当前活跃 panel）
    @MainActor
    static func execute(
        workingDirectory: String? = nil,
        target: Target = .currentPanel,
        windowNumber: Int? = nil,
        panelId: String? = nil
    ) -> Response {
        let windowManager = WindowManager.shared

        // 1. 找到目标 Coordinator
        let coordinator: TerminalWindowCoordinator?
        if let wn = windowNumber {
            coordinator = windowManager.getCoordinator(for: wn)
        } else {
            // 使用当前 key window
            coordinator = windowManager.windows
                .first { $0.isKeyWindow }
                .flatMap { windowManager.getCoordinator(for: $0.windowNumber) }
                ?? windowManager.windows.first
                    .flatMap { windowManager.getCoordinator(for: $0.windowNumber) }
        }

        guard let coordinator = coordinator else {
            return Response(success: false, message: "No window available", terminalId: nil, panelId: nil)
        }

        // 2. 找到目标 Panel ID
        let targetPanelId: UUID
        if let pidStr = panelId, let pid = UUID(uuidString: pidStr) {
            targetPanelId = pid
        } else if let activePid = coordinator.activePanelId {
            targetPanelId = activePid
        } else {
            return Response(success: false, message: "No active panel", terminalId: nil, panelId: nil)
        }

        // 3. 根据 target 执行不同操作
        switch target {
        case .currentPanel:
            return addTabToPanel(coordinator: coordinator, panelId: targetPanelId, cwd: workingDirectory)

        case .splitHorizontal:
            return splitPanel(coordinator: coordinator, panelId: targetPanelId, direction: .horizontal, cwd: workingDirectory)

        case .splitVertical:
            return splitPanel(coordinator: coordinator, panelId: targetPanelId, direction: .vertical, cwd: workingDirectory)

        case .newWindow:
            return createNewWindow(cwd: workingDirectory)
        }
    }

    // MARK: - Private Helpers

    @MainActor
    private static func addTabToPanel(coordinator: TerminalWindowCoordinator, panelId: UUID, cwd: String?) -> Response {
        let config = TabConfig(cwd: cwd ?? coordinator.getActiveCwd(for: panelId))
        let result = coordinator.perform(.tab(.addWithConfig(panelId: panelId, config: config)))

        if result.success {
            // 获取新创建的 tab 的 terminalId
            if let panel = coordinator.terminalWindow.getPanel(panelId),
               let activeTab = panel.tabs.first(where: { $0.tabId == panel.activeTabId }) {
                return Response(
                    success: true,
                    message: "Terminal opened in current panel",
                    terminalId: activeTab.rustTerminalId,
                    panelId: panelId.uuidString
                )
            }
            return Response(success: true, message: "Terminal opened", terminalId: nil, panelId: panelId.uuidString)
        } else {
            return Response(success: false, message: "Failed to add tab", terminalId: nil, panelId: nil)
        }
    }

    @MainActor
    private static func splitPanel(coordinator: TerminalWindowCoordinator, panelId: UUID, direction: SplitDirection, cwd: String?) -> Response {
        let effectiveCwd = cwd ?? coordinator.getActiveCwd(for: panelId)
        let result = coordinator.perform(.panel(.split(panelId: panelId, direction: direction, cwd: effectiveCwd)))

        if result.success {
            // 获取新创建的 panel
            if let newPanelId = coordinator.terminalWindow.active.panelId,
               let newPanel = coordinator.terminalWindow.getPanel(newPanelId),
               let activeTab = newPanel.tabs.first(where: { $0.tabId == newPanel.activeTabId }) {
                return Response(
                    success: true,
                    message: "Terminal opened in new \(direction == .horizontal ? "horizontal" : "vertical") split",
                    terminalId: activeTab.rustTerminalId,
                    panelId: newPanelId.uuidString
                )
            }
            return Response(success: true, message: "Panel split created", terminalId: nil, panelId: nil)
        } else {
            return Response(success: false, message: "Failed to split panel", terminalId: nil, panelId: nil)
        }
    }

    @MainActor
    private static func createNewWindow(cwd: String?) -> Response {
        let windowManager = WindowManager.shared
        windowManager.createWindow(inheritCwd: cwd)

        // 等待窗口创建完成，获取新窗口信息
        if let newWindow = windowManager.windows.last,
           let coordinator = windowManager.getCoordinator(for: newWindow.windowNumber),
           let panel = coordinator.terminalWindow.allPanels.first,
           let tab = panel.tabs.first {
            return Response(
                success: true,
                message: "Terminal opened in new window",
                terminalId: tab.rustTerminalId,
                panelId: panel.panelId.uuidString
            )
        }

        return Response(success: true, message: "New window created", terminalId: nil, panelId: nil)
    }

    /// Encode response to JSON
    static func responseToJSON(_ response: Response) -> String {
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
