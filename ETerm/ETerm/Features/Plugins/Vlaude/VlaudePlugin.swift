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
            return
        }

        // 上报 session 可用
        daemonClient?.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)
    }
}

// MARK: - VlaudeDaemonClientDelegate

extension VlaudePlugin: VlaudeDaemonClientDelegate {
    func daemonClient(_ client: VlaudeDaemonClient, didReceiveInject sessionId: String, terminalId: Int, text: String) {
        // 注入消息到 Terminal
        print("💉 [VlaudePlugin] 注入消息: session=\(sessionId), terminal=\(terminalId)")

        // 通过 NotificationCenter 请求写入
        NotificationCenter.default.post(
            name: .vlaudeInjectRequest,
            object: nil,
            userInfo: [
                "terminal_id": terminalId,
                "text": text + "\n"
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
