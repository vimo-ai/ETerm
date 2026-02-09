//
//  SocketClientBridge.swift
//  VlaudeKit
//
//  Swift wrapper for socket-client-ffi
//  Handles Socket.IO connection to vlaude-server
//
//  VlaudeKit 使用此桥接层处理 Socket 连接和数据同步
//  ETerm 特有逻辑（createSession, sendMessage 等）保留在 VlaudeClient.swift
//

import Foundation
import SocketClientFFI

// MARK: - Error Types

enum SocketClientError: Error, LocalizedError {
    case nullPointer
    case invalidUtf8
    case connectionFailed
    case notConnected
    case emitFailed
    case runtimeError
    case registryError
    case unknown(Int32)

    static func from(_ code: SocketClientFFI.SocketClientError) -> SocketClientError? {
        switch code {
        case SUCCESS: return nil
        case NULL_POINTER: return .nullPointer
        case INVALID_UTF8: return .invalidUtf8
        case CONNECTION_FAILED: return .connectionFailed
        case NOT_CONNECTED: return .notConnected
        case EMIT_FAILED: return .emitFailed
        case RUNTIME_ERROR: return .runtimeError
        case REGISTRY_ERROR: return .registryError
        default: return .unknown(Int32(code.rawValue))
        }
    }

    var errorDescription: String? {
        switch self {
        case .nullPointer: return "Null pointer"
        case .invalidUtf8: return "Invalid UTF-8"
        case .connectionFailed: return "Connection failed"
        case .notConnected: return "Not connected"
        case .emitFailed: return "Emit failed"
        case .runtimeError: return "Runtime error"
        case .registryError: return "Registry error"
        case .unknown(let code): return "Unknown error (\(code))"
        }
    }
}

// MARK: - Event Callback Protocol

protocol SocketClientBridgeDelegate: AnyObject {
    /// 收到服务器事件
    func socketClient(_ bridge: SocketClientBridge, didReceiveEvent event: String, data: [String: Any])

    /// 连接状态变化
    func socketClientDidConnect(_ bridge: SocketClientBridge)
    func socketClientDidDisconnect(_ bridge: SocketClientBridge)

    /// 重连状态（Server 重启后自动重连）
    func socketClientDidReconnect(_ bridge: SocketClientBridge)
    func socketClient(_ bridge: SocketClientBridge, reconnectFailed error: String)
}

// MARK: - Redis Configuration

/// Redis 配置
struct RedisConfig {
    let host: String
    let port: UInt16
    let password: String?
}

/// Daemon 配置（用于 Redis 注册）
struct DaemonConfig {
    let deviceId: String
    let deviceName: String
    let platform: String
    let version: String
    let ttl: UInt64  // 秒
}

/// Session 信息（用于 Redis 更新）
struct SessionInfo: Codable {
    let sessionId: String
    let projectPath: String
}

// MARK: - SocketClientBridge

/// Swift bridge for socket-client-ffi
/// Thread-safe wrapper for Rust socket client
final class SocketClientBridge {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.eterm.SocketClientBridge", qos: .userInitiated)

    weak var delegate: SocketClientBridgeDelegate?

    /// 保持对 self 的引用，用于 C 回调
    private var callbackContext: UnsafeMutableRawPointer?

    // MARK: - Lifecycle

    /// 创建 Socket 客户端（通过 Redis 服务发现）
    /// - Parameters:
    ///   - url: 服务器地址（作为 fallback）
    ///   - namespace: 命名空间（默认 "/daemon"）
    ///   - redis: Redis 配置
    ///   - daemon: Daemon 配置
    init(url: String, namespace: String = "/daemon", redis: RedisConfig, daemon: DaemonConfig) throws {
        var handlePtr: OpaquePointer?

        let error = url.withCString { urlCstr in
            namespace.withCString { nsCstr in
                redis.host.withCString { hostCstr in
                    daemon.deviceId.withCString { deviceIdCstr in
                        daemon.deviceName.withCString { deviceNameCstr in
                            daemon.platform.withCString { platformCstr in
                                daemon.version.withCString { versionCstr in
                                    let passwordPtr: UnsafePointer<CChar>? = redis.password.flatMap { strdup($0).map { UnsafePointer($0) } }
                                    defer {
                                        if let p = passwordPtr { free(UnsafeMutablePointer(mutating: p)) }
                                    }
                                    return socket_client_create_with_redis(
                                        urlCstr,
                                        nsCstr,
                                        hostCstr,
                                        redis.port,
                                        passwordPtr,
                                        deviceIdCstr,
                                        deviceNameCstr,
                                        platformCstr,
                                        versionCstr,
                                        daemon.ttl,
                                        &handlePtr
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        if let err = SocketClientError.from(error) {
            throw err
        }

        self.handle = handlePtr
    }

    deinit {
        // 先清除回调，防止 use-after-free
        if let handle = handle {
            socket_client_set_event_callback(handle, nil, nil)
        }

        // 释放 retained 的 self 引用
        if let ctx = callbackContext {
            Unmanaged<SocketClientBridge>.fromOpaque(ctx).release()
            callbackContext = nil
        }

        if let handle = handle {
            socket_client_destroy(handle)
        }
    }

    // MARK: - Connection

    /// 连接到服务器（通过 Redis 服务发现）
    /// 1. 初始化 Redis 连接
    /// 2. 从 Redis 发现 Server 地址
    /// 3. 连接 Socket
    /// 4. 注册到 Redis
    /// 5. 启动心跳和重连监听
    func connect() throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            // 设置事件回调
            setupEventCallback()

            let error = socket_client_connect_with_discovery(handle)
            if let err = SocketClientError.from(error) {
                throw err
            }
        }

        // 通知代理
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.socketClientDidConnect(self)
        }
    }

    /// 发现 Server 地址
    /// - Returns: 发现的第一个 Server 地址，如果没有则返回 nil
    func discoverServer() -> String? {
        queue.sync {
            guard let handle = handle else { return nil }

            let resultPtr = socket_client_discover_server(handle)
            guard let ptr = resultPtr else { return nil }

            let result = String(cString: ptr)
            socket_client_free_string(ptr)
            return result
        }
    }

    /// 断开连接
    func disconnect() {
        queue.sync {
            guard let handle = handle else { return }

            // 先清除回调，防止 disconnect 后还收到事件
            socket_client_set_event_callback(handle, nil, nil)

            // 释放 retained 的 self 引用
            if let ctx = callbackContext {
                Unmanaged<SocketClientBridge>.fromOpaque(ctx).release()
                callbackContext = nil
            }

            socket_client_disconnect(handle)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.socketClientDidDisconnect(self)
        }
    }

    /// 是否已连接
    var isConnected: Bool {
        queue.sync {
            guard let handle = handle else { return false }
            return socket_client_is_connected(handle)
        }
    }

    // MARK: - Event Callback

    private func setupEventCallback() {
        guard let handle = handle else { return }

        // 释放旧的 retained 引用（如果有）
        if let ctx = callbackContext {
            Unmanaged<SocketClientBridge>.fromOpaque(ctx).release()
        }

        // 创建 retained 指向 self 的指针，防止 use-after-free
        callbackContext = Unmanaged.passRetained(self).toOpaque()

        // 设置 C 回调
        socket_client_set_event_callback(handle, { event, data, userData in
            guard let event = event,
                  let data = data,
                  let userData = userData else { return }

            let bridge = Unmanaged<SocketClientBridge>.fromOpaque(userData).takeUnretainedValue()
            let eventStr = String(cString: event)
            let dataStr = String(cString: data)

            // 处理内部事件
            switch eventStr {
            case "__reconnected":
                DispatchQueue.main.async {
                    bridge.delegate?.socketClientDidReconnect(bridge)
                }
                return
            case "__reconnect_failed":
                if let jsonData = dataStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let error = dict["error"] as? String {
                    DispatchQueue.main.async {
                        bridge.delegate?.socketClient(bridge, reconnectFailed: error)
                    }
                }
                return
            default:
                break
            }

            // 解析 JSON - 支持对象和数组
            if let jsonData = dataStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) {
                let payload: [String: Any]
                if let dict = json as? [String: Any] {
                    payload = dict
                } else {
                    // 数组或标量包装为 {"data": ...}
                    payload = ["data": json]
                }
                DispatchQueue.main.async {
                    bridge.delegate?.socketClient(bridge, didReceiveEvent: eventStr, data: payload)
                }
            }
        }, callbackContext)
    }

    // MARK: - Registration

    /// 注册 daemon
    func register(hostname: String, platform: String, version: String) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let error = hostname.withCString { hostCstr in
                platform.withCString { platCstr in
                    version.withCString { verCstr in
                        socket_client_register(handle, hostCstr, platCstr, verCstr)
                    }
                }
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    // MARK: - Status Reporting

    /// 上报在线状态
    func reportOnline() throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }
            let error = socket_client_report_online(handle)
            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 上报离线状态
    func reportOffline() throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }
            let error = socket_client_report_offline(handle)
            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    // MARK: - Redis Session Updates

    /// 更新 Redis 中的 Session 列表
    /// - Parameter sessions: Session 信息数组
    func updateSessions(_ sessions: [SessionInfo]) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(sessions)
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
                throw SocketClientError.invalidUtf8
            }

            let error = jsonStr.withCString { jsonCstr in
                socket_client_update_sessions(handle, jsonCstr)
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    // MARK: - Data Reporting

    /// 上报项目数据
    func reportProjectData(projects: [[String: Any]], requestId: String? = nil) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let jsonData = try JSONSerialization.data(withJSONObject: projects)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "[]"

            let error = jsonStr.withCString { jsonCstr in
                if let reqId = requestId {
                    return reqId.withCString { reqCstr in
                        socket_client_report_project_data(handle, jsonCstr, reqCstr)
                    }
                } else {
                    return socket_client_report_project_data(handle, jsonCstr, nil)
                }
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 上报会话元数据
    func reportSessionMetadata(sessions: [[String: Any]], projectPath: String? = nil, requestId: String? = nil) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let jsonData = try JSONSerialization.data(withJSONObject: sessions)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "[]"

            let error = jsonStr.withCString { jsonCstr in
                let projPtr: UnsafePointer<CChar>? = projectPath.flatMap { $0.withCString { UnsafePointer(strdup($0)) } }
                let reqPtr: UnsafePointer<CChar>? = requestId.flatMap { $0.withCString { UnsafePointer(strdup($0)) } }

                defer {
                    if let p = projPtr { free(UnsafeMutablePointer(mutating: p)) }
                    if let r = reqPtr { free(UnsafeMutablePointer(mutating: r)) }
                }

                return socket_client_report_session_metadata(handle, jsonCstr, projPtr, reqPtr)
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 上报会话消息
    func reportSessionMessages(
        sessionId: String,
        projectPath: String,
        messages: [[String: Any]],
        total: Int,
        hasMore: Bool,
        requestId: String? = nil,
        openTurn: Bool? = nil,
        nextCursor: Int? = nil
    ) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let jsonData = try JSONSerialization.data(withJSONObject: messages)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "[]"

            // 防止负数溢出
            let safeTotal = UInt(max(0, total))

            // open_turn: -1 = None, 0 = false, 1 = true
            let openTurnVal: Int8 = openTurn.map { $0 ? 1 : 0 } ?? -1
            // next_cursor: -1 = None, >= 0 = value
            let nextCursorVal: Int64 = nextCursor.map { Int64($0) } ?? -1

            let error = sessionId.withCString { sidCstr in
                projectPath.withCString { pathCstr in
                    jsonStr.withCString { jsonCstr in
                        if let reqId = requestId {
                            return reqId.withCString { reqCstr in
                                socket_client_report_session_messages(
                                    handle, sidCstr, pathCstr, jsonCstr,
                                    safeTotal, hasMore, reqCstr,
                                    openTurnVal, nextCursorVal
                                )
                            }
                        } else {
                            return socket_client_report_session_messages(
                                handle, sidCstr, pathCstr, jsonCstr,
                                safeTotal, hasMore, nil,
                                openTurnVal, nextCursorVal
                            )
                        }
                    }
                }
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 通知新消息
    func notifyNewMessage(sessionId: String, message: [String: Any]) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let jsonData = try JSONSerialization.data(withJSONObject: message)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

            let error = sessionId.withCString { sidCstr in
                jsonStr.withCString { jsonCstr in
                    socket_client_notify_new_message(handle, sidCstr, jsonCstr)
                }
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 通知项目更新
    func notifyProjectUpdate(projectPath: String, metadata: [String: Any]? = nil) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let error = projectPath.withCString { pathCstr in
                if let meta = metadata,
                   let jsonData = try? JSONSerialization.data(withJSONObject: meta),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    return jsonStr.withCString { jsonCstr in
                        socket_client_notify_project_update(handle, pathCstr, jsonCstr)
                    }
                } else {
                    return socket_client_notify_project_update(handle, pathCstr, nil)
                }
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 通知会话列表更新
    func notifySessionListUpdate(projectPath: String) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let error = projectPath.withCString { pathCstr in
                socket_client_notify_session_list_update(handle, pathCstr)
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    // MARK: - V3 Write Operation Results

    /// 发送会话创建结果
    func sendSessionCreatedResult(
        requestId: String,
        success: Bool,
        sessionId: String? = nil,
        encodedDirName: String? = nil,
        transcriptPath: String? = nil,
        error: String? = nil
    ) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let result = requestId.withCString { reqCstr in
                let sidPtr: UnsafePointer<CChar>? = sessionId.flatMap { strdup($0).map { UnsafePointer($0) } }
                let encPtr: UnsafePointer<CChar>? = encodedDirName.flatMap { strdup($0).map { UnsafePointer($0) } }
                let pathPtr: UnsafePointer<CChar>? = transcriptPath.flatMap { strdup($0).map { UnsafePointer($0) } }
                let errPtr: UnsafePointer<CChar>? = error.flatMap { strdup($0).map { UnsafePointer($0) } }

                defer {
                    if let p = sidPtr { free(UnsafeMutablePointer(mutating: p)) }
                    if let p = encPtr { free(UnsafeMutablePointer(mutating: p)) }
                    if let p = pathPtr { free(UnsafeMutablePointer(mutating: p)) }
                    if let p = errPtr { free(UnsafeMutablePointer(mutating: p)) }
                }

                return socket_client_send_session_created_result(
                    handle, reqCstr, success, sidPtr, encPtr, pathPtr, errPtr
                )
            }

            if let err = SocketClientError.from(result) {
                throw err
            }
        }
    }

    /// 发送加载状态检查结果
    func sendCheckLoadingResult(requestId: String, loading: Bool) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let error = requestId.withCString { reqCstr in
                socket_client_send_check_loading_result(handle, reqCstr, loading)
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    /// 发送消息发送结果
    func sendMessageResult(requestId: String, success: Bool, message: String? = nil, via: String? = nil) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let result = requestId.withCString { reqCstr in
                let msgPtr: UnsafePointer<CChar>? = message.flatMap { strdup($0).map { UnsafePointer($0) } }
                let viaPtr: UnsafePointer<CChar>? = via.flatMap { strdup($0).map { UnsafePointer($0) } }

                defer {
                    if let p = msgPtr { free(UnsafeMutablePointer(mutating: p)) }
                    if let p = viaPtr { free(UnsafeMutablePointer(mutating: p)) }
                }

                return socket_client_send_message_result(handle, reqCstr, success, msgPtr, viaPtr)
            }

            if let err = SocketClientError.from(result) {
                throw err
            }
        }
    }

    // MARK: - Generic Emit

    /// 发送任意事件
    func emit(event: String, data: [String: Any]) throws {
        try queue.sync {
            guard let handle = handle else { throw SocketClientError.nullPointer }

            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

            let error = event.withCString { evCstr in
                jsonStr.withCString { jsonCstr in
                    socket_client_emit(handle, evCstr, jsonCstr)
                }
            }

            if let err = SocketClientError.from(error) {
                throw err
            }
        }
    }

    // MARK: - Version

    /// 获取 FFI 版本
    static var version: String {
        String(cString: socket_client_version())
    }
}
