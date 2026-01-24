//
//  AgentClientBridge.swift
//  MemexKit
//
//  Swift wrapper for ai-cli-session-db Agent Client FFI
//  Provides event subscription via Unix Socket connection to Agent
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

// MARK: - Event Types

/// Agent 推送的事件类型
enum AgentEventKind {
    case newMessages
    case sessionStart
    case sessionEnd
    case unknown(UInt32)

    init(from ffiType: AgentEventType) {
        switch ffiType {
        case NewMessage: self = .newMessages
        case SessionStart: self = .sessionStart
        case SessionEnd: self = .sessionEnd
        default: self = .unknown(ffiType.rawValue)
        }
    }

    var ffiType: AgentEventType {
        switch self {
        case .newMessages: return NewMessage
        case .sessionStart: return SessionStart
        case .sessionEnd: return SessionEnd
        case .unknown(let raw): return AgentEventType(rawValue: raw)
        }
    }
}

/// 新消息事件数据
struct NewMessagesEvent: Codable {
    let sessionId: String
    let path: String
    let count: Int
    let messageIds: [Int64]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case path
        case count
        case messageIds = "message_ids"
    }
}

/// 会话开始事件数据
struct SessionStartEvent: Codable {
    let sessionId: String
    let projectPath: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case projectPath = "project_path"
    }
}

/// 会话结束事件数据
struct SessionEndEvent: Codable {
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

/// Agent 推送事件
enum AgentEvent {
    case newMessages(NewMessagesEvent)
    case sessionStart(SessionStartEvent)
    case sessionEnd(SessionEndEvent)
}

// MARK: - Delegate Protocol

/// AgentClient 事件回调协议
protocol AgentClientDelegate: AnyObject {
    func agentClient(_ client: AgentClientBridge, didReceiveEvent event: AgentEvent)
    func agentClient(_ client: AgentClientBridge, didDisconnect error: Error?)
}

// MARK: - AgentClientBridge

/// Agent Client 桥接层
///
/// 通过 Unix Socket 连接到 vimo-agent，订阅事件推送
class AgentClientBridge {

    // MARK: - Properties

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.eterm.AgentClientBridge", qos: .utility)

    weak var delegate: AgentClientDelegate?

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
    ///   - component: 组件名称（如 "vlaudekit", "memexkit"）
    ///   - dataDir: 数据目录（可选，默认 ~/.vimo）
    init(component: String, dataDir: String? = nil) throws {
        self.component = component

        var handlePtr: OpaquePointer?
        let result = component.withCString { componentPtr in
            if let dataDir = dataDir {
                return dataDir.withCString { dataDirPtr in
                    agent_client_create(componentPtr, dataDirPtr, &handlePtr)
                }
            } else {
                return agent_client_create(componentPtr, nil, &handlePtr)
            }
        }

        if let error = AgentClientBridgeError.from(result) {
            throw error
        }

        self.handle = handlePtr
        setupCallback()
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

        logInfo("[AgentClient] connected")
    }

    /// 断开连接
    func disconnect() {
        guard let handle = handle else { return }
        agent_client_disconnect(handle)
        logInfo("[AgentClient] disconnected")
    }

    // MARK: - Subscription

    /// 订阅事件
    /// - Parameter events: 要订阅的事件类型列表
    func subscribe(events: [AgentEventKind]) throws {
        guard let handle = handle else {
            throw AgentClientBridgeError.nullPointer
        }

        var ffiEvents = events.map { $0.ffiType }
        let result = agent_client_subscribe(handle, &ffiEvents, UInt(ffiEvents.count))

        if let error = AgentClientBridgeError.from(result) {
            throw error
        }

        logDebug("[AgentClient] subscribed to events: \(events)")
    }

    /// 订阅所有事件
    func subscribeAll() throws {
        try subscribe(events: [.newMessages, .sessionStart, .sessionEnd])
    }

    // MARK: - File Change Notification

    /// 通知文件变化
    ///
    /// 当 Swift 层检测到文件变化时，通知 Agent 触发重新解析
    /// - Parameter path: 文件路径
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

    // MARK: - Private

    /// 设置推送回调
    private func setupCallback() {
        guard let handle = handle else { return }

        // 使用 Unmanaged 传递 self
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        agent_client_set_push_callback(handle, { eventType, dataJson, userData in
            guard let userData = userData,
                  let dataJson = dataJson else { return }

            let bridge = Unmanaged<AgentClientBridge>.fromOpaque(userData).takeUnretainedValue()
            let jsonString = String(cString: dataJson)
            let eventKind = AgentEventKind(from: eventType)

            bridge.handleEvent(kind: eventKind, json: jsonString)
        }, selfPtr)
    }

    /// 处理事件
    private func handleEvent(kind: AgentEventKind, json: String) {
        // 忽略未知事件类型
        if case .unknown(let raw) = kind {
            logWarn("[AgentClient] received unknown event type: \(raw)")
            return
        }

        guard let data = json.data(using: .utf8) else {
            logWarn("[AgentClient] failed to parse event JSON: \(json)")
            return
        }

        let decoder = JSONDecoder()

        do {
            let event: AgentEvent

            switch kind {
            case .newMessages:
                let eventData = try decoder.decode(NewMessagesEvent.self, from: data)
                event = .newMessages(eventData)

            case .sessionStart:
                let eventData = try decoder.decode(SessionStartEvent.self, from: data)
                event = .sessionStart(eventData)

            case .sessionEnd:
                let eventData = try decoder.decode(SessionEndEvent.self, from: data)
                event = .sessionEnd(eventData)

            case .unknown:
                return  // 已在上面处理
            }

            // 回调到主线程
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.agentClient(self, didReceiveEvent: event)
            }

        } catch {
            logError("[AgentClient] failed to decode event: \(error)")
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
