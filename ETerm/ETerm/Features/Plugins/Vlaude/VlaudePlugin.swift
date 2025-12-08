//
//  VlaudePlugin.swift
//  ETerm
//
//  Vlaude 远程控制插件
//  负责：连接 daemon，上报 session 状态，接收注入请求

import Foundation

final class VlaudePlugin: Plugin {
    static let id = "vlaude"
    static let name = "Vlaude Remote"
    static let version = "1.0.0"

    private var daemonClient: VlaudeDaemonClient?
    private weak var context: PluginContext?

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 连接 daemon
        daemonClient = VlaudeDaemonClient()
        daemonClient?.delegate = self
        daemonClient?.connect()

        // 监听 session 映射变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionMapped(_:)),
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

        print("✅ [VlaudePlugin] 已激活")
    }

    func deactivate() {
        NotificationCenter.default.removeObserver(self)
        daemonClient?.disconnect()
        daemonClient = nil
        print("🛑 [VlaudePlugin] 已停用")
    }

    @objc private func handleSessionMapped(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionId = userInfo["session_id"] as? String,
              let terminalId = userInfo["terminal_id"] as? Int else {
            print("⚠️ [VlaudePlugin] 收到 claudeResponseComplete 但 userInfo 无效")
            return
        }

        print("📍 [VlaudePlugin] 上报 session 可用: \(sessionId.prefix(8))... -> Terminal \(terminalId)")
        // 上报 session 可用
        daemonClient?.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)
    }

    @objc private func handleTerminalClosed(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        // 查找该 terminal 对应的 session
        guard let sessionId = ClaudeSessionMapper.shared.getSessionId(for: terminalId) else {
            // 该 terminal 没有 Claude session，无需处理
            return
        }

        print("🗑️ [VlaudePlugin] Terminal \(terminalId) 关闭，上报 session 不可用: \(sessionId.prefix(8))...")

        // 清理本地映射
        ClaudeSessionMapper.shared.remove(terminalId: terminalId)

        // 通知 daemon
        daemonClient?.reportSessionUnavailable(sessionId: sessionId)
    }

    @objc private func handleClaudeSessionEnd(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionId = userInfo["session_id"] as? String,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        print("🛑 [VlaudePlugin] Claude 退出，上报 session 不可用: \(sessionId.prefix(8))... (Terminal \(terminalId))")

        // 清理本地映射
        ClaudeSessionMapper.shared.remove(terminalId: terminalId)

        // 通知 daemon
        daemonClient?.reportSessionUnavailable(sessionId: sessionId)
    }
}

// MARK: - VlaudeDaemonClientDelegate

extension VlaudePlugin: VlaudeDaemonClientDelegate {
    func daemonClientDidConnect(_ client: VlaudeDaemonClient) {
        // 连接成功后，上报所有已存在的 session 映射
        let mappings = ClaudeSessionMapper.shared.getAllMappings()
        print("🔄 [VlaudePlugin] 连接成功，上报 \(mappings.count) 个已存在的 session")

        for (sessionId, terminalId) in mappings {
            client.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)
        }
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveInject sessionId: String, terminalId: Int, text: String) {
        print("💉 [VlaudePlugin] 注入消息: session=\(sessionId), terminal=\(terminalId)")

        // 输入文本 + 回车发送
        let commands: [VlaudeInputCommand] = [
            .input(text),
            .controlKey("\r")
        ]

        NotificationCenter.default.post(
            name: .vlaudeInjectRequest,
            object: nil,
            userInfo: [
                "terminal_id": terminalId,
                "commands": commands
            ]
        )
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveMobileViewing sessionId: String, isViewing: Bool) {
        // 更新 Tab emoji
        print("📱 [VlaudePlugin] Mobile \(isViewing ? "正在查看" : "离开了") session \(sessionId)")

        guard let terminalId = ClaudeSessionMapper.shared.getTerminalId(for: sessionId) else {
            return
        }

        // 通过 NotificationCenter 通知 Tab 更新 emoji
        NotificationCenter.default.post(
            name: .vlaudeMobileViewingChanged,
            object: nil,
            userInfo: [
                "terminal_id": terminalId,
                "is_viewing": isViewing
            ]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let vlaudeMobileViewingChanged = Notification.Name("vlaudeMobileViewingChanged")
    static let vlaudeInjectRequest = Notification.Name("vlaudeInjectRequest")
}
