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

    /// 装饰状态类型
    private enum DecorationState {
        case thinking   // 蓝色脉冲，focus 时保持
        case completed  // 橙色静态，focus 时清除
    }

    /// 每个终端的装饰状态（用于 focus 时判断是否清除）
    private var decorationStates: [Int: DecorationState] = [:]

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
    // UserPromptSubmit → 蓝色脉冲（思考中，focus 时保持）
    // Stop             → 橙色静态（完成提醒，focus 时清除）
    // Focus Tab        → 只清除 completed，保持 thinking
    // SessionEnd       → 清除

    private func setupNotifications() {
        // 用户提交问题 → 设置"思考中"装饰（蓝色脉冲）
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

        // 用户切换到 Tab → 清除装饰（用户已经看到了）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabFocus(_:)),
            name: .tabDidFocus,
            object: nil
        )
    }

    /// 处理思考开始
    @objc private func handleThinkingStart(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 记录状态：thinking（focus 时不清除）
        decorationStates[terminalId] = .thinking

        // 设置"思考中"装饰：蓝色脉冲动画（优先级 101，高于 active）
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: .thinking
        )
    }

    /// 处理响应完成
    @objc private func handleResponseComplete(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 记录状态：completed（focus 时清除）
        decorationStates[terminalId] = .completed

        // 设置"完成"装饰：橙色静态（优先级 5，低于 active）
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: .completed
        )
    }

    /// 处理会话结束
    @objc private func handleSessionEnd(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 清除状态
        decorationStates.removeValue(forKey: terminalId)

        // 清除装饰
        context?.ui.clearTabDecoration(terminalId: terminalId)
    }

    /// 处理 Tab 获得焦点（用户切换到该 Tab）
    @objc private func handleTabFocus(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 只有 completed 状态才清除（用户看到了完成提醒）
        // thinking 状态保持（Claude 还在工作）
        guard decorationStates[terminalId] == .completed else {
            return
        }

        // 清除状态和装饰
        decorationStates.removeValue(forKey: terminalId)
        context?.ui.clearTabDecoration(terminalId: terminalId)
    }
}
