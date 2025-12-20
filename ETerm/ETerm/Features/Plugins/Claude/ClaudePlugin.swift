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
    //
    // 事件流程：
    // SessionStart     → 脉冲（启动中）
    // UserPromptSubmit → 脉冲（思考中）← 每次用户输入都会触发
    // Stop             → 静态橙色（完成提醒）
    // SessionEnd       → 清除

    private func setupNotifications() {
        // Claude 会话开始 → 设置"启动中"装饰（橙色脉冲）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThinkingStart(_:)),
            name: .claudeSessionStart,
            object: nil
        )

        // 用户提交问题 → 设置"思考中"装饰（橙色脉冲）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThinkingStart(_:)),
            name: .claudeUserPromptSubmit,
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

    /// 处理思考开始（SessionStart 或 UserPromptSubmit）
    @objc private func handleThinkingStart(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 设置"思考中"装饰：橙色脉冲动画
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: TabDecoration(color: .systemOrange, style: .pulse)
        )
    }

    /// 处理响应完成
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

    /// 处理会话结束
    @objc private func handleSessionEnd(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 清除装饰
        context?.ui.clearTabDecoration(terminalId: terminalId)
    }
}
