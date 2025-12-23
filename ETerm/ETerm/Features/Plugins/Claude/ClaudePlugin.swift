//
//  ClaudePlugin.swift
//  ETerm
//
//  Claude Code 集成插件
//
//  职责：
//  - 接收 Claude Hook 回调（通过 ClaudeSocketServer）
//  - 管理 Session 映射和持久化（通过 ClaudeSessionMapper）
//  - 控制 Tab 装饰（思考中、等待输入、完成）
//  - 处理终端恢复（重启后自动恢复 Claude 会话）

import Foundation
import AppKit
import SwiftUI

final class ClaudePlugin: Plugin {
    static let id = "claude"
    static let name = "Claude Integration"
    static let version = "1.0.0"

    private var socketServer: ClaudeSocketServer?
    private weak var context: PluginContext?

    /// 装饰状态类型
    private enum DecorationState {
        case thinking      // 蓝色脉冲，focus 时保持
        case waitingInput  // 黄色脉冲，focus 时清除
        case completed     // 橙色静态，focus 时清除
    }

    /// 每个终端的装饰状态（用于 focus 时判断是否清除）
    private var decorationStates: [Int: DecorationState] = [:]

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 启动 Socket Server（接收 Claude Hook）
        socketServer = ClaudeSocketServer.shared
        socketServer?.start()

        // 监听 Claude 事件
        setupNotifications()

        // 监听终端生命周期（恢复逻辑）
        setupTerminalLifecycleObservers()

        // 注册 Page Slot（显示该 Page 下 Claude 任务统计）
        registerPageSlot(context: context)
    }

    func deactivate() {
        socketServer?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Tab 装饰控制
    //
    // 事件流程：
    // UserPromptSubmit → 蓝色脉冲（思考中，focus 时保持）
    // Notification     → 黄色脉冲（等待用户输入，focus 时清除）
    // Stop             → 橙色静态（完成提醒，focus 时清除）
    // Focus Tab        → 清除 waitingInput 和 completed，保持 thinking
    // SessionEnd       → 清除

    private func setupNotifications() {
        // Session 开始 → 建立映射 + 持久化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionStart(_:)),
            name: .claudeSessionStart,
            object: nil
        )

        // 用户提交问题 → 设置"思考中"装饰（蓝色脉冲）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThinkingStart(_:)),
            name: .claudeUserPromptSubmit,
            object: nil
        )

        // Claude 等待用户输入 → 设置"等待输入"装饰（黄色脉冲）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWaitingInput(_:)),
            name: .claudeWaitingInput,
            object: nil
        )

        // Claude 响应完成 → 设置"完成"装饰（橙色静态）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResponseComplete(_:)),
            name: .claudeResponseComplete,
            object: nil
        )

        // Claude 会话结束 → 清除装饰 + 清理映射
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

    // MARK: - 终端生命周期监听

    private func setupTerminalLifecycleObservers() {
        // 终端创建 → 检查并恢复 Claude 会话
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalCreated(_:)),
            name: .terminalDidCreate,
            object: nil
        )

        // 终端关闭 → 清理 Session 映射
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalClosed(_:)),
            name: .terminalDidClose,
            object: nil
        )
    }

    // MARK: - Session 映射管理

    /// 处理 Session 开始 → 建立映射 + 持久化
    @objc private func handleSessionStart(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int,
              let sessionId = notification.userInfo?["session_id"] as? String else {
            return
        }

        // 获取 tabId 用于持久化
        guard let tabId = context?.terminal.getTabId(for: terminalId) else {
            return
        }

        // 建立映射 + 持久化
        ClaudeSessionMapper.shared.establish(
            terminalId: terminalId,
            sessionId: sessionId,
            tabId: tabId
        )
    }

    /// 处理终端创建 → 检查并恢复 Claude 会话
    @objc private func handleTerminalCreated(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int,
              let tabId = notification.userInfo?["tab_id"] as? String else {
            return
        }

        // 检查是否需要恢复
        guard let sessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId) else {
            return
        }

        // 延迟恢复，等待终端完全启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            // 重新验证：确保 tab 仍然对应同一个 sessionId
            // （防止终端在延迟期间关闭或 ID 被复用）
            guard let currentSessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId),
                  currentSessionId == sessionId else {
                return
            }

            // 重新验证：确保 terminalId 仍然属于这个 tabId
            guard let currentTabId = self.context?.terminal.getTabId(for: terminalId),
                  currentTabId == tabId else {
                return
            }

            self.context?.terminal.write(
                terminalId: terminalId,
                data: "claude --resume \(sessionId)\n"
            )
        }
    }

    /// 处理终端关闭 → 清理 Session 映射
    @objc private func handleTerminalClosed(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int,
              let tabId = notification.userInfo?["tab_id"] as? String else {
            return
        }

        // 清理映射
        ClaudeSessionMapper.shared.end(terminalId: terminalId, tabId: tabId)
    }

    /// 处理思考开始
    @objc private func handleThinkingStart(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 记录状态：thinking（focus 时不清除）
        decorationStates[terminalId] = .thinking

        // 设置"思考中"装饰：蓝色脉冲动画（plugin priority 101，高于 system active）
        // thinking 状态即使用户在看也要显示（Claude 正在工作）
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: .thinking(pluginId: Self.id),
            skipIfActive: false
        )

        // 智能标题生成：根据 prompt 生成简短标题
        // 先设置 "Claude" 作为临时标题，然后异步生成智能标题
        context?.ui.setTabTitle(terminalId: terminalId, title: "Claude")

        if let prompt = notification.userInfo?["prompt"] as? String, !prompt.isEmpty {
            // 异步生成智能标题
            ClaudeTitleGenerator.shared.generateTitle(from: prompt) { [weak self] title in
                // 检查终端是否还在 thinking 状态（可能已经完成了）
                guard self?.decorationStates[terminalId] == .thinking else {
                    return
                }
                self?.context?.ui.setTabTitle(terminalId: terminalId, title: title)
            }
        }
    }

    /// 处理等待用户输入
    @objc private func handleWaitingInput(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 如果用户正在看这个 terminal，不需要提醒
        if context?.ui.isTerminalActive(terminalId: terminalId) == true {
            return
        }

        // 用户不在看，设置"等待输入"装饰提醒
        decorationStates[terminalId] = .waitingInput
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: .waitingInput(pluginId: Self.id),
            skipIfActive: false
        )
    }

    /// 处理响应完成
    @objc private func handleResponseComplete(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 如果用户正在看这个 terminal，直接清除装饰（不需要提醒）
        // 这也处理了 ESC 中断的情况：清除 thinking 状态，不设置 completed
        if context?.ui.isTerminalActive(terminalId: terminalId) == true {
            decorationStates.removeValue(forKey: terminalId)
            context?.ui.clearTabDecoration(terminalId: terminalId)
            return
        }

        // 用户不在看，设置"完成"装饰提醒
        decorationStates[terminalId] = .completed
        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: .completed(pluginId: Self.id),
            skipIfActive: false
        )
    }

    /// 处理会话结束
    @objc private func handleSessionEnd(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // 清除装饰状态
        decorationStates.removeValue(forKey: terminalId)

        // 清除装饰
        context?.ui.clearTabDecoration(terminalId: terminalId)

        // 清除 Tab 标题
        context?.ui.clearTabTitle(terminalId: terminalId)

        // 清理 Session 映射（如果有 tabId）
        if let tabId = context?.terminal.getTabId(for: terminalId) {
            ClaudeSessionMapper.shared.end(terminalId: terminalId, tabId: tabId)
        }
    }

    /// 处理 Tab 获得焦点（用户切换到该 Tab）
    @objc private func handleTabFocus(_ notification: Notification) {
        guard let terminalId = notification.userInfo?["terminal_id"] as? Int else {
            return
        }

        // waitingInput 和 completed 状态在 focus 时清除（用户已经看到了）
        // thinking 状态保持（Claude 还在工作）
        guard let state = decorationStates[terminalId],
              state == .waitingInput || state == .completed else {
            return
        }

        // 清除状态和装饰
        decorationStates.removeValue(forKey: terminalId)
        context?.ui.clearTabDecoration(terminalId: terminalId)
    }

    // MARK: - Page Slot 注册

    /// 注册 Page Slot，显示该 Page 下的 Claude 任务统计
    ///
    /// 显示逻辑：
    /// - 蓝色圆点 + 数字：思考中的 Tab 数量（priority = 101）
    /// - 黄色圆点 + 数字：等待输入的 Tab 数量（priority = 6）
    /// - 橙色圆点 + 数字：已完成的 Tab 数量（priority = 5）
    private func registerPageSlot(context: PluginContext) {
        context.ui.registerPageSlot(
            for: Self.id,
            slotId: "claude-stats",
            priority: 50
        ) { [weak self] page in
            guard self != nil else { return nil }

            // 统计该 Page 下所有 Tab 的装饰状态
            let allTabs = page.allPanels.flatMap { $0.tabs }

            // 思考中：plugin(id: "claude", priority: 101)
            let thinkingCount = allTabs.filter { tab in
                guard let decoration = tab.decoration else { return false }
                // 匹配：plugin 类型且 plugin ID 为 "claude" 且 priority == 101
                if case .plugin(let id, let priority) = decoration.priority,
                   id == Self.id, priority == 101 {
                    return true
                }
                return false
            }.count

            // 等待输入：plugin(id: "claude", priority: 6)
            let waitingInputCount = allTabs.filter { tab in
                guard let decoration = tab.decoration else { return false }
                // 匹配：plugin 类型且 plugin ID 为 "claude" 且 priority == 6
                if case .plugin(let id, let priority) = decoration.priority,
                   id == Self.id, priority == 6 {
                    return true
                }
                return false
            }.count

            // 已完成：plugin(id: "claude", priority: 5)
            let completedCount = allTabs.filter { tab in
                guard let decoration = tab.decoration else { return false }
                // 匹配：plugin 类型且 plugin ID 为 "claude" 且 priority == 5
                if case .plugin(let id, let priority) = decoration.priority,
                   id == Self.id, priority == 5 {
                    return true
                }
                return false
            }.count

            // 如果都为 0，不显示 slot
            guard thinkingCount > 0 || waitingInputCount > 0 || completedCount > 0 else {
                return nil
            }

            // 返回统计视图
            return AnyView(
                HStack(spacing: 4) {
                    // 思考中（蓝色圆点 + 数字）
                    if thinkingCount > 0 {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                            Text("\(thinkingCount)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    // 等待输入（黄色圆点 + 数字）
                    if waitingInputCount > 0 {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 6, height: 6)
                            Text("\(waitingInputCount)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    // 已完成（橙色圆点 + 数字）
                    if completedCount > 0 {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("\(completedCount)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            )
        }
    }
}
