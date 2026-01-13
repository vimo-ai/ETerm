//
//  VlaudePlugin.swift
//  VlaudeKit
//
//  Vlaude 远程控制插件 (SDK 版本)
//
//  职责：
//  - 直连 vlaude-server，上报 session 状态
//  - 接收注入请求，转发给终端
//  - 处理远程创建 Claude 会话请求
//  - Tab Slot 显示手机图标
//  - 实时监听会话文件变化，推送增量消息
//

import Foundation
import AppKit
import SwiftUI
import ETermKit

@objc(VlaudePlugin)
public final class VlaudePlugin: NSObject, Plugin {
    public static var id = "com.eterm.vlaude"

    private weak var host: HostBridge?
    private var client: VlaudeClient?

    /// Session 文件路径映射：sessionId -> transcriptPath
    /// 注意：session ↔ terminal 映射由 ClaudeKit 的 ClaudeSessionMapper 维护
    private var sessionPaths: [String: String] = [:]

    /// 待上报的创建请求：terminalId -> (requestId, projectPath)
    private var pendingRequests: [Int: (requestId: String, projectPath: String)] = [:]

    /// Mobile 正在查看的 terminal ID 集合
    private var mobileViewingTerminals: Set<Int> = []

    /// 正在 loading（Claude 思考中）的 session 集合
    private var loadingSessions: Set<String> = []

    /// 待处理的 clientMessageId：sessionId -> clientMessageId
    /// 当收到 iOS 发送的消息注入请求时存储，推送 user 消息时携带并清除
    private var pendingClientMessageIds: [String: String] = [:]

    /// 会话文件监听器
    private var sessionWatcher: SessionWatcher?

    /// 配置变更观察
    private var configObserver: NSObjectProtocol?

    /// 重连请求观察
    private var reconnectObserver: NSObjectProtocol?

    public override required init() {
        super.init()
    }

    // MARK: - Plugin Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 初始化客户端（使用 Rust FFI）
        client = VlaudeClient()
        client?.delegate = self

        // 初始化会话文件监听器
        sessionWatcher = SessionWatcher()
        sessionWatcher?.delegate = self

        // 监听配置变更
        configObserver = NotificationCenter.default.addObserver(
            forName: .vlaudeConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigChange()
            }
        }

        // 监听重连请求
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .vlaudeReconnectRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleReconnectRequest()
            }
        }

        // 如果配置有效，立即连接
        connectIfConfigured()
    }

    public func deactivate() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = reconnectObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // 停止所有文件监听
        sessionWatcher?.stopAll()
        sessionWatcher = nil

        client?.disconnect()
        client = nil

        // 更新状态
        VlaudeConfigManager.shared.updateConnectionStatus(.disconnected)

        // 映射由 ClaudeKit 维护，这里只清理 VlaudeKit 本地状态
        // sessionPaths 保留，重连后还能用
        pendingRequests.removeAll()
        mobileViewingTerminals.removeAll()
        loadingSessions.removeAll()
        pendingClientMessageIds.removeAll()
    }

    // MARK: - Configuration

    private func connectIfConfigured() {
        let config = VlaudeConfigManager.shared.config
        guard config.isValid else { return }
        VlaudeConfigManager.shared.updateConnectionStatus(.connecting)
        client?.connect(config: config)
    }

    private func handleConfigChange() {
        let config = VlaudeConfigManager.shared.config

        if config.isValid {
            VlaudeConfigManager.shared.updateConnectionStatus(.connecting)
            client?.connect(config: config)
        } else {
            client?.disconnect()
            VlaudeConfigManager.shared.updateConnectionStatus(.disconnected)
        }
    }

    private func handleReconnectRequest() {
        let config = VlaudeConfigManager.shared.config
        guard config.isValid else { return }
        VlaudeConfigManager.shared.updateConnectionStatus(.reconnecting)
        client?.reconnect()
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "claude.sessionStart":
            handleClaudeSessionStart(payload)

        case "claude.promptSubmit":
            handleClaudePromptSubmit(payload)

        case "claude.responseComplete":
            handleClaudeResponseComplete(payload)

        case "claude.sessionEnd":
            handleClaudeSessionEnd(payload)

        case "claude.permissionPrompt":
            handleClaudePermissionPrompt(payload)

        case "terminal.didClose":
            handleTerminalClosed(payload)

        default:
            break
        }
    }

    private func handleClaudeSessionStart(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String,
              let transcriptPath = payload["transcriptPath"] as? String else { return }

        // 映射由 ClaudeKit 的 ClaudeSessionMapper 维护，这里只保存 transcriptPath
        sessionPaths[sessionId] = transcriptPath

        // 发送 daemon:sessionStart 事件（更新 StatusManager，iOS 显示在线状态）
        let projectPath = payload["cwd"] as? String ?? ""
        client?.emitSessionStart(sessionId: sessionId, projectPath: projectPath, terminalId: terminalId)

        // 开始监听文件变化
        sessionWatcher?.startWatching(sessionId: sessionId, transcriptPath: transcriptPath)
    }

    private func handleClaudePromptSubmit(_ payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String else { return }
        // 标记为 loading
        loadingSessions.insert(sessionId)
    }

    private func handleClaudeResponseComplete(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else { return }

        // 清除 loading 状态
        loadingSessions.remove(sessionId)

        // 检查是否有旧的 sessionPaths 需要清理（session 改变的情况）
        // 先收集要清理的 sessionId，避免迭代时修改字典
        let sessionsToClean = sessionPaths.keys.filter { oldSessionId in
            oldSessionId != sessionId &&
            getTerminalId(for: oldSessionId) == terminalId
        }
        for oldSessionId in sessionsToClean {
            sessionPaths.removeValue(forKey: oldSessionId)
            sessionWatcher?.stopWatching(sessionId: oldSessionId)
            client?.emitSessionEnd(sessionId: oldSessionId)
        }

        // 更新 transcriptPath 并确保文件监听已启动
        if let transcriptPath = payload["transcriptPath"] as? String {
            let isNewSession = sessionPaths[sessionId] == nil
            sessionPaths[sessionId] = transcriptPath

            // 如果是新 session，发送 daemon:sessionStart 事件
            if isNewSession {
                let projectPath = payload["cwd"] as? String ?? ""
                client?.emitSessionStart(sessionId: sessionId, projectPath: projectPath, terminalId: terminalId)
            }

            // 如果还没有在监听，启动监听
            let alreadyWatching = sessionWatcher?.isWatching(sessionId: sessionId) ?? false
            if !alreadyWatching {
                sessionWatcher?.startWatching(sessionId: sessionId, transcriptPath: transcriptPath)
            }
        }

        // 检查是否有待上报的 requestId
        if let pending = pendingRequests.removeValue(forKey: terminalId) {
            let encodedDirName = payload["encodedDirName"] as? String
            let transcriptPath = payload["transcriptPath"] as? String

            client?.emitSessionCreatedResult(
                requestId: pending.requestId,
                success: true,
                sessionId: sessionId,
                encodedDirName: encodedDirName,
                transcriptPath: transcriptPath
            )
        }

        // 索引会话到 SharedDb（推送由 SessionWatcher 处理）
        if let transcriptPath = payload["transcriptPath"] as? String {
            client?.indexSession(path: transcriptPath)
        }
    }

    private func handleClaudeSessionEnd(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else { return }

        // 注意：ClaudeKit 先清理映射再 emit 事件，所以这里不能依赖 getSessionId()
        // 直接使用 payload 中的 sessionId 进行清理

        // 停止文件监听
        sessionWatcher?.stopWatching(sessionId: sessionId)

        // 清理本地数据（映射由 ClaudeKit 维护）
        sessionPaths.removeValue(forKey: sessionId)
        pendingRequests.removeValue(forKey: terminalId)

        // 发送 daemon:sessionEnd 事件（通知 StatusManager session 结束）
        client?.emitSessionEnd(sessionId: sessionId)
    }

    private func handleTerminalClosed(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int else {
            return
        }

        // 无论是否有 sessionId，都要清理 terminalId 相关的状态
        pendingRequests.removeValue(forKey: terminalId)
        mobileViewingTerminals.remove(terminalId)

        // 注意：ClaudeKit 可能已经清理了映射，所以不能依赖 getSessionId()
        // 从本地 sessionPaths 中查找属于这个 terminal 的 session
        // 需要遍历 sessionPaths，通过 getTerminalId 找到匹配的 session
        // 但 getTerminalId 也依赖 ClaudeKit 映射，所以这里需要用 payload 中的 sessionId（如果有）
        // 或者从 sessionPaths 中根据已知信息清理

        // 尝试从 payload 获取 sessionId
        if let sessionId = payload["sessionId"] as? String {
            sessionWatcher?.stopWatching(sessionId: sessionId)
            sessionPaths.removeValue(forKey: sessionId)
            client?.emitSessionEnd(sessionId: sessionId)
        } else {
            // payload 中没有 sessionId，尝试从 sessionPaths 中查找
            // 这种情况下映射可能还存在
            if let sessionId = getSessionId(for: terminalId) {
                sessionWatcher?.stopWatching(sessionId: sessionId)
                sessionPaths.removeValue(forKey: sessionId)
                client?.emitSessionEnd(sessionId: sessionId)
            }
        }
    }

    private func handleClaudePermissionPrompt(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String,
              let toolName = payload["toolName"] as? String,
              let toolInput = payload["toolInput"] as? [String: Any] else {
            return
        }

        // 从 PermissionRequest hook 直接获取完整的工具信息
        // 不需要从 JSONL 读取或缓存，无时序问题
        var toolUseInfo: [String: Any] = [
            "name": toolName,
            "input": toolInput
        ]

        // 可选字段
        if let toolUseId = payload["toolUseId"] as? String {
            toolUseInfo["id"] = toolUseId
        }

        // 推送权限请求给 iOS
        client?.emitPermissionRequest(
            sessionId: sessionId,
            terminalId: terminalId,
            message: payload["message"] as? String,  // 可选
            toolUse: toolUseInfo
        )
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令
    }

    // MARK: - ClaudeKit 服务调用

    /// 通过 ClaudeKit 服务查询 sessionId -> terminalId 映射
    private func getTerminalId(for sessionId: String) -> Int? {
        guard let host = host else { return nil }
        guard let result = host.callService(
            pluginId: "com.eterm.claude",
            name: "getTerminalId",
            params: ["sessionId": sessionId]
        ) else { return nil }
        return result["terminalId"] as? Int
    }

    /// 通过 ClaudeKit 服务查询 terminalId -> sessionId 映射
    private func getSessionId(for terminalId: Int) -> String? {
        guard let host = host else { return nil }
        guard let result = host.callService(
            pluginId: "com.eterm.claude",
            name: "getSessionId",
            params: ["terminalId": terminalId]
        ) else { return nil }
        return result["sessionId"] as? String
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        guard tabId == "vlaude-settings" else { return nil }
        return AnyView(VlaudeSettingsView())
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
        guard slotId == "vlaude-mobile-viewing" else { return nil }
        guard let terminalId = tab.terminalId else { return nil }
        guard mobileViewingTerminals.contains(terminalId) else { return nil }

        return AnyView(
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .help("Mobile 正在查看")
        )
    }

    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        nil
    }
}

// MARK: - VlaudeClientDelegate

extension VlaudePlugin: VlaudeClientDelegate {
    func vlaudeClientDidConnect(_ client: VlaudeClient) {
        // 更新连接状态
        VlaudeConfigManager.shared.updateConnectionStatus(.connected)

        // 连接成功后，上报所有已存在的 session（StatusManager 架构）
        // 遍历 sessionPaths，通过 ClaudeKit 服务查询 terminalId
        var reportedCount = 0
        for sessionId in sessionPaths.keys {
            guard let terminalId = getTerminalId(for: sessionId) else { continue }
            let projectPath = host?.getTerminalInfo(terminalId: terminalId)?.cwd ?? ""
            client.emitSessionStart(sessionId: sessionId, projectPath: projectPath, terminalId: terminalId)
            reportedCount += 1
        }

    }

    func vlaudeClientDidDisconnect(_ client: VlaudeClient) {
        // 如果正在重连中，不要覆盖状态（避免 .reconnecting -> .disconnected 闪烁）
        let currentStatus = VlaudeConfigManager.shared.connectionStatus
        if currentStatus != .reconnecting {
            VlaudeConfigManager.shared.updateConnectionStatus(.disconnected)
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveInject sessionId: String, text: String, clientMessageId: String?) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            return
        }

        // 存储 clientMessageId，等待 SessionWatcher 检测到 user 消息后一起推送
        if let clientMsgId = clientMessageId {
            pendingClientMessageIds[sessionId] = clientMsgId
        }

        // 写入终端
        host?.writeToTerminal(terminalId: terminalId, data: text)

        // 延迟发送回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveMobileViewing sessionId: String, isViewing: Bool) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            return
        }

        // 更新状态
        if isViewing {
            mobileViewingTerminals.insert(terminalId)
        } else {
            mobileViewingTerminals.remove(terminalId)
        }

        // 触发 UI 刷新
        // SDK 插件通过 updateViewModel 触发刷新
        host?.updateViewModel(Self.id, data: ["mobileViewingChanged": true])
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?) {
        // 旧方式：不支持
    }

    // MARK: - 新 WebSocket 事件处理

    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSessionNew projectPath: String, prompt: String?, requestId: String) {
        guard let host = host else {
            client.emitSessionCreatedResult(requestId: requestId, success: false, error: "Host not available")
            return
        }

        // 1. 创建终端 Tab
        guard let terminalId = host.createTerminalTab(cwd: projectPath) else {
            client.emitSessionCreatedResult(requestId: requestId, success: false, error: "Failed to create terminal")
            return
        }

        // 2. 保存 pending 请求，等待 claude.responseComplete 事件
        pendingRequests[terminalId] = (requestId: requestId, projectPath: projectPath)

        // 3. 启动 Claude（延迟等待终端准备好）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            let command: String
            if let prompt = prompt, !prompt.isEmpty {
                // 转义 prompt 中的特殊字符
                let escapedPrompt = prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                command = "claude -p \"\(escapedPrompt)\""
            } else {
                command = "claude"
            }

            self.host?.writeToTerminal(terminalId: terminalId, data: command + "\n")
        }

        // 4. 设置超时（60秒），如果 session 没有创建则报告失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self else { return }

            // 如果还在 pending 中，说明超时了
            if self.pendingRequests[terminalId] != nil {
                self.pendingRequests.removeValue(forKey: terminalId)
                client.emitSessionCreatedResult(requestId: requestId, success: false, error: "Timeout waiting for session")
            }
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveSendMessage sessionId: String, text: String, projectPath: String?, clientId: String?, requestId: String) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            client.emitSendMessageResult(requestId: requestId, success: false, message: "Session not in ETerm")
            return
        }

        // 写入终端
        host?.writeToTerminal(terminalId: terminalId, data: text)

        // 延迟发送回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
            client.emitSendMessageResult(requestId: requestId, success: true, via: "eterm")
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveCheckLoading sessionId: String, projectPath: String?, requestId: String) {
        let isLoading = loadingSessions.contains(sessionId)
        client.emitCheckLoadingResult(requestId: requestId, loading: isLoading)
    }

    func vlaudeClient(_ client: VlaudeClient, didReceivePermissionResponse sessionId: String, action: String, toolUseId: String) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            // 即使找不到终端，也发送失败的 ack
            if !toolUseId.isEmpty {
                client.emitApprovalAck(toolUseId: toolUseId, sessionId: sessionId, success: false, message: "终端未找到")
            }
            return
        }

        // 写入终端（action 可以是 y/n/a 或 "n: 理由"）
        host?.writeToTerminal(terminalId: terminalId, data: action)

        // 延迟发送回车，然后发送 ack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")

            // 发送 approval-ack 通知 iOS
            if !toolUseId.isEmpty {
                client.emitApprovalAck(toolUseId: toolUseId, sessionId: sessionId, success: true)
            }
        }
    }
}

// MARK: - SessionWatcherDelegate

extension VlaudePlugin: SessionWatcherDelegate {
    func sessionWatcher(
        _ watcher: SessionWatcher,
        didReceiveMessages messages: [RawMessage],
        for sessionId: String,
        transcriptPath: String
    ) {
        // 推送新消息给服务器（带结构化内容块）
        for message in messages {
            let blocks = ContentBlockParser.readMessage(from: transcriptPath, uuid: message.uuid)

            // 对于 user 类型消息，携带 clientMessageId（如果有）
            var clientMsgId: String? = nil
            if message.type == "user" {
                // 取出并消费 clientMessageId（一次性使用）
                clientMsgId = pendingClientMessageIds.removeValue(forKey: sessionId)
            }

            client?.pushMessage(sessionId: sessionId, message: message, contentBlocks: blocks, clientMessageId: clientMsgId)
        }
    }
}
