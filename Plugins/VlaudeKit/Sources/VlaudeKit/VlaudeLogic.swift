//
//  VlaudeLogic.swift
//  VlaudeKit
//
//  Vlaude 远程控制插件逻辑 - 在 Extension Host 进程中运行
//
//  职责：
//  - 连接 daemon，上报 session 状态
//  - 接收注入请求，转发给终端
//  - 处理远程创建 Claude 会话请求
//  - 跟踪 requestId，在会话创建完成后上报
//
//  SDK 版本设计：
//  - 通过 service.call 调用 ClaudeKit 服务获取 session 映射
//  - 通过 terminal.write 能力写入终端
//  - 通过 ui.tabDecoration 显示手机图标

import Foundation
import ETermKit

/// Vlaude 远程控制插件逻辑入口
///
/// 线程安全说明：
/// - 使用串行队列 `stateQueue` 保护所有可变状态访问
/// - `host` 引用的 `HostBridge` 本身是 `Sendable` 且内部线程安全
@objc(VlaudeLogic)
public final class VlaudeLogic: NSObject, PluginLogic, @unchecked Sendable {

    public static var id: String { "com.eterm.vlaude" }

    /// 串行队列，保护可变状态访问
    private let stateQueue = DispatchQueue(label: "com.eterm.vlaude.state")

    /// 受保护的可变状态
    private var _host: HostBridge?
    private var _daemonClient: VlaudeDaemonClient?

    /// 待上报的 requestId 映射：terminalId -> (requestId, projectPath)
    /// 当收到创建请求时保存，当 Claude 启动后（ResponseComplete）检测并上报
    private var _pendingRequests: [Int: (requestId: String, projectPath: String)] = [:]

    /// Mobile 正在查看的 terminal ID 集合
    private var _mobileViewingTerminals: Set<Int> = []

    /// 线程安全的 host 访问
    private var host: HostBridge? {
        get { stateQueue.sync { _host } }
        set { stateQueue.sync { _host = newValue } }
    }

    /// 线程安全的 daemonClient 访问
    private var daemonClient: VlaudeDaemonClient? {
        get { stateQueue.sync { _daemonClient } }
        set { stateQueue.sync { _daemonClient = newValue } }
    }

    public required override init() {
        super.init()
        print("[VlaudeLogic] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[VlaudeLogic] Activated")

        // 创建并连接 daemon client
        let client = VlaudeDaemonClient()
        client.delegate = self
        self.daemonClient = client
        client.connect()
    }

    public func deactivate() {
        print("[VlaudeLogic] Deactivating...")

        stateQueue.sync {
            _pendingRequests.removeAll()
            _mobileViewingTerminals.removeAll()
        }

        daemonClient?.disconnect()
        daemonClient = nil
        host = nil
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        print("[VlaudeLogic] Event: \(eventName)")

        switch eventName {
        case "plugin.claude.responseComplete":
            handleClaudeResponseComplete(payload)

        case "core.terminal.didExit":
            handleTerminalClosed(payload)

        case "plugin.claude.sessionEnd":
            handleClaudeSessionEnd(payload)

        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        print("[VlaudeLogic] Command: \(commandId)")
    }

    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        print("[VlaudeLogic] Request: \(requestId) params: \(params)")

        switch requestId {
        case "getMobileViewingTerminals":
            let terminals = stateQueue.sync { Array(_mobileViewingTerminals) }
            return ["success": true, "terminals": terminals]

        default:
            return ["success": false, "error": "Unknown request: \(requestId)"]
        }
    }

    // MARK: - Claude Response Complete

    private func handleClaudeResponseComplete(_ payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String,
              let terminalId = payload["terminalId"] as? Int else {
            return
        }

        // 上报 session 可用
        daemonClient?.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)

        // 检查是否有待上报的 requestId
        let pending = stateQueue.sync { _pendingRequests.removeValue(forKey: terminalId) }
        if let pending = pending {
            daemonClient?.reportSessionCreated(
                requestId: pending.requestId,
                sessionId: sessionId,
                projectPath: pending.projectPath
            )
        }
    }

    // MARK: - Terminal Closed

    private func handleTerminalClosed(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int else {
            return
        }

        // 清理待上报的 requestId
        _ = stateQueue.sync {
            _pendingRequests.removeValue(forKey: terminalId)
        }

        // 通过 service.call 获取 session 映射
        guard let result = host?.callService(
            pluginId: "com.eterm.claude",
            name: "getSessionId",
            params: ["terminalId": terminalId]
        ),
              let sessionId = result["sessionId"] as? String else {
            return
        }

        // 通知 daemon
        daemonClient?.reportSessionUnavailable(sessionId: sessionId)
    }

    // MARK: - Claude Session End

    private func handleClaudeSessionEnd(_ payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String,
              let terminalId = payload["terminalId"] as? Int else {
            return
        }

        // 清理待上报的 requestId
        _ = stateQueue.sync {
            _pendingRequests.removeValue(forKey: terminalId)
        }

        // 通知 daemon
        daemonClient?.reportSessionUnavailable(sessionId: sessionId)
    }

    // MARK: - Create Claude Session

    /// 创建 Claude 会话（供 daemon 调用）
    private func createClaudeSession(projectPath: String, prompt: String?, requestId: String?) {
        // 构建 claude 命令
        var command = "claude"
        if let prompt = prompt, !prompt.isEmpty {
            // 转义单引号
            let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
            command += " -p '\(escapedPrompt)'"
        }
        command += "\r"  // 回车执行

        // 通过 service.call 请求主进程创建终端
        guard let result = host?.callService(
            pluginId: "com.eterm.core",
            name: "createTerminal",
            params: [
                "cwd": projectPath,
                "command": command
            ]
        ),
              let success = result["success"] as? Bool,
              success,
              let terminalId = result["terminalId"] as? Int else {
            print("[VlaudeLogic] Failed to create terminal")
            return
        }

        // 如果有 requestId，保存到待上报映射
        if let reqId = requestId {
            stateQueue.sync {
                _pendingRequests[terminalId] = (reqId, projectPath)
            }
        }
    }

    // MARK: - UI Update

    private func updateMobileViewingUI() {
        let terminals = stateQueue.sync { Array(_mobileViewingTerminals) }

        // 更新 ViewModel，主进程会根据数据更新 Tab 装饰
        host?.updateViewModel(Self.id, data: [
            "mobileViewingTerminals": terminals
        ])
    }
}

// MARK: - VlaudeDaemonClientDelegate

extension VlaudeLogic: VlaudeDaemonClientDelegate {
    func daemonClientDidConnect(_ client: VlaudeDaemonClient) {
        print("[VlaudeLogic] Daemon connected")

        // 连接成功后，获取所有已存在的 session 映射
        guard let result = host?.callService(
            pluginId: "com.eterm.claude",
            name: "getAllMappings",
            params: [:]
        ),
              let mappings = result["mappings"] as? [[String: Any]] else {
            return
        }

        for mapping in mappings {
            if let sessionId = mapping["sessionId"] as? String,
               let terminalId = mapping["terminalId"] as? Int {
                client.reportSessionAvailable(sessionId: sessionId, terminalId: terminalId)
            }
        }
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveInject sessionId: String, terminalId: Int, text: String) {
        print("[VlaudeLogic] Inject: sessionId=\(sessionId), terminalId=\(terminalId)")

        // 写入终端
        host?.writeToTerminal(terminalId: terminalId, data: text)

        // 延迟发送回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
        }
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveMobileViewing sessionId: String, isViewing: Bool) {
        // 通过 service.call 获取 terminal ID
        guard let result = host?.callService(
            pluginId: "com.eterm.claude",
            name: "getTerminalId",
            params: ["sessionId": sessionId]
        ),
              let terminalId = result["terminalId"] as? Int else {
            return
        }

        // 更新 mobile 查看状态
        stateQueue.sync {
            if isViewing {
                _mobileViewingTerminals.insert(terminalId)
            } else {
                _mobileViewingTerminals.remove(terminalId)
            }
        }

        // 更新 Tab 装饰
        if isViewing {
            host?.setTabDecoration(terminalId: terminalId, decoration: TabDecoration(
                icon: "iphone"
            ))
        } else {
            host?.clearTabDecoration(terminalId: terminalId)
        }
    }

    func daemonClient(_ client: VlaudeDaemonClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?) {
        print("[VlaudeLogic] Create session: path=\(projectPath)")
        createClaudeSession(projectPath: projectPath, prompt: prompt, requestId: requestId)
    }
}
