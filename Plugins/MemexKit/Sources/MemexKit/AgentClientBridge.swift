//
//  AgentClientBridge.swift
//  MemexKit
//
//  Swift wrapper for ai-cli-session-db Agent Client FFI
//  [V2] 仅 RPC 连接（notifyFileChange），不订阅事件
//

import Foundation
import SharedDbFFI
import ETermKit

// MARK: - Error Types

enum AgentClientBridgeError: Error, LocalizedError {
    case nullPointer
    case invalidUtf8
    case connectionFailed
    case notConnected
    case requestFailed
    case agentNotFound
    case runtimeError
    case unknown(Int32)

    static func from(_ code: FfiError) -> AgentClientBridgeError? {
        switch code {
        case Success: return nil
        case NullPointer: return .nullPointer
        case InvalidUtf8: return .invalidUtf8
        case ConnectionFailed: return .connectionFailed
        case NotConnected: return .notConnected
        case RequestFailed: return .requestFailed
        case AgentNotFound: return .agentNotFound
        case RuntimeError: return .runtimeError
        default: return .unknown(Int32(code.rawValue))
        }
    }

    var errorDescription: String? {
        switch self {
        case .nullPointer: return "Null pointer error"
        case .invalidUtf8: return "Invalid UTF-8 string"
        case .connectionFailed: return "Failed to connect to Agent"
        case .notConnected: return "Not connected to Agent"
        case .requestFailed: return "Request to Agent failed"
        case .agentNotFound: return "Agent binary not found"
        case .runtimeError: return "Runtime error"
        case .unknown(let code): return "Unknown error (code: \(code))"
        }
    }
}

// MARK: - AgentClientBridge

/// Agent Client 桥接层（仅 RPC）
///
/// [V2] 仅保留 RPC 连接用于 notifyFileChange 写请求。
/// 事件订阅已由 AICliKit event 接管（aicli.responseComplete）。
class AgentClientBridge {

    // MARK: - Properties

    private var handle: OpaquePointer?

    /// 组件名称
    let component: String

    /// 是否已连接
    var isConnected: Bool {
        guard let handle = handle else { return false }
        return agent_client_is_connected(handle)
    }

    // MARK: - Lifecycle

    /// 创建 AgentClient
    /// - Parameters:
    ///   - component: 组件名称（如 "memexkit"）
    ///   - dataDir: 数据目录（可选，默认 ~/.vimo）
    ///   - agentSourceDir: Agent 源目录（可选，用于首次部署 vimo-agent）
    init(component: String, dataDir: String? = nil, agentSourceDir: String? = nil) throws {
        self.component = component

        var handlePtr: OpaquePointer?

        // 辅助函数：安全地处理可选 C 字符串
        func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            if let s = string {
                return s.withCString { body($0) }
            } else {
                return body(nil)
            }
        }

        let result = component.withCString { componentPtr in
            withOptionalCString(dataDir) { dataDirPtr in
                withOptionalCString(agentSourceDir) { agentSourceDirPtr in
                    agent_client_create(componentPtr, dataDirPtr, agentSourceDirPtr, &handlePtr)
                }
            }
        }

        if let error = AgentClientBridgeError.from(result) {
            throw error
        }

        self.handle = handlePtr
    }

    /// 便捷初始化：自动使用 bundle 的 Lib 目录作为 Agent 源
    /// - Parameters:
    ///   - component: 组件名称
    ///   - bundle: Plugin bundle（用于定位 vimo-agent）
    convenience init(component: String, bundle: Bundle) throws {
        let agentSourceDir = bundle.bundlePath + "/Contents/Lib"
        try self.init(component: component, agentSourceDir: agentSourceDir)
    }

    deinit {
        disconnect()
        if let handle = handle {
            agent_client_destroy(handle)
        }
    }

    // MARK: - Connection

    /// 连接到 Agent
    ///
    /// 如果 Agent 未运行，会自动启动
    func connect() throws {
        guard let handle = handle else {
            throw AgentClientBridgeError.nullPointer
        }

        let result = agent_client_connect(handle)
        if let error = AgentClientBridgeError.from(result) {
            throw error
        }

        logInfo("[AgentClient] connected (RPC only)")
    }

    /// 断开连接
    func disconnect() {
        guard let handle = handle else { return }
        agent_client_disconnect(handle)
        logInfo("[AgentClient] disconnected")
    }

    // MARK: - RPC: File Change Notification

    /// 通知文件变化（同步 RPC：返回即 collect 完成）
    ///
    /// 由 MemexPlugin.handleEvent("aicli.responseComplete") 触发，
    /// 通知 agent 立即采集指定 JSONL 文件。
    /// - Parameter path: JSONL 文件路径
    func notifyFileChange(path: String) throws {
        guard let handle = handle else {
            throw AgentClientBridgeError.nullPointer
        }

        let result = path.withCString { pathPtr in
            agent_client_notify_file_change(handle, pathPtr)
        }

        if let error = AgentClientBridgeError.from(result) {
            throw error
        }
    }
}

// MARK: - Version

extension AgentClientBridge {
    /// 获取版本号
    static var version: String {
        guard let versionPtr = agent_client_version() else {
            return "unknown"
        }
        return String(cString: versionPtr)
    }
}
