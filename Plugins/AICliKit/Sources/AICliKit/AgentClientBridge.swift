//
//  AgentClientBridge.swift
//  AICliKit
//
//  Swift wrapper for ai-cli-session-db Agent Client FFI
//  Provides HookEvent subscription via Unix Socket connection to Agent
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
    case hookEvent
    case unknown(UInt32)

    init(from ffiType: AgentEventType) {
        switch ffiType {
        case NewMessage: self = .newMessages
        case SessionStart: self = .sessionStart
        case SessionEnd: self = .sessionEnd
        case HookEvent: self = .hookEvent
        default: self = .unknown(ffiType.rawValue)
        }
    }

    var ffiType: AgentEventType {
        switch self {
        case .newMessages: return NewMessage
        case .sessionStart: return SessionStart
        case .sessionEnd: return SessionEnd
        case .hookEvent: return HookEvent
        case .unknown(let raw): return AgentEventType(rawValue: raw)
        }
    }
}

// MARK: - HookEvent Data

/// vimo-agent 推送的 HookEvent 数据
struct AgentHookEvent: Codable {
    let eventType: String
    let sessionId: String
    let transcriptPath: String?
    let cwd: String?
    let prompt: String?
    let toolName: String?
    let toolInput: [String: AnyCodableValue]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    let context: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case prompt
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case context
    }

    /// 从 context 提取 terminal_id
    var terminalId: Int? {
        guard let ctx = context,
              let value = ctx["terminal_id"] else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
}

/// 用于解码任意 JSON 值
enum AnyCodableValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case dict([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .dict(let dict):
            try container.encode(dict)
        }
    }

    /// 转换为 Any 类型
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.anyValue }
        case .dict(let dict): return dict.mapValues { $0.anyValue }
        }
    }
}

// MARK: - Delegate Protocol

/// AgentClient 事件回调协议
protocol AgentClientDelegate: AnyObject {
    func agentClient(_ client: AgentClientBridge, didReceiveHookEvent event: AgentHookEvent)
    func agentClient(_ client: AgentClientBridge, didDisconnect error: Error?)
}

// MARK: - AgentClientBridge

/// Agent Client 桥接层
///
/// 通过 Unix Socket 连接到 vimo-agent，订阅 HookEvent 推送
class AgentClientBridge {

    // MARK: - Properties

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.eterm.AICliKit.AgentClientBridge", qos: .utility)

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
    ///   - component: 组件名称（如 "aiclikit"）
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
        setupCallback()
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

    /// 订阅 HookEvent
    func subscribeHookEvent() throws {
        try subscribe(events: [.hookEvent])
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
        // 只处理 HookEvent
        guard case .hookEvent = kind else {
            logDebug("[AgentClient] ignoring non-HookEvent: \(kind)")
            return
        }

        guard let data = json.data(using: .utf8) else {
            logWarn("[AgentClient] failed to parse event JSON: \(json)")
            return
        }

        let decoder = JSONDecoder()

        do {
            let event = try decoder.decode(AgentHookEvent.self, from: data)

            // 回调到主线程
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.agentClient(self, didReceiveHookEvent: event)
            }

        } catch {
            logError("[AgentClient] failed to decode HookEvent: \(error), json: \(json)")
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
