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

    /// 待上报的创建请求：terminalId -> (requestId, projectPath)
    private var pendingRequests: [Int: (requestId: String, projectPath: String)] = [:]

    /// Mobile 正在查看的 terminal ID 集合
    private var mobileViewingTerminals: Set<Int> = []

    /// 配置变更观察
    private var configObserver: NSObjectProtocol?

    public override required init() {
        super.init()
    }

    // MARK: - Plugin Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 存储 SocketService 引用（供 VlaudeSettingsView 使用）
        VlaudeConfigManager.shared.socketService = host.socketService

        // 初始化客户端（通过 HostBridge 获取 SocketService）
        client = VlaudeClient(socketService: host.socketService)
        client?.delegate = self

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

        client?.disconnect()
        client = nil

        sessionMap.removeAll()
        reverseSessionMap.removeAll()
        pendingRequests.removeAll()
        mobileViewingTerminals.removeAll()

        print("[VlaudeKit] Plugin deactivated")
    }

    // MARK: - Configuration

    private func connectIfConfigured() {
        let config = VlaudeConfigManager.shared.config

        guard config.isValid else {
            print("[VlaudeKit] Config not valid, skipping connection")
            return
        }

        client?.connect(to: config.serverURL, deviceName: config.deviceName)
    }

    private func handleConfigChange() {
        let config = VlaudeConfigManager.shared.config

        if config.isValid {
            client?.connect(to: config.serverURL, deviceName: config.deviceName)
        } else {
            client?.disconnect()
        }
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
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

    private func handleClaudeResponseComplete(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else {
            return
        }

        // 检查是否是新 session 或 session 变更
        let oldSessionId = sessionMap[terminalId]
        let isNewSession = oldSessionId == nil
        let isSessionChanged = oldSessionId != nil && oldSessionId != sessionId

        // 如果该终端之前有不同的 sessionId，先清理旧的映射并上报不可用
        if isSessionChanged, let oldId = oldSessionId {
            reverseSessionMap.removeValue(forKey: oldId)
            client?.reportSessionUnavailable(sessionId: oldId)
        }

        // 更新映射
        sessionMap[terminalId] = sessionId
        reverseSessionMap[sessionId] = terminalId

        // 只在新 session 或 session 变更时上报可用（避免重复上报）
        if isNewSession || isSessionChanged {
            let projectPath = payload["cwd"] as? String
            client?.reportSessionAvailable(
                sessionId: sessionId,
                terminalId: terminalId,
                projectPath: projectPath
            )
        }

        // 检查是否有待上报的 requestId
        if let pending = pendingRequests.removeValue(forKey: terminalId) {
            client?.reportSessionCreated(
                requestId: pending.requestId,
                sessionId: sessionId,
                projectPath: pending.projectPath
            )
        }
    }

    private func handleClaudeSessionEnd(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else {
            return
        }

        // 清理映射
        sessionMap.removeValue(forKey: terminalId)
        reverseSessionMap.removeValue(forKey: sessionId)
        pendingRequests.removeValue(forKey: terminalId)

        // 上报 session 不可用
        client?.reportSessionUnavailable(sessionId: sessionId)
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

        reverseSessionMap.removeValue(forKey: sessionId)

        // 上报 session 不可用
        client?.reportSessionUnavailable(sessionId: sessionId)
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
        // TODO: 需要 HostBridge 提供创建终端的 API
        // 目前 SDK 插件没有直接创建终端的能力
        // 可能需要通过服务调用或者扩展 HostBridge

        print("[VlaudeKit] Create session request: projectPath=\(projectPath), requestId=\(requestId ?? "N/A")")
        print("[VlaudeKit] WARNING: Create session not implemented yet - need HostBridge API")

        // 临时方案：保存 requestId，等待用户手动创建终端
        // 如果有 requestId，需要跟踪并在 session 创建后上报
        // 但由于我们无法创建终端，这里只能记录日志
    }
}
