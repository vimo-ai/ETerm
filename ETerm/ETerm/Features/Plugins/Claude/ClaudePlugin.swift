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

    /// 事件订阅句柄
    private var subscriptions: [EventSubscription] = []

    /// 装饰状态类型（支持多状态共存）
    private enum DecorationState: Hashable, Comparable {
        case thinking      // 蓝色脉冲，focus 时保持，优先级 101
        case waitingInput  // 黄色脉冲，focus 时清除，优先级 102（高于 thinking，需要用户注意）
        case completed     // 橙色静态，focus 时清除，优先级 5

        /// 优先级（数值越大越优先显示）
        /// waitingInput > thinking：当需要用户输入时，黄色提醒优先显示
        var priority: Int {
            switch self {
            case .waitingInput: return 102  // 最高，需要用户注意
            case .thinking: return 101
            case .completed: return 5
            }
        }

        /// 是否在 focus 时清除
        var clearOnFocus: Bool {
            switch self {
            case .thinking: return false
            case .waitingInput, .completed: return true
            }
        }

        /// 比较（用于排序，优先级高的在前）
        static func < (lhs: DecorationState, rhs: DecorationState) -> Bool {
            lhs.priority < rhs.priority
        }
    }

    /// 每个终端的装饰状态集合（支持多状态共存，独立生命周期）
    private var decorationStates: [Int: Set<DecorationState>] = [:]

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 启动 Socket Server（接收 Claude Hook）
        socketServer = ClaudeSocketServer.shared
        socketServer?.start()

        // 订阅事件
        setupEventSubscriptions(context: context)

        // 注册 Page Slot（显示该 Page 下 Claude 任务统计）
        registerPageSlot(context: context)
    }

    func deactivate() {
        socketServer?.stop()
        // EventSubscription 在 removeAll 时自动取消订阅
        subscriptions.removeAll()
    }

    // MARK: - Tab 装饰控制
    //
    // 事件流程：
    // PromptSubmit    → 蓝色脉冲（思考中，focus 时保持）
    // WaitingInput    → 黄色脉冲（等待用户输入，focus 时清除）
    // ResponseComplete → 橙色静态（完成提醒，focus 时清除）
    // Tab.DidActivate → 清除 waitingInput 和 completed，保持 thinking
    // SessionEnd      → 清除

    private func setupEventSubscriptions(context: PluginContext) {
        // Claude 事件订阅

        // Session 开始 → 建立映射 + 持久化
        subscriptions.append(
            context.events.subscribe(ClaudeEvents.SessionStart.self) { [weak self] event in
                self?.handleSessionStart(event)
            }
        )

        // 用户提交问题 → 设置"思考中"装饰（蓝色脉冲）
        subscriptions.append(
            context.events.subscribe(ClaudeEvents.PromptSubmit.self) { [weak self] event in
                self?.handlePromptSubmit(event)
            }
        )

        // 等待用户输入 → 设置"等待输入"装饰（黄色脉冲）
        subscriptions.append(
            context.events.subscribe(ClaudeEvents.WaitingInput.self) { [weak self] event in
                self?.handleWaitingInput(event)
            }
        )

        // 响应完成 → 设置"完成"装饰（橙色静态）
        subscriptions.append(
            context.events.subscribe(ClaudeEvents.ResponseComplete.self) { [weak self] event in
                self?.handleResponseComplete(event)
            }
        )

        // 会话结束 → 清除装饰 + 清理映射
        subscriptions.append(
            context.events.subscribe(ClaudeEvents.SessionEnd.self) { [weak self] event in
                self?.handleSessionEnd(event)
            }
        )

        // Core 事件订阅

        // Tab 激活 → 清除装饰（用户已经看到了）
        subscriptions.append(
            context.events.subscribe(CoreEvents.Tab.DidActivate.self) { [weak self] event in
                self?.handleTabActivate(event)
            }
        )

        // 终端创建 → 检查并恢复 Claude 会话
        subscriptions.append(
            context.events.subscribe(CoreEvents.Terminal.DidCreate.self) { [weak self] event in
                self?.handleTerminalCreated(event)
            }
        )

        // 终端关闭 → 清理 Session 映射
        subscriptions.append(
            context.events.subscribe(CoreEvents.Terminal.DidClose.self) { [weak self] event in
                self?.handleTerminalClosed(event)
            }
        )
    }

    // MARK: - Claude 事件处理

    /// 处理 Session 开始 → 建立映射 + 持久化
    private func handleSessionStart(_ event: ClaudeEvents.SessionStart) {
        // 获取 tabId 用于持久化
        guard let tabId = context?.terminal.getTabId(for: event.terminalId) else {
            return
        }

        // 建立映射 + 持久化
        ClaudeSessionMapper.shared.establish(
            terminalId: event.terminalId,
            sessionId: event.sessionId,
            tabId: tabId
        )
    }

    /// 处理用户提交问题
    ///
    /// - Note: 已知限制 - 用户按 ESC 中断对话时，Claude Code 的 Stop hook 不会触发，
    ///   因此 thinking 状态会一直保持。下次正常对话完成后会自动清除。
    ///   参考：GitHub Issue #9516 请求添加 Interrupt Hook，目前未实现。
    private func handlePromptSubmit(_ event: ClaudeEvents.PromptSubmit) {
        // 添加 thinking 状态（不覆盖其他状态）
        // thinking 状态即使用户在看也要显示（Claude 正在工作）
        addState(.thinking, for: event.terminalId)

        // 智能标题生成：根据 prompt 生成简短标题
        // 先设置 "Claude" 作为临时标题，然后异步生成智能标题
        context?.ui.setTabTitle(terminalId: event.terminalId, title: "Claude")

        if let prompt = event.prompt, !prompt.isEmpty {
            // 异步生成智能标题
            ClaudeTitleGenerator.shared.generateTitle(from: prompt) { [weak self] title in
                // 检查终端是否还在 thinking 状态（可能已经完成了）
                guard self?.hasState(.thinking, for: event.terminalId) == true else {
                    return
                }
                self?.context?.ui.setTabTitle(terminalId: event.terminalId, title: title)
            }
        }
    }

    /// 处理等待用户输入
    private func handleWaitingInput(_ event: ClaudeEvents.WaitingInput) {
        // 如果用户正在看这个 terminal，不需要提醒
        if context?.ui.isTerminalActive(terminalId: event.terminalId) == true {
            return
        }

        // 添加 waitingInput 状态（不移除 thinking，两者共存）
        addState(.waitingInput, for: event.terminalId)
    }

    /// 处理响应完成
    private func handleResponseComplete(_ event: ClaudeEvents.ResponseComplete) {
        // 移除 thinking 状态（Claude 思考完了）
        removeState(.thinking, for: event.terminalId)

        // 如果用户正在看这个 terminal，清除所有状态（不需要提醒）
        if context?.ui.isTerminalActive(terminalId: event.terminalId) == true {
            decorationStates.removeValue(forKey: event.terminalId)
            context?.ui.clearTabDecoration(terminalId: event.terminalId)
            return
        }

        // 用户不在看，添加 completed 状态提醒
        addState(.completed, for: event.terminalId)
    }

    /// 处理会话结束
    private func handleSessionEnd(_ event: ClaudeEvents.SessionEnd) {
        // 清除装饰状态
        decorationStates.removeValue(forKey: event.terminalId)

        // 清除装饰
        context?.ui.clearTabDecoration(terminalId: event.terminalId)

        // 清除 Tab 标题
        context?.ui.clearTabTitle(terminalId: event.terminalId)

        // 清理 Session 映射（如果有 tabId）
        if let tabId = context?.terminal.getTabId(for: event.terminalId) {
            ClaudeSessionMapper.shared.end(terminalId: event.terminalId, tabId: tabId)
        }
    }

    // MARK: - Core 事件处理

    /// 处理 Tab 激活（用户切换到该 Tab）
    private func handleTabActivate(_ event: CoreEvents.Tab.DidActivate) {
        // 获取当前状态集合
        guard var states = decorationStates[event.terminalId], !states.isEmpty else {
            return
        }

        // 移除所有 clearOnFocus 的状态（waitingInput、completed）
        let statesToRemove = states.filter { $0.clearOnFocus }
        guard !statesToRemove.isEmpty else {
            return  // 没有需要清除的状态
        }

        states.subtract(statesToRemove)

        // 更新状态集合并刷新装饰
        if states.isEmpty {
            decorationStates.removeValue(forKey: event.terminalId)
            context?.ui.clearTabDecoration(terminalId: event.terminalId)
        } else {
            decorationStates[event.terminalId] = states
            updateDecoration(for: event.terminalId)
        }
    }

    /// 处理终端创建 → 检查并恢复 Claude 会话
    private func handleTerminalCreated(_ event: CoreEvents.Terminal.DidCreate) {
        // [TEST MODE] 暂时禁用 Claude resume 功能
        return

        // let terminalId = event.terminalId
        // let tabId = event.tabId
        //
        // // 检查是否需要恢复
        // guard let sessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId) else {
        //     return
        // }
        //
        // // 延迟恢复，等待终端完全启动
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        //     guard let self = self else { return }
        //
        //     // 重新验证：确保 tab 仍然对应同一个 sessionId
        //     guard let currentSessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId),
        //           currentSessionId == sessionId else {
        //         return
        //     }
        //
        //     // 重新验证：确保 terminalId 仍然属于这个 tabId
        //     guard let currentTabId = self.context?.terminal.getTabId(for: terminalId),
        //           currentTabId == tabId else {
        //         return
        //     }
        //
        //     self.context?.terminal.write(
        //         terminalId: terminalId,
        //         data: "claude --resume \(sessionId)\n"
        //     )
        // }
    }

    /// 处理终端关闭 → 清理 Session 映射
    private func handleTerminalClosed(_ event: CoreEvents.Terminal.DidClose) {
        guard let tabId = event.tabId else { return }
        ClaudeSessionMapper.shared.end(terminalId: event.terminalId, tabId: tabId)
    }

    // MARK: - 装饰状态辅助方法

    /// 添加装饰状态并刷新显示
    private func addState(_ state: DecorationState, for terminalId: Int) {
        var states = decorationStates[terminalId] ?? []
        states.insert(state)
        decorationStates[terminalId] = states
        updateDecoration(for: terminalId)
    }

    /// 移除装饰状态并刷新显示
    private func removeState(_ state: DecorationState, for terminalId: Int) {
        guard var states = decorationStates[terminalId] else { return }
        states.remove(state)

        if states.isEmpty {
            decorationStates.removeValue(forKey: terminalId)
            context?.ui.clearTabDecoration(terminalId: terminalId)
        } else {
            decorationStates[terminalId] = states
            updateDecoration(for: terminalId)
        }
    }

    /// 根据当前状态集合更新 Tab 装饰（显示优先级最高的）
    private func updateDecoration(for terminalId: Int) {
        guard let states = decorationStates[terminalId],
              let topState = states.max() else {
            context?.ui.clearTabDecoration(terminalId: terminalId)
            return
        }

        let decoration: TabDecoration
        switch topState {
        case .thinking:
            decoration = .thinking(pluginId: Self.id)
        case .waitingInput:
            decoration = .waitingInput(pluginId: Self.id)
        case .completed:
            decoration = .completed(pluginId: Self.id)
        }

        context?.ui.setTabDecoration(
            terminalId: terminalId,
            decoration: decoration,
            skipIfActive: false
        )
    }

    /// 检查终端是否有指定状态
    private func hasState(_ state: DecorationState, for terminalId: Int) -> Bool {
        decorationStates[terminalId]?.contains(state) ?? false
    }

    // MARK: - Page Slot 注册

    /// 注册 Page Slot，显示该 Page 下的 Claude 任务统计
    ///
    /// 显示逻辑：
    /// - 蓝色圆点 + 数字：思考中的 Tab 数量（priority = 101）
    /// - 黄色圆点 + 数字：等待输入的 Tab 数量（priority = 102）
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
                if case .plugin(let id, let priority) = decoration.priority,
                   id == Self.id, priority == 101 {
                    return true
                }
                return false
            }.count

            // 等待输入：plugin(id: "claude", priority: 102)
            let waitingInputCount = allTabs.filter { tab in
                guard let decoration = tab.decoration else { return false }
                if case .plugin(let id, let priority) = decoration.priority,
                   id == Self.id, priority == 102 {
                    return true
                }
                return false
            }.count

            // 已完成：plugin(id: "claude", priority: 5)
            let completedCount = allTabs.filter { tab in
                guard let decoration = tab.decoration else { return false }
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
