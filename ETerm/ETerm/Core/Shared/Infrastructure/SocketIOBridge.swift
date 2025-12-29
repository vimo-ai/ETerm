// SocketIOBridge.swift
// ETerm
//
// SocketIO 桥接层 - 提供 Socket 服务给 SDK 插件使用

import Foundation
import SocketIO
import ETermKit

// MARK: - SocketIOBridge

/// SocketIO 桥接服务
///
/// 管理所有 Socket 连接，提供给 SDK 插件复用。
/// 避免每个插件都链接自己的 SocketIO 库。
final class SocketIOBridge: SocketServiceProtocol, @unchecked Sendable {

    static let shared = SocketIOBridge()

    /// 活跃的 SocketManager（按 URL 复用）
    private var managers: [URL: SocketManager] = [:]

    /// 同步锁
    private let lock = NSLock()

    private init() {}

    // MARK: - SocketServiceProtocol

    func createClient(
        url: URL,
        namespace: String,
        config: SocketClientConfig
    ) -> SocketClientProtocol {
        lock.lock()
        defer { lock.unlock() }

        // 复用或创建 SocketManager
        let manager = managers[url] ?? {
            let socketConfig: SocketIOClientConfiguration = [
                .log(config.log),
                .compress,
                .forceWebsockets(config.forceWebsockets),
                .reconnects(config.reconnects),
                .reconnectWait(Int(config.reconnectWait)),
                .reconnectAttempts(config.reconnectAttempts)
            ]

            let m = SocketManager(socketURL: url, config: socketConfig)
            managers[url] = m
            return m
        }()

        let socket = manager.socket(forNamespace: namespace)
        return SocketIOClientWrapper(socket: socket)
    }

    // MARK: - Cleanup

    /// 清理所有连接
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        for (_, manager) in managers {
            manager.disconnect()
        }
        managers.removeAll()
    }
}

// MARK: - SocketIOClientWrapper

/// SocketIOClient 包装器
///
/// 将 SocketIO 库的 SocketIOClient 包装为 SocketClientProtocol
final class SocketIOClientWrapper: SocketClientProtocol, @unchecked Sendable {

    private let socket: SocketIOClient

    /// 同步锁
    private let lock = NSLock()

    var isConnected: Bool {
        socket.status == .connected
    }

    init(socket: SocketIOClient) {
        self.socket = socket
    }

    func connect() {
        socket.connect()
    }

    func disconnect() {
        socket.disconnect()
    }

    func on(_ event: String, callback: @escaping @Sendable @MainActor ([Any]) -> Void) {
        socket.on(event) { data, _ in
            Task { @MainActor in
                callback(data)
            }
        }
    }

    func onClientEvent(_ event: ETermKit.SocketClientEvent, callback: @escaping @Sendable @MainActor () -> Void) {
        let clientEvent: SocketIO.SocketClientEvent = switch event {
        case .connect: .connect
        case .disconnect: .disconnect
        case .error: .error
        case .reconnect: .reconnect
        case .reconnectAttempt: .reconnectAttempt
        }

        socket.on(clientEvent: clientEvent) { _, _ in
            Task { @MainActor in
                callback()
            }
        }
    }

    func emit(_ event: String, _ data: [String: Any]) {
        socket.emit(event, data)
    }

    func emitWithAck(
        _ event: String,
        _ data: [String: Any],
        timeout: TimeInterval,
        completion: @escaping @Sendable @MainActor ([Any]) -> Void
    ) {
        socket.emitWithAck(event, data).timingOut(after: timeout) { response in
            Task { @MainActor in
                completion(response)
            }
        }
    }

    func off(_ event: String) {
        socket.off(event)
    }

    func offAll() {
        socket.removeAllHandlers()
    }
}
