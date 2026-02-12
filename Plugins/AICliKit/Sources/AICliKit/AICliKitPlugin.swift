//
//  AICliKitPlugin.swift
//  AICliKit
//
//  AI CLI 集成插件 - 统一管理多种 AI CLI（Claude、Gemini、Codex、OpenCode）
//
//  职责：
//  - 管理多个 AI CLI Provider
//  - 接收各 Provider 的事件并统一处理
//  - 控制 Tab 装饰（思考中、等待输入、完成）
//  - 显示 Page Slot 统计

import Foundation
import AppKit
import SwiftUI
import ETermKit

@objc(AICliKitPlugin)
public final class AICliKitPlugin: NSObject, Plugin, AICliKitProtocol {
    public static var id = "com.eterm.aicli"

    private weak var host: HostBridge?

    // MARK: - Provider Management

    /// 已注册的 Provider 列表
    public private(set) var providers: [any AICliProvider] = []

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

    /// Session 映射 (terminalId -> sessionId)，线程安全访问
    private nonisolated(unsafe) var sessionMap: [Int: String] = [:]
    private let sessionMapLock = NSLock()

    /// 启动阶段标志
    private var hasCheckedForResume = false

    // MARK: - Waiting Services (for MCP call_plugin_service)

    private struct Waiter: Sendable {
        let terminalId: Int
        let semaphore: DispatchSemaphore
        var result: [String: Any]?
    }

    private nonisolated(unsafe) var sessionWaiters: [UUID: Waiter] = [:]
    private let sessionWaiterLock = NSLock()

    private nonisolated(unsafe) var responseWaiters: [UUID: Waiter] = [:]
    private let responseWaiterLock = NSLock()

    public override required init() {
        super.init()
    }

    // MARK: - Plugin Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 强制初始化 SessionMapper（触发迁移）
        _ = AICliSessionMapper.shared

        // 创建 Provider 配置
        let config = AICliProviderConfig(
            socketDirectory: (host.socketPath(for: "claude") as NSString).deletingLastPathComponent,
            hostBridge: host
        )

        // 注册所有 Provider
        registerProviders(config: config)

        // 注册服务
        registerServices(host: host)

        // 监听插件加载完成通知
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.PluginsLoaded"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkExistingTerminalsForResume()
        }
    }

    /// 注册所有 Provider
    private func registerProviders(config: AICliProviderConfig) {
        // Claude Provider
        let claudeProvider = ClaudeProvider()
        claudeProvider.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
        claudeProvider.start(config: config)
        providers.append(claudeProvider)

        // Gemini Provider
        let geminiProvider = GeminiProvider()
        geminiProvider.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
        geminiProvider.start(config: config)
        providers.append(geminiProvider)

        // Codex Provider
        let codexProvider = CodexProvider()
        codexProvider.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
        codexProvider.start(config: config)
        providers.append(codexProvider)

        // OpenCode Provider
        let openCodeProvider = OpenCodeProvider()
        openCodeProvider.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
        openCodeProvider.start(config: config)
        providers.append(openCodeProvider)
    }

    /// 注册服务
    private func registerServices(host: HostBridge) {
        // waitForSession 服务
        host.registerService(name: "waitForSession") { [weak self] params in
            self?.handleWaitForSession(params: params)
        }

        // waitForResponse 服务
        host.registerService(name: "waitForResponse") { [weak self] params in
            self?.handleWaitForResponse(params: params)
        }

        // getTerminalId 服务
        host.registerService(name: "getTerminalId") { params in
            guard let sessionId = params["sessionId"] as? String else { return nil }
            if let terminalId = AICliSessionMapper.shared.getTerminalId(for: sessionId) {
                return ["terminalId": terminalId]
            }
            return nil
        }

        // getSessionId 服务
        host.registerService(name: "getSessionId") { params in
            guard let terminalId = params["terminalId"] as? Int else { return nil }
            if let sessionId = AICliSessionMapper.shared.getSessionId(for: terminalId) {
                return ["sessionId": sessionId]
            }
            return nil
        }
    }

    /// 检查已存在的终端是否需要恢复会话
    private func checkExistingTerminalsForResume() {
        guard !hasCheckedForResume else { return }
        hasCheckedForResume = true

        guard let host = host else { return }

        let terminals = host.getAllTerminals()
        let sessionsToResume = terminals.compactMap { info -> (Int, String, String, String)? in
            guard let sessionId = AICliSessionMapper.shared.getSessionIdForTab(info.tabId),
                  let providerId = AICliSessionMapper.shared.getProviderIdForTab(info.tabId) else {
                return nil
            }
            return (info.terminalId, info.tabId, sessionId, providerId)
        }

        guard !sessionsToResume.isEmpty else { return }

        for (terminalId, tabId, sessionId, providerId) in sessionsToResume {
            // 重建运行时映射
            AICliSessionMapper.shared.establish(
                terminalId: terminalId,
                sessionId: sessionId,
                tabId: tabId,
                providerId: providerId
            )

            // 延迟恢复
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }

                guard let currentSessionId = AICliSessionMapper.shared.getSessionIdForTab(tabId),
                      currentSessionId == sessionId else { return }

                // 根据 provider 选择恢复命令（只有支持 --resume 的 CLI 才会返回命令）
                guard let resumeCommand = self.getResumeCommand(providerId: providerId, sessionId: sessionId) else {
                    return
                }
                self.host?.writeToTerminal(terminalId: terminalId, data: resumeCommand)
            }
        }
    }

    /// 获取恢复命令
    ///
    /// 目前只有 Claude 支持 --resume 参数，其他 CLI 暂不支持。
    private func getResumeCommand(providerId: String, sessionId: String) -> String? {
        switch providerId {
        case "claude":
            return "claude --resume \(sessionId)\n"
        // TODO: Gemini/OpenCode/Codex 的 --resume 支持待确认
        default:
            return nil
        }
    }

    public func deactivate() {
        for provider in providers {
            provider.stop()
        }
        providers.removeAll()
    }

    // MARK: - AICliKitProtocol

    /// 合并所有 Provider 的能力
    public var combinedCapabilities: AICliCapabilities {
        var caps = AICliCapabilities()
        for provider in providers {
            let providerCaps = type(of: provider).capabilities
            caps = AICliCapabilities(
                sessionStart: caps.sessionStart || providerCaps.sessionStart,
                sessionEnd: caps.sessionEnd || providerCaps.sessionEnd,
                userInput: caps.userInput || providerCaps.userInput,
                assistantThinking: caps.assistantThinking || providerCaps.assistantThinking,
                responseComplete: caps.responseComplete || providerCaps.responseComplete,
                waitingInput: caps.waitingInput || providerCaps.waitingInput,
                permissionRequest: caps.permissionRequest || providerCaps.permissionRequest,
                toolUse: caps.toolUse || providerCaps.toolUse
            )
        }
        return caps
    }

    /// 处理来自任意 Provider 的事件
    public func handleEvent(_ event: AICliEvent) {
        let terminalId = event.terminalId
        let hostAlive = host != nil
        logInfo("[AICliSocket] handleEvent: \(event.type) tid=\(terminalId) sid=\(event.sessionId.prefix(8)) host=\(hostAlive)")

        // 更新 session 映射
        sessionMapLock.lock()
        sessionMap[terminalId] = event.sessionId
        sessionMapLock.unlock()

        switch event.type {
        case .sessionStart:
            handleSessionStart(event: event)

        case .userInput:
            handleUserInput(event: event)

        case .assistantThinking:
            // 大多数 CLI 的 thinking 和 userInput 是同一个事件
            break

        case .waitingInput:
            handleWaitingInput(terminalId: terminalId)

        case .responseComplete:
            handleResponseComplete(terminalId: terminalId, event: event)

        case .sessionEnd:
            handleSessionEnd(terminalId: terminalId)

        case .permissionRequest:
            handlePermissionRequest(event: event)

        case .toolUse:
            handleToolUse(event: event)
        }
    }

    // MARK: - Event Handlers

    private func handleSessionStart(event: AICliEvent) {
        if let tabId = getTabId(for: event.terminalId) {
            AICliSessionMapper.shared.establish(
                terminalId: event.terminalId,
                sessionId: event.sessionId,
                tabId: tabId,
                providerId: event.source
            )
        }

        // 广播事件
        host?.emit(eventName: "aicli.sessionStart", payload: makePayload(event))

        // 通知等待者
        notifySessionWaiters(terminalId: event.terminalId, sessionId: event.sessionId)
    }

    private func handleUserInput(event: AICliEvent) {
        let terminalId = event.terminalId
        addState(.thinking, for: terminalId)

        // 设置临时标题
        let providerName = event.source.capitalized
        host?.setTabTitle(terminalId: terminalId, title: providerName)

        // 智能标题生成
        if let prompt = event.payload["prompt"] as? String, !prompt.isEmpty {
            Task { [weak self] in
                if let title = await AICliTitleGenerator.shared.generateTitle(from: prompt) {
                    await MainActor.run {
                        self?.host?.setTabTitle(terminalId: terminalId, title: title)
                    }
                }
            }
        }

        // 广播事件
        host?.emit(eventName: "aicli.promptSubmit", payload: makePayload(event))
    }

    private func handleWaitingInput(terminalId: Int) {
        if isTerminalActive(terminalId) {
            return
        }
        addState(.waitingInput, for: terminalId)

        // 广播事件
        host?.emit(eventName: "aicli.waitingInput", payload: [
            "terminalId": terminalId
        ])
    }

    private func handleResponseComplete(terminalId: Int, event: AICliEvent) {
        removeState(.thinking, for: terminalId)

        if isTerminalActive(terminalId) {
            decorationStates.removeValue(forKey: terminalId)
            host?.clearTabDecoration(terminalId: terminalId)
        } else {
            addState(.completed, for: terminalId)
        }

        // 广播事件
        host?.emit(eventName: "aicli.responseComplete", payload: makePayload(event))

        // 通知等待者
        notifyResponseWaiters(terminalId: terminalId)
    }

    private func handleSessionEnd(terminalId: Int) {
        decorationStates.removeValue(forKey: terminalId)
        host?.clearTabDecoration(terminalId: terminalId)
        host?.clearTabTitle(terminalId: terminalId)

        sessionMapLock.lock()
        sessionMap.removeValue(forKey: terminalId)
        sessionMapLock.unlock()

        if let tabId = getTabId(for: terminalId) {
            AICliSessionMapper.shared.end(terminalId: terminalId, tabId: tabId)
        }

        // 广播事件
        host?.emit(eventName: "aicli.sessionEnd", payload: [
            "terminalId": terminalId
        ])
    }

    private func handlePermissionRequest(event: AICliEvent) {
        let terminalId = event.terminalId

        // 权限请求 = 等待用户输入，设置黄色装饰（与 handleWaitingInput 相同逻辑）
        if !isTerminalActive(terminalId) {
            addState(.waitingInput, for: terminalId)
        }

        var payload = makePayload(event)
        payload["toolName"] = event.payload["toolName"] ?? ""
        payload["toolInput"] = event.payload["toolInput"] ?? [String: Any]()
        if let toolUseId = event.payload["toolUseId"] {
            payload["toolUseId"] = toolUseId
        }

        host?.emit(eventName: "aicli.permissionRequest", payload: payload)
    }

    private func handleToolUse(event: AICliEvent) {
        var payload = makePayload(event)
        payload["toolName"] = event.payload["toolName"] ?? ""
        payload["phase"] = event.payload["phase"] ?? ""
        if let toolUseId = event.payload["toolUseId"] {
            payload["toolUseId"] = toolUseId
        }
        if let toolInput = event.payload["toolInput"] {
            payload["toolInput"] = toolInput
        }

        host?.emit(eventName: "aicli.toolUse", payload: payload)
    }

    // MARK: - Plugin Event Handling

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

    private func handleTabActivate(terminalId: Int) {
        guard var states = decorationStates[terminalId], !states.isEmpty else {
            return
        }

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

    private func handleTerminalCreated(terminalId: Int, tabId: String) {
        guard hasCheckedForResume else { return }

        guard let sessionId = AICliSessionMapper.shared.getSessionIdForTab(tabId),
              let providerId = AICliSessionMapper.shared.getProviderIdForTab(tabId) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            guard let currentSessionId = AICliSessionMapper.shared.getSessionIdForTab(tabId),
                  currentSessionId == sessionId else { return }

            guard let currentTabId = self.getTabId(for: terminalId),
                  currentTabId == tabId else { return }

            guard let resumeCommand = self.getResumeCommand(providerId: providerId, sessionId: sessionId) else {
                return
            }
            self.host?.writeToTerminal(terminalId: terminalId, data: resumeCommand)
        }
    }

    private func handleTerminalClosed(terminalId: Int, tabId: String) {
        decorationStates.removeValue(forKey: terminalId)

        sessionMapLock.lock()
        sessionMap.removeValue(forKey: terminalId)
        sessionMapLock.unlock()

        AICliSessionMapper.shared.end(terminalId: terminalId, tabId: tabId)
    }

    // MARK: - Helpers

    private func makePayload(_ event: AICliEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "terminalId": event.terminalId,
            "sessionId": event.sessionId,
            "source": event.source,
            "transcriptPath": event.transcriptPath ?? "",
            "cwd": event.cwd ?? ""
        ]
        for (key, value) in event.payload {
            payload[key] = value
        }
        return payload
    }

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

        if host != nil {
            host?.setTabDecoration(terminalId: terminalId, decoration: decoration)
        } else {
            logWarn("[AICliSocket] host is nil! Cannot set decoration \(topState) for tid=\(terminalId)")
        }
    }

    private func isTerminalActive(_ terminalId: Int) -> Bool {
        host?.getActiveTerminalId() == terminalId
    }

    private func getTabId(for terminalId: Int) -> String? {
        host?.getTerminalInfo(terminalId: terminalId)?.tabId
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? { nil }
    public func bottomDockView(for id: String) -> AnyView? { nil }
    public func infoPanelView(for id: String) -> AnyView? { nil }
    public func bubbleView(for id: String) -> AnyView? { nil }
    public func menuBarView() -> AnyView? { nil }
    public func pageBarView(for itemId: String) -> AnyView? { nil }
    public func windowBottomOverlayView(for id: String) -> AnyView? { nil }
    public func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? { nil }

    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        guard slotId == "aicli-stats" else { return nil }

        let allTabs = page.slotTabs

        // 思考中：priority 101
        let thinkingCount = allTabs.filter { tab in
            guard let decoration = tab.decoration else { return false }
            if case .plugin(let id, let priority) = decoration.priority,
               id == Self.id, priority == 101 {
                return true
            }
            return false
        }.count

        // 等待输入：priority 102
        let waitingInputCount = allTabs.filter { tab in
            guard let decoration = tab.decoration else { return false }
            if case .plugin(let id, let priority) = decoration.priority,
               id == Self.id, priority == 102 {
                return true
            }
            return false
        }.count

        // 已完成：priority 5
        let completedCount = allTabs.filter { tab in
            guard let decoration = tab.decoration else { return false }
            if case .plugin(let id, let priority) = decoration.priority,
               id == Self.id, priority == 5 {
                return true
            }
            return false
        }.count

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

    // MARK: - Service Handlers

    private nonisolated func handleWaitForSession(params: [String: Any]) -> [String: Any]? {
        guard let terminalId = params["terminalId"] as? Int else {
            return ["success": false, "error": "Missing 'terminalId' parameter"]
        }

        let timeout = params["timeout"] as? Int ?? 30

        sessionMapLock.lock()
        let existingSessionId = sessionMap[terminalId]
        sessionMapLock.unlock()

        if let existingSessionId = existingSessionId {
            return [
                "success": true,
                "sessionId": existingSessionId,
                "terminalId": terminalId
            ]
        }

        let waiterId = UUID()
        let semaphore = DispatchSemaphore(value: 0)

        sessionWaiterLock.lock()
        sessionWaiters[waiterId] = Waiter(terminalId: terminalId, semaphore: semaphore, result: nil)
        sessionWaiterLock.unlock()

        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout))

        sessionWaiterLock.lock()
        let waiter = sessionWaiters.removeValue(forKey: waiterId)
        sessionWaiterLock.unlock()

        if waitResult == .timedOut {
            return ["success": false, "error": "Timeout waiting for session"]
        }

        return waiter?.result ?? ["success": false, "error": "Session not received"]
    }

    private nonisolated func notifySessionWaiters(terminalId: Int, sessionId: String) {
        sessionWaiterLock.lock()
        for (waiterId, var waiter) in sessionWaiters {
            if waiter.terminalId == terminalId {
                waiter.result = [
                    "success": true,
                    "sessionId": sessionId,
                    "terminalId": terminalId
                ]
                sessionWaiters[waiterId] = waiter
                waiter.semaphore.signal()
            }
        }
        sessionWaiterLock.unlock()
    }

    private nonisolated func handleWaitForResponse(params: [String: Any]) -> [String: Any]? {
        guard let terminalId = params["terminalId"] as? Int else {
            return ["success": false, "error": "Missing 'terminalId' parameter"]
        }

        let timeout = params["timeout"] as? Int ?? 300

        let waiterId = UUID()
        let semaphore = DispatchSemaphore(value: 0)

        responseWaiterLock.lock()
        responseWaiters[waiterId] = Waiter(terminalId: terminalId, semaphore: semaphore, result: nil)
        responseWaiterLock.unlock()

        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout))

        responseWaiterLock.lock()
        let waiter = responseWaiters.removeValue(forKey: waiterId)
        responseWaiterLock.unlock()

        if waitResult == .timedOut {
            return ["success": false, "error": "Timeout waiting for response"]
        }

        return waiter?.result ?? ["success": false, "error": "Response not received"]
    }

    private nonisolated func notifyResponseWaiters(terminalId: Int) {
        responseWaiterLock.lock()
        for (waiterId, var waiter) in responseWaiters {
            if waiter.terminalId == terminalId {
                waiter.result = [
                    "success": true,
                    "terminalId": terminalId
                ]
                responseWaiters[waiterId] = waiter
                waiter.semaphore.signal()
            }
        }
        responseWaiterLock.unlock()
    }
}
