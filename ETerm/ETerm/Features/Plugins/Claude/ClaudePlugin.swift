//
//  ClaudePlugin.swift
//  ETerm
//
//  Claude Code 集成插件
//  负责：接收 Claude Hook 回调，管理 session 映射，控制 Tab 装饰

import Foundation
import AppKit

final class ClaudePlugin: Plugin {
    static let id = "claude"
    static let name = "Claude Integration"
    static let version = "1.0.0"

    private var socketServer: ClaudeSocketServer?
    private weak var context: PluginContext?

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 启动 Socket Server（接收 Claude Hook）
        socketServer = ClaudeSocketServer.shared
        socketServer?.start()

        // 监听 Claude 事件，控制 Tab 装饰
        setupNotifications()
    }

    func deactivate() {
        socketServer?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Tab 装饰控制

    private func setupNotifications() {
        // Claude 会话开始 → 设置"运行中"装饰（橙色脉冲）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionStart(_:)),
            name: .claudeSessionStart,
            object: nil
        )

        // Claude 响应完成 → 设置"完成"装饰（橙色静态）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResponseComplete(_:)),
            name: .claudeResponseComplete,
            object: nil
        )

        // Claude 会话结束 → 清除装饰
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionEnd(_:)),
            name: .claudeSessionEnd,
            object: nil
        )
    }

    @objc private func handleSessionStart(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 设置"运行中"装饰：橙色脉冲动画
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: TabDecoration(color: .systemOrange, style: .pulse)
        )
    }

    @objc private func handleResponseComplete(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 设置"完成"装饰：橙色静态（提醒用户查看）
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: TabDecoration(color: .systemOrange, style: .solid)
        )
    }

    @objc private func handleSessionEnd(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 清除装饰
        context?.ui.clearTabDecoration(terminalId: terminalId)
    }
}
