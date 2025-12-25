// OneLineCommandLogic.swift
// OneLineCommandKit
//
// 一行命令插件逻辑 - 在 Extension Host 进程中运行

import Foundation
import ETermKit

/// 一行命令插件逻辑入口
///
/// 线程安全说明：
/// - 使用串行队列 `stateQueue` 保护所有可变状态访问
/// - `host` 引用的 `HostBridge` 本身是 `Sendable` 且内部线程安全
@objc(OneLineCommandLogic)
public final class OneLineCommandLogic: NSObject, PluginLogic, @unchecked Sendable {

    public static var id: String { "com.eterm.one-line-command" }

    /// 串行队列，保护可变状态访问
    private let stateQueue = DispatchQueue(label: "com.eterm.one-line-command.state")

    /// 受保护的可变状态
    private var _host: HostBridge?

    /// 线程安全的 host 访问
    private var host: HostBridge? {
        get { stateQueue.sync { _host } }
        set { stateQueue.sync { _host = newValue } }
    }

    public required override init() {
        super.init()
        print("[OneLineCommandLogic] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[OneLineCommandLogic] Activated")
    }

    public func deactivate() {
        print("[OneLineCommandLogic] Deactivating...")
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        print("[OneLineCommandLogic] Event: \(eventName)")
    }

    public func handleCommand(_ commandId: String) {
        print("[OneLineCommandLogic] Command: \(commandId)")

        switch commandId {
        case "one-line-command.show":
            showInputPanel()

        case "one-line-command.hide":
            hideInputPanel()

        default:
            break
        }
    }

    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        print("[OneLineCommandLogic] Request: \(requestId) params: \(params)")

        switch requestId {
        case "executeCommand":
            guard let command = params["command"] as? String,
                  let cwd = params["cwd"] as? String else {
                return ["success": false, "error": "Missing command or cwd"]
            }
            return executeCommand(command, cwd: cwd)

        default:
            return ["success": false, "error": "Unknown request: \(requestId)"]
        }
    }

    // MARK: - Private Methods

    /// 显示命令输入面板
    private func showInputPanel() {
        host?.emit(
            eventName: "plugin.one-line-command.show",
            payload: [:]
        )
    }

    /// 隐藏命令输入面板
    private func hideInputPanel() {
        host?.emit(
            eventName: "plugin.one-line-command.hide",
            payload: [:]
        )
    }

    /// 执行命令
    private func executeCommand(_ command: String, cwd: String) -> [String: Any] {
        do {
            let result = try ImmediateExecutor.executeSync(command, cwd: cwd)
            return ["success": true, "output": result]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }
}
