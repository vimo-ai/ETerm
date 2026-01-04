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

    /// Session 映射：terminalId -> sessionId
    /// 从 claude.responseComplete 事件中收集
    private var sessionMap: [Int: String] = [:]

    /// 反向映射：sessionId -> terminalId
    private var reverseSessionMap: [String: Int] = [:]

    /// Session 文件路径映射：sessionId -> transcriptPath
    private var sessionPaths: [String: String] = [:]

    /// 待上报的创建请求：terminalId -> (requestId, projectPath)
    private var pendingRequests: [Int: (requestId: String, projectPath: String)] = [:]

    /// Mobile 正在查看的 terminal ID 集合
    private var mobileViewingTerminals: Set<Int> = []

    /// 正在 loading（Claude 思考中）的 session 集合
    private var loadingSessions: Set<String> = []

    /// 会话文件监听器
    private var sessionWatcher: SessionWatcher?

    /// 配置变更观察
    private var configObserver: NSObjectProtocol?

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

        // 如果配置有效，立即连接
        connectIfConfigured()

        print("[VlaudeKit] Plugin activated")
    }

    public func deactivate() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // 停止所有文件监听
        sessionWatcher?.stopAll()
        sessionWatcher = nil

        client?.disconnect()
        client = nil

        sessionMap.removeAll()
        reverseSessionMap.removeAll()
        sessionPaths.removeAll()
        pendingRequests.removeAll()
        mobileViewingTerminals.removeAll()
        loadingSessions.removeAll()

        print("[VlaudeKit] Plugin deactivated")
    }

    // MARK: - Configuration

    private func connectIfConfigured() {
        let config = VlaudeConfigManager.shared.config

        guard config.isValid else {
            print("[VlaudeKit] Config not valid, skipping connection")
            return
        }

        // 根据配置选择连接模式
        if config.useRedis {
            print("[VlaudeKit] Using Redis discovery mode")
            client?.connectWithRedis(config: config)
        } else {
            print("[VlaudeKit] Using direct connection mode")
            client?.connect(to: config.serverURL, deviceName: config.deviceName)
        }
    }

    private func handleConfigChange() {
        let config = VlaudeConfigManager.shared.config

        if config.isValid {
            // 根据配置选择连接模式
            if config.useRedis {
                client?.connectWithRedis(config: config)
            } else {
                client?.connect(to: config.serverURL, deviceName: config.deviceName)
            }
        } else {
            client?.disconnect()
        }
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

        case "core.terminal.didClose":
            handleTerminalClosed(payload)

        default:
            break
        }
    }

    private func handleClaudeSessionStart(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String,
              let transcriptPath = payload["transcriptPath"] as? String else {
            print("[VlaudeKit] ⚠️ handleClaudeSessionStart: 缺少必要字段")
            return
        }

        print("[VlaudeKit] 📥 收到 claude.sessionStart: terminalId=\(terminalId), sessionId=\(sessionId)")

        // 提前建立映射（不等 responseComplete）
        sessionMap[terminalId] = sessionId
        reverseSessionMap[sessionId] = terminalId
        sessionPaths[sessionId] = transcriptPath

        // 上报 session 可用
        let projectPath = payload["cwd"] as? String ?? ""
        client?.reportSessionAvailable(
            sessionId: sessionId,
            terminalId: terminalId,
            projectPath: projectPath.isEmpty ? nil : projectPath
        )

        // Redis 模式：添加活跃 Session
        client?.addActiveSession(sessionId: sessionId, projectPath: projectPath)

        // 开始监听文件变化
        sessionWatcher?.startWatching(sessionId: sessionId, transcriptPath: transcriptPath)

        // 发送 projectUpdate 事件
        if !projectPath.isEmpty {
            client?.reportProjectUpdate(projectPath: projectPath)
        }
    }

    private func handleClaudePromptSubmit(_ payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String else { return }
        // 标记为 loading
        loadingSessions.insert(sessionId)
    }

    private func handleClaudeResponseComplete(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else {
            print("[VlaudeKit] ⚠️ handleClaudeResponseComplete: 缺少 terminalId 或 sessionId")
            return
        }

        print("[VlaudeKit] 📥 收到 claude.responseComplete: terminalId=\(terminalId), sessionId=\(sessionId)")

        // 清除 loading 状态
        loadingSessions.remove(sessionId)

        // 检查是否已经在 sessionStart 中处理过
        let oldSessionId = sessionMap[terminalId]
        let isNewSession = oldSessionId == nil
        let isSessionChanged = oldSessionId != nil && oldSessionId != sessionId

        // 如果该终端之前有不同的 sessionId，先清理旧的映射并上报不可用
        if isSessionChanged, let oldId = oldSessionId {
            reverseSessionMap.removeValue(forKey: oldId)
            sessionPaths.removeValue(forKey: oldId)
            sessionWatcher?.stopWatching(sessionId: oldId)
            client?.reportSessionUnavailable(sessionId: oldId)
        }

        // 更新映射（如果 sessionStart 没有处理过）
        if isNewSession || isSessionChanged {
            sessionMap[terminalId] = sessionId
            reverseSessionMap[sessionId] = terminalId

            let projectPath = payload["cwd"] as? String
            client?.reportSessionAvailable(
                sessionId: sessionId,
                terminalId: terminalId,
                projectPath: projectPath
            )

            // 发送 projectUpdate 事件
            if let projectPath = projectPath {
                client?.reportProjectUpdate(projectPath: projectPath)
            }
        }

        // 更新 transcriptPath 并确保文件监听已启动
        if let transcriptPath = payload["transcriptPath"] as? String {
            sessionPaths[sessionId] = transcriptPath

            // 如果还没有在监听，启动监听
            if !(sessionWatcher?.isWatching(sessionId: sessionId) ?? false) {
                sessionWatcher?.startWatching(sessionId: sessionId, transcriptPath: transcriptPath)
            }
        }

        // 检查是否有待上报的 requestId（新方式）
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
            print("[VlaudeKit] 📤 索引会话: transcriptPath=\(transcriptPath)")
            client?.indexSession(path: transcriptPath)
        }
    }

    private func handleClaudeSessionEnd(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else {
            return
        }

        // 防御：检查当前映射是否匹配，避免乱序事件清错映射
        guard sessionMap[terminalId] == sessionId else {
            print("[VlaudeKit] ⚠️ sessionEnd 跳过: 映射已变更")
            return
        }

        // 停止文件监听
        sessionWatcher?.stopWatching(sessionId: sessionId)

        // 清理映射
        sessionMap.removeValue(forKey: terminalId)
        reverseSessionMap.removeValue(forKey: sessionId)
        sessionPaths.removeValue(forKey: sessionId)
        pendingRequests.removeValue(forKey: terminalId)

        // 上报 session 不可用
        client?.reportSessionUnavailable(sessionId: sessionId)

        // Redis 模式：移除活跃 Session
        client?.removeActiveSession(sessionId: sessionId)
    }

    private func handleTerminalClosed(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int else {
            return
        }

        // 无论是否有 sessionId，都要清理 terminalId 相关的状态
        pendingRequests.removeValue(forKey: terminalId)
        mobileViewingTerminals.remove(terminalId)

        // 获取 sessionId 并清理映射
        guard let sessionId = sessionMap.removeValue(forKey: terminalId) else {
            return
        }

        // 停止文件监听
        sessionWatcher?.stopWatching(sessionId: sessionId)

        reverseSessionMap.removeValue(forKey: sessionId)
        sessionPaths.removeValue(forKey: sessionId)

        // 上报 session 不可用
        client?.reportSessionUnavailable(sessionId: sessionId)

        // Redis 模式：移除活跃 Session
        client?.removeActiveSession(sessionId: sessionId)
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令
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
        // 连接成功后，上报所有已存在的 session
        for (terminalId, sessionId) in sessionMap {
            // 获取项目路径
            let projectPath = host?.getTerminalInfo(terminalId: terminalId)?.cwd
            client.reportSessionAvailable(
                sessionId: sessionId,
                terminalId: terminalId,
                projectPath: projectPath
            )
        }

        print("[VlaudeKit] Connected, reported \(sessionMap.count) sessions")
    }

    func vlaudeClientDidDisconnect(_ client: VlaudeClient) {
        print("[VlaudeKit] Disconnected")
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveInject sessionId: String, text: String) {
        guard let terminalId = reverseSessionMap[sessionId] else {
            print("[VlaudeKit] Session not found: \(sessionId)")
            return
        }

        // 写入终端
        host?.writeToTerminal(terminalId: terminalId, data: text)

        // 延迟发送回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
        }

        print("[VlaudeKit] Injected to terminal \(terminalId)")
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveMobileViewing sessionId: String, isViewing: Bool) {
        guard let terminalId = reverseSessionMap[sessionId] else {
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
        // 旧方式：不支持，仅记录日志
        print("[VlaudeKit] Old createSession request (deprecated): projectPath=\(projectPath)")
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

        print("[VlaudeKit] Created terminal \(terminalId) for requestId: \(requestId)")

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
        guard let terminalId = reverseSessionMap[sessionId] else {
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

        print("[VlaudeKit] Sent message to session \(sessionId) via terminal \(terminalId)")
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveCheckLoading sessionId: String, projectPath: String?, requestId: String) {
        let isLoading = loadingSessions.contains(sessionId)
        client.emitCheckLoadingResult(requestId: requestId, loading: isLoading)
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
            // 从 JSONL 文件解析结构化内容块
            let blocks = ContentBlockParser.readMessage(from: transcriptPath, uuid: message.uuid)
            client?.pushMessage(sessionId: sessionId, message: message, contentBlocks: blocks)
        }

        print("[VlaudeKit] SessionWatcher 推送 \(messages.count) 条新消息: \(sessionId)")
    }
}
