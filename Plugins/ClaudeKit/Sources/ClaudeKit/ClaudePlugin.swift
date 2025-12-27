//
//  ClaudePlugin.swift
//  ClaudeKit
//
//  Claude Code 集成插件 (SDK 版本)
//
//  职责：
//  - 接收 Claude Hook 回调（通过 ClaudeSocketServer）
//  - 控制 Tab 装饰（思考中、等待输入、完成）
//  - 显示 Page Slot 统计

import Foundation
import AppKit
import SwiftUI
import ETermKit

@objc(ClaudePlugin)
public final class ClaudePlugin: NSObject, Plugin {
    public static var id = "com.eterm.claude"

    private var socketServer: ClaudeSocketServer?
    private weak var host: HostBridge?

    /// 装饰状态类型（支持多状态共存）
    private enum DecorationState: Hashable, Comparable {
        case thinking      // 蓝色脉冲，focus 时保持，优先级 101
        case waitingInput  // 黄色脉冲，focus 时清除，优先级 102
        case completed     // 橙色静态，focus 时清除，优先级 5

        var priority: Int {
            switch self {
            case .waitingInput: return 102
            case .thinking: return 101
            case .completed: return 5
            }
        }

        var clearOnFocus: Bool {
            switch self {
            case .thinking: return false
            case .waitingInput, .completed: return true
            }
        }

        static func < (lhs: DecorationState, rhs: DecorationState) -> Bool {
            lhs.priority < rhs.priority
        }
    }

    /// 每个终端的装饰状态集合
    private var decorationStates: [Int: Set<DecorationState>] = [:]

    /// Session 映射 (terminalId -> sessionId)
    private var sessionMap: [Int: String] = [:]

    /// 启动阶段标志：false 表示启动阶段（由 checkExistingTerminalsForResume 统一处理）
    /// true 表示运行阶段（由 handleTerminalCreated 处理新建终端）
    private var hasCheckedForResume = false

    public override required init() {
        super.init()
    }

    // MARK: - Plugin Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 强制初始化 SessionMapper（触发迁移）
        _ = ClaudeSessionMapper.shared

        // 启动 Socket Server
        socketServer = ClaudeSocketServer()
        socketServer?.onEvent = { [weak self] event in
            self?.handleHookEvent(event)
        }

        let socketPath = host.socketPath(for: "claude")
        socketServer?.start(at: socketPath)
        print("[ClaudeKit] Plugin activated, socket: \(socketPath)")

        // 监听插件加载完成通知，检查已有终端是否需要恢复
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.PluginsLoaded"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkExistingTerminalsForResume()
        }

        // 已移除：asyncAfter fallback（使用单一触发机制）
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        //     self?.checkExistingTerminalsForResume()
        // }
    }

    /// 检查已存在的终端是否需要恢复 Claude 会话
    private func checkExistingTerminalsForResume() {
        // 防止重复执行
        guard !hasCheckedForResume else { return }
        hasCheckedForResume = true

        guard let host = host else { return }

        // 获取所有终端信息并过滤出需要恢复的
        let terminals = host.getAllTerminals()
        let sessionsToResume = terminals.compactMap { info -> (Int, String, String)? in
            guard let sessionId = ClaudeSessionMapper.shared.getSessionIdForTab(info.tabId) else { return nil }
            return (info.terminalId, info.tabId, sessionId)
        }

        guard !sessionsToResume.isEmpty else { return }
        print("[ClaudeKit] Resuming \(sessionsToResume.count) sessions")

        for (terminalId, tabId, sessionId) in sessionsToResume {
            // 延迟恢复
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }

                // 验证 session 仍然有效
                guard let currentSessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId),
                      currentSessionId == sessionId else { return }

                self.host?.writeToTerminal(
                    terminalId: terminalId,
                    data: "claude --resume \(sessionId)\n"
                )
            }
        }
    }

    public func deactivate() {
        socketServer?.stop()
        socketServer = nil
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "tab.didActivate":
            if let terminalId = payload["terminalId"] as? Int {
                handleTabActivate(terminalId: terminalId)
            }

        case "terminal.didCreate":
            if let terminalId = payload["terminalId"] as? Int,
               let tabId = payload["tabId"] as? String {
                handleTerminalCreated(terminalId: terminalId, tabId: tabId)
            }

        case "terminal.didClose":
            if let terminalId = payload["terminalId"] as? Int,
               let tabId = payload["tabId"] as? String {
                handleTerminalClosed(terminalId: terminalId, tabId: tabId)
            }

        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令
    }

    // MARK: - Hook Event Handling

    /// 构造事件广播的基础 payload
    private func makePayload(_ event: ClaudeHookEvent, extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "terminalId": event.terminal_id,
            "sessionId": event.session_id,
            "transcriptPath": event.transcript_path ?? "",
            "cwd": event.cwd ?? ""
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        return payload
    }

    private func handleHookEvent(_ event: ClaudeHookEvent) {
        let eventType = event.event_type ?? "stop"
        let terminalId = event.terminal_id

        // 更新 session 映射
        sessionMap[terminalId] = event.session_id

        switch eventType {
        case "session_start":
            // Session 开始，建立持久化映射
            if let tabId = getTabId(for: terminalId) {
                ClaudeSessionMapper.shared.establish(
                    terminalId: terminalId,
                    sessionId: event.session_id,
                    tabId: tabId
                )
            }
            host?.emit(eventName: "claude.sessionStart", payload: makePayload(event))

        case "user_prompt_submit":
            handlePromptSubmit(terminalId: terminalId, prompt: event.prompt)
            host?.emit(eventName: "claude.promptSubmit", payload: makePayload(event, extra: [
                "prompt": event.prompt ?? ""
            ]))

        case "notification":
            handleWaitingInput(terminalId: terminalId)
            host?.emit(eventName: "claude.waitingInput", payload: makePayload(event))

        case "stop":
            handleResponseComplete(terminalId: terminalId)
            host?.emit(eventName: "claude.responseComplete", payload: makePayload(event))

        case "session_end":
            handleSessionEnd(terminalId: terminalId)
            host?.emit(eventName: "claude.sessionEnd", payload: makePayload(event))

        default:
            break
        }
    }

    // MARK: - State Handling

    private func handlePromptSubmit(terminalId: Int, prompt: String?) {
        addState(.thinking, for: terminalId)

        // 设置临时标题
        host?.setTabTitle(terminalId: terminalId, title: "Claude")

        // 智能标题生成：根据 prompt 生成简短标题
        if let prompt = prompt, !prompt.isEmpty {
            // 异步生成智能标题
            Task { [weak self] in
                if let title = await ClaudeTitleGenerator.shared.generateTitle(from: prompt) {
                    await MainActor.run {
                        self?.host?.setTabTitle(terminalId: terminalId, title: title)
                    }
                }
            }
        }
    }

    private func handleWaitingInput(terminalId: Int) {
        // 如果用户正在看，不需要提醒
        if isTerminalActive(terminalId) {
            return
        }

        addState(.waitingInput, for: terminalId)
    }

    private func handleResponseComplete(terminalId: Int) {
        // 移除 thinking 状态
        removeState(.thinking, for: terminalId)

        // 如果用户正在看，清除所有状态
        if isTerminalActive(terminalId) {
            decorationStates.removeValue(forKey: terminalId)
            host?.clearTabDecoration(terminalId: terminalId)
            return
        }

        // 添加 completed 状态提醒
        addState(.completed, for: terminalId)
    }

    private func handleSessionEnd(terminalId: Int) {
        decorationStates.removeValue(forKey: terminalId)
        host?.clearTabDecoration(terminalId: terminalId)
        host?.clearTabTitle(terminalId: terminalId)
        sessionMap.removeValue(forKey: terminalId)

        // 清理持久化映射
        if let tabId = getTabId(for: terminalId) {
            ClaudeSessionMapper.shared.end(terminalId: terminalId, tabId: tabId)
        }
    }

    private func handleTabActivate(terminalId: Int) {
        guard var states = decorationStates[terminalId], !states.isEmpty else {
            return
        }

        // 移除所有 clearOnFocus 的状态
        let statesToRemove = states.filter { $0.clearOnFocus }
        guard !statesToRemove.isEmpty else { return }

        states.subtract(statesToRemove)

        if states.isEmpty {
            decorationStates.removeValue(forKey: terminalId)
            host?.clearTabDecoration(terminalId: terminalId)
        } else {
            decorationStates[terminalId] = states
            updateDecoration(for: terminalId)
        }
    }

    /// 处理终端创建 → 检查并恢复 Claude 会话
    private func handleTerminalCreated(terminalId: Int, tabId: String) {
        // 启动阶段跳过，由 checkExistingTerminalsForResume 统一处理
        guard hasCheckedForResume else { return }

        // 检查是否需要恢复
        guard let sessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId) else { return }

        // 延迟恢复，等待终端完全启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            // 重新验证：确保 tab 仍然对应同一个 sessionId
            guard let currentSessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabId),
                  currentSessionId == sessionId else { return }

            // 重新验证：确保 terminalId 仍然属于这个 tabId
            guard let currentTabId = self.getTabId(for: terminalId),
                  currentTabId == tabId else { return }

            print("[ClaudeKit] Resuming session \(sessionId)")
            self.host?.writeToTerminal(
                terminalId: terminalId,
                data: "claude --resume \(sessionId)\n"
            )
        }
    }

    /// 处理终端关闭 → 清理 Session 映射
    private func handleTerminalClosed(terminalId: Int, tabId: String) {
        decorationStates.removeValue(forKey: terminalId)
        sessionMap.removeValue(forKey: terminalId)
        ClaudeSessionMapper.shared.end(terminalId: terminalId, tabId: tabId)
    }

    // MARK: - Decoration Helpers

    private func addState(_ state: DecorationState, for terminalId: Int) {
        var states = decorationStates[terminalId] ?? []
        states.insert(state)
        decorationStates[terminalId] = states
        updateDecoration(for: terminalId)
    }

    private func removeState(_ state: DecorationState, for terminalId: Int) {
        guard var states = decorationStates[terminalId] else { return }
        states.remove(state)

        if states.isEmpty {
            decorationStates.removeValue(forKey: terminalId)
            host?.clearTabDecoration(terminalId: terminalId)
        } else {
            decorationStates[terminalId] = states
            updateDecoration(for: terminalId)
        }
    }

    private func updateDecoration(for terminalId: Int) {
        guard let states = decorationStates[terminalId],
              let topState = states.max() else {
            host?.clearTabDecoration(terminalId: terminalId)
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

        host?.setTabDecoration(terminalId: terminalId, decoration: decoration)
    }

    private func hasState(_ state: DecorationState, for terminalId: Int) -> Bool {
        decorationStates[terminalId]?.contains(state) ?? false
    }

    private func isTerminalActive(_ terminalId: Int) -> Bool {
        host?.getActiveTerminalId() == terminalId
    }

    /// 获取终端对应的 tabId
    private func getTabId(for terminalId: Int) -> String? {
        host?.getTerminalInfo(terminalId: terminalId)?.tabId
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        nil
    }

    public func bottomDockView(for id: String) -> AnyView? {
        nil
    }

    public func infoPanelView(for id: String) -> AnyView? {
        nil
    }

    public func bubbleView(for id: String) -> AnyView? {
        nil
    }

    public func menuBarView() -> AnyView? {
        nil
    }

    public func pageBarView(for itemId: String) -> AnyView? {
        nil
    }

    public func windowBottomOverlayView(for id: String) -> AnyView? {
        nil
    }

    public func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
        nil
    }

    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        guard slotId == "claude-stats" else { return nil }

        // 统计该 Page 下所有 Tab 的装饰状态
        let allTabs = page.slotTabs

        // 思考中：plugin(id: "com.eterm.claude", priority: 101)
        let thinkingCount = allTabs.filter { tab in
            guard let decoration = tab.decoration else { return false }
            if case .plugin(let id, let priority) = decoration.priority,
               id == Self.id, priority == 101 {
                return true
            }
            return false
        }.count

        // 等待输入：plugin(id: "com.eterm.claude", priority: 102)
        let waitingInputCount = allTabs.filter { tab in
            guard let decoration = tab.decoration else { return false }
            if case .plugin(let id, let priority) = decoration.priority,
               id == Self.id, priority == 102 {
                return true
            }
            return false
        }.count

        // 已完成：plugin(id: "com.eterm.claude", priority: 5)
        let completedCount = allTabs.filter { tab in
            guard let decoration = tab.decoration else { return false }
            if case .plugin(let id, let priority) = decoration.priority,
               id == Self.id, priority == 5 {
                return true
            }
            return false
        }.count

        // 如果都为 0，不显示
        guard thinkingCount > 0 || waitingInputCount > 0 || completedCount > 0 else {
            return nil
        }

        return AnyView(
            HStack(spacing: 4) {
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
