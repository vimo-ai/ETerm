//
//  VlaudePlugin.swift
//  ETerm
//
//  Vlaude 远程控制插件
//  职责：
//  - 连接 daemon，上报 session 状态
//  - 接收注入请求，转发给 Coordinator
//  - 处理远程创建 Claude 会话请求
//  - 跟踪 requestId，在会话创建完成后上报

import AppKit
import Foundation
import SwiftUI

final class VlaudePlugin: Plugin {
    static let id = "vlaude"
    static let name = "Vlaude Remote"
    static let version = "1.0.0"

    private var daemonClient: VlaudeDaemonClient?
    private weak var context: PluginContext?

    /// 待上报的 requestId 映射：terminalId -> (requestId, projectPath)
    /// 当收到创建请求时保存，当 Claude 启动后（claudeResponseComplete）检测并上报
    private var pendingRequests: [Int: (requestId: String, projectPath: String)] = [:]

    /// Mobile 正在查看的 terminal ID 集合
    private var mobileViewingTerminals: Set<Int> = []

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 注册 Tab Slot（显示手机图标）
        context.ui.registerTabSlot(
            for: Self.id,
            slotId: "vlaude-mobile-viewing",
            priority: 50
        ) { [weak self] tab in
            guard let self = self else { return nil }
            guard let terminalId = tab.rustTerminalId else { return nil }
            guard self.mobileViewingTerminals.contains(terminalId) else { return nil }
            return AnyView(
                Image(systemName: "iphone")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            )
        }

        // 连接 daemon
        daemonClient = VlaudeDaemonClient()
        daemonClient?.delegate = self
        daemonClient?.connect()

        // 监听 session 映射变化（Claude 响应完成）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClaudeResponseComplete(_:)),
            name: .claudeResponseComplete,
            object: nil
        )

        // 监听终端关闭
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalClosed(_:)),
            name: .terminalDidClose,
            object: nil
        )

        // 监听 Claude 退出（SessionEnd hook）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClaudeSessionEnd(_:)),
            name: .claudeSessionEnd,
            object: nil
        )

    }

    func deactivate() {
        NotificationCenter.default.removeObserver(self)
        pendingRequests.removeAll()
        daemonClient?.disconnect()
        daemonClient = nil
    }

    // MARK: - Claude Response Complete

    @objc private func handleClaudeResponseComplete(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionId = userInfo["session_id"] as? String,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        // 查找对应的 tabId 用于持久化
        let tabId = WindowManager.shared.findTabId(for: terminalId)

        // 更新映射（包含持久化）
        ClaudeSessionMapper.shared.map(terminalId: terminalId, sessionId: sessionId, tabId: tabId)

        // 上报 session 可用
        daemonClient?.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)

        // 检查是否有待上报的 requestId
        if let pending = pendingRequests.removeValue(forKey: terminalId) {
            daemonClient?.reportSessionCreated(
                requestId: pending.requestId,
                sessionId: sessionId,
                projectPath: pending.projectPath
            )
        }
    }

    // MARK: - Terminal Closed

    @objc private func handleTerminalClosed(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        // 清理待上报的 requestId（如果有）
        pendingRequests.removeValue(forKey: terminalId)

        // 查找该 terminal 对应的 session
        guard let sessionId = ClaudeSessionMapper.shared.getSessionId(for: terminalId) else {
            // 该 terminal 没有 Claude session，无需处理
            return
        }

        // 查找对应的 tabId 用于清理持久化数据
        // 注意：terminalDidClose 通知中可能已经包含 tabId
        let tabId = userInfo["tab_id"] as? String

        // 清理本地映射（包含持久化）
        ClaudeSessionMapper.shared.remove(terminalId: terminalId, tabId: tabId)

        // 通知 daemon
        daemonClient?.reportSessionUnavailable(sessionId: sessionId)
    }

    // MARK: - Claude Session End

    @objc private func handleClaudeSessionEnd(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionId = userInfo["session_id"] as? String,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        // 清理待上报的 requestId（如果有）
        pendingRequests.removeValue(forKey: terminalId)

        // 查找对应的 tabId 用于清理持久化数据
        let tabId = WindowManager.shared.findTabId(for: terminalId)

        // 清理本地映射（包含持久化）
        ClaudeSessionMapper.shared.remove(terminalId: terminalId, tabId: tabId)

        // 通知 daemon
        daemonClient?.reportSessionUnavailable(sessionId: sessionId)
    }

    // MARK: - Create Claude Session

    /// 创建 Claude 会话（供 daemon 调用）
    private func createClaudeSession(projectPath: String, prompt: String?, requestId: String?) {

        // 构建 claude 命令
        var command = "claude"
        if let prompt = prompt, !prompt.isEmpty {
            // 转义单引号
            let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
            command += " -p '\(escapedPrompt)'"
        }
        command += "\r"  // 回车执行

        // 在主线程通过 Coordinator 创建终端
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 获取当前活动窗口的 Coordinator
            guard let keyWindow = WindowManager.shared.keyWindow,
                  let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber) else {
                return
            }

            // 调用 Coordinator 的公开 API 创建终端
            guard let result = coordinator.createNewTabWithCommand(
                cwd: projectPath,
                command: command
            ) else {
                return
            }


            // 如果有 requestId，保存到待上报映射
            if let reqId = requestId {
                self.pendingRequests[result.terminalId] = (reqId, projectPath)
            }
        }
    }
}

// MARK: - VlaudeDaemonClientDelegate

extension VlaudePlugin: VlaudeDaemonClientDelegate {
    func daemonClientDidConnect(_ client: VlaudeDaemonClient) {
        // 连接成功后，上报所有已存在的 session 映射
        let mappings = ClaudeSessionMapper.shared.getAllMappings()

        for (sessionId, terminalId) in mappings {
            client.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)
        }
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveInject sessionId: String, terminalId: Int, text: String) {

        // 在主线程写入
        DispatchQueue.main.async {
            // 遍历所有 Coordinator 写入（terminalId 是全局唯一的，只有一个会真正写入）
            for coordinator in WindowManager.shared.getAllCoordinators() {
                coordinator.writeInput(terminalId: terminalId, data: text)
            }

            // 延迟一点发送回车
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                for coordinator in WindowManager.shared.getAllCoordinators() {
                    coordinator.writeInput(terminalId: terminalId, data: "\r")
                }
            }
        }
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveMobileViewing sessionId: String, isViewing: Bool) {
        guard let terminalId = ClaudeSessionMapper.shared.getTerminalId(for: sessionId) else {
            return
        }

        // 更新 mobile 查看状态
        if isViewing {
            mobileViewingTerminals.insert(terminalId)
        } else {
            mobileViewingTerminals.remove(terminalId)
        }

        // 触发 slot 刷新
        NotificationCenter.default.post(
            name: SlotRegistry<Tab>.slotDidChangeNotification,
            object: nil
        )
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?) {
        // 直接调用内部方法创建会话
        createClaudeSession(projectPath: projectPath, prompt: prompt, requestId: requestId)
    }
}

