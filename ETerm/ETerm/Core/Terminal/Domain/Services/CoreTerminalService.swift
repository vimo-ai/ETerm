//
//  CoreTerminalService.swift
//  ETerm
//
//  核心终端服务
//
//  提供终端操作的底层统一实现，供 MCP Tools 和 HostBridge 共用。
//  所有方法都在主线程执行。
//

import Foundation
import AppKit

/// 核心终端服务
///
/// 统一的终端操作底层实现：
/// - MCP Tools (OpenTerminalTool, SendInputTool) 调用这里
/// - HostBridge (MainProcessHostBridge) 调用这里
///
/// 避免重复实现终端操作逻辑。
@MainActor
enum CoreTerminalService {

    // MARK: - Types

    struct CreateTabResult {
        let success: Bool
        let terminalId: Int?
        let panelId: String?
        let message: String
    }

    struct SendInputResult {
        let success: Bool
        let message: String
    }

    // MARK: - Create Tab

    /// 创建终端 Tab
    ///
    /// 在指定窗口的指定 Panel 创建新终端 Tab。
    ///
    /// - Parameters:
    ///   - cwd: 工作目录（nil 继承当前目录）
    ///   - windowNumber: 指定窗口（nil 使用当前活跃窗口）
    ///   - panelId: 指定 panel UUID 字符串（nil 使用当前活跃 panel）
    /// - Returns: 创建结果
    static func createTab(
        cwd: String? = nil,
        windowNumber: Int? = nil,
        panelId: String? = nil
    ) -> CreateTabResult {
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
            return CreateTabResult(success: false, terminalId: nil, panelId: nil, message: "No window available")
        }

        // 2. 找到目标 Panel ID
        let targetPanelId: UUID
        if let pidStr = panelId, let pid = UUID(uuidString: pidStr) {
            targetPanelId = pid
        } else if let activePid = coordinator.activePanelId {
            targetPanelId = activePid
        } else {
            return CreateTabResult(success: false, terminalId: nil, panelId: nil, message: "No active panel")
        }

        // 3. 创建 Tab
        let effectiveCwd = cwd ?? coordinator.getActiveCwd(for: targetPanelId)
        let config = TabConfig(cwd: effectiveCwd)
        let result = coordinator.perform(.tab(.addWithConfig(panelId: targetPanelId, config: config)))

        if result.success {
            // 获取新创建的 tab 的 terminalId
            if let panel = coordinator.terminalWindow.getPanel(targetPanelId),
               let activeTab = panel.tabs.first(where: { $0.tabId == panel.activeTabId }) {
                return CreateTabResult(
                    success: true,
                    terminalId: activeTab.rustTerminalId,
                    panelId: targetPanelId.uuidString,
                    message: "Terminal created"
                )
            }
            return CreateTabResult(success: true, terminalId: nil, panelId: targetPanelId.uuidString, message: "Terminal created but ID not found")
        } else {
            return CreateTabResult(success: false, terminalId: nil, panelId: nil, message: "Failed to add tab")
        }
    }

    // MARK: - Create Tab With External Fd

    /// 用外部 PTY fd 创建终端 Tab
    ///
    /// 不走 Command 管道（无需 CWD 继承、命令执行等逻辑），
    /// 直接创建 Tab 模型 + 调用 terminalPool.createTerminalWithFd。
    ///
    /// - Parameters:
    ///   - fd: PTY master fd（所有权移交给 terminal_pool）
    ///   - childPid: 子进程 PID
    ///   - cols: 终端列数（nil 使用默认 80）
    ///   - rows: 终端行数（nil 使用默认 24）
    ///   - title: 初始 Tab 标题
    ///   - windowNumber: 指定窗口（nil 使用当前活跃窗口）
    ///   - panelId: 指定 panel UUID 字符串（nil 使用当前活跃 panel）
    /// - Returns: 创建结果
    static func createTabWithFd(
        fd: Int32,
        childPid: Int32?,
        cols: UInt16? = nil,
        rows: UInt16? = nil,
        title: String? = nil,
        windowNumber: Int? = nil,
        panelId: String? = nil
    ) -> CreateTabResult {
        let windowManager = WindowManager.shared

        // 1. 找到目标 Coordinator
        let coordinator: TerminalWindowCoordinator?
        if let wn = windowNumber {
            coordinator = windowManager.getCoordinator(for: wn)
        } else {
            coordinator = windowManager.windows
                .first { $0.isKeyWindow }
                .flatMap { windowManager.getCoordinator(for: $0.windowNumber) }
                ?? windowManager.windows.first
                    .flatMap { windowManager.getCoordinator(for: $0.windowNumber) }
        }

        guard let coordinator = coordinator else {
            return CreateTabResult(success: false, terminalId: nil, panelId: nil, message: "No window available")
        }

        // 2. 找到目标 Panel ID
        let targetPanelId: UUID
        if let pidStr = panelId, let pid = UUID(uuidString: pidStr) {
            targetPanelId = pid
        } else if let activePid = coordinator.activePanelId {
            targetPanelId = activePid
        } else {
            return CreateTabResult(success: false, terminalId: nil, panelId: nil, message: "No active panel")
        }

        // 3. 创建 Tab 模型（跳过终端创建，由我们用外部 fd 创建）
        let config = TabConfig(skipTerminalCreation: true)
        let result = coordinator.perform(.tab(.addWithConfig(panelId: targetPanelId, config: config)))

        guard result.success,
              let createdTabId = result.createdTabId,
              let panel = coordinator.terminalWindow.getPanel(targetPanelId),
              let newTab = panel.tabs.first(where: { $0.tabId == createdTabId }) else {
            return CreateTabResult(success: false, terminalId: nil, panelId: nil, message: "Failed to create tab")
        }

        // 4. 用外部 fd 创建终端（替代默认的 shell spawn）
        let effectiveCols = cols ?? 80
        let effectiveRows = rows ?? 24
        let effectivePid = childPid.map { UInt32(bitPattern: $0) } ?? 0
        let terminalId = coordinator.terminalPool.createTerminalWithFd(
            fd,
            childPid: effectivePid,
            cols: effectiveCols,
            rows: effectiveRows
        )

        guard terminalId >= 0 else {
            return CreateTabResult(success: false, terminalId: nil, panelId: targetPanelId.uuidString, message: "Failed to create terminal with fd")
        }

        // 5. 绑定 terminalId 到 Tab
        newTab.setRustTerminalId(terminalId)

        // 6. 设置标题
        if let title = title {
            newTab.title = title
        }

        return CreateTabResult(
            success: true,
            terminalId: terminalId,
            panelId: targetPanelId.uuidString,
            message: "Terminal created with external fd"
        )
    }

    // MARK: - Send Input

    /// 发送输入到终端
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - text: 输入文本
    ///   - pressEnter: 是否追加回车（延迟 50ms 发送）
    /// - Returns: 发送结果
    static func sendInput(
        terminalId: Int,
        text: String,
        pressEnter: Bool = false
    ) async -> SendInputResult {
        let windowManager = WindowManager.shared

        // 查找拥有该终端的 coordinator
        for window in windowManager.windows {
            guard let coordinator = windowManager.getCoordinator(for: window.windowNumber) else {
                continue
            }

            // 检查此 coordinator 是否有该终端
            for page in coordinator.terminalWindow.pages.all {
                for panel in page.allPanels {
                    for tab in panel.tabs {
                        if tab.rustTerminalId == terminalId {
                            // 找到终端，发送输入
                            coordinator.writeInput(terminalId: terminalId, data: text)

                            // 如果需要回车，延迟 50ms 发送
                            if pressEnter {
                                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                                coordinator.writeInput(terminalId: terminalId, data: "\r")
                            }

                            return SendInputResult(success: true, message: "Input sent to terminal \(terminalId)")
                        }
                    }
                }
            }
        }

        return SendInputResult(success: false, message: "Terminal \(terminalId) not found")
    }

    // MARK: - Find Terminal

    /// 查找终端所属的 Coordinator
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: Coordinator，未找到返回 nil
    static func findCoordinator(for terminalId: Int) -> TerminalWindowCoordinator? {
        let windowManager = WindowManager.shared

        for window in windowManager.windows {
            guard let coordinator = windowManager.getCoordinator(for: window.windowNumber) else {
                continue
            }

            for page in coordinator.terminalWindow.pages.all {
                for panel in page.allPanels {
                    for tab in panel.tabs {
                        if tab.rustTerminalId == terminalId {
                            return coordinator
                        }
                    }
                }
            }
        }

        return nil
    }

    /// 直接写入终端（不等待，同步）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - data: 数据
    /// - Returns: 是否成功
    static func writeToTerminal(terminalId: Int, data: String) -> Bool {
        guard let coordinator = findCoordinator(for: terminalId) else {
            return false
        }
        coordinator.writeInput(terminalId: terminalId, data: data)
        return true
    }
}
