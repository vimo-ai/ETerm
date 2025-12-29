// SocketService.swift
// ETermKit
//
// Socket 服务协议 - 允许 SDK 插件复用主应用的 SocketIO 连接

import Foundation

// MARK: - Socket 客户端事件

/// Socket 客户端事件类型
public enum SocketClientEvent: String, Sendable {
    case connect
    case disconnect
    case error
    case reconnect
    case reconnectAttempt
}

// MARK: - Socket 客户端配置

/// Socket 客户端配置
public struct SocketClientConfig: Sendable {
    /// 是否自动重连
    public var reconnects: Bool

    /// 重连等待时间（秒）
    public var reconnectWait: TimeInterval

    /// 重连最大尝试次数（-1 表示无限）
    public var reconnectAttempts: Int

    /// 是否强制使用 WebSocket
    public var forceWebsockets: Bool

    /// 是否启用压缩
    public var compress: Bool

    /// 是否输出日志
    public var log: Bool

    public init(
        reconnects: Bool = true,
        reconnectWait: TimeInterval = 5,
        reconnectAttempts: Int = -1,
        forceWebsockets: Bool = true,
        compress: Bool = true,
        log: Bool = false
    ) {
        self.reconnects = reconnects
        self.reconnectWait = reconnectWait
        self.reconnectAttempts = reconnectAttempts
        self.forceWebsockets = forceWebsockets
        self.compress = compress
        self.log = log
    }
}

// MARK: - Socket 客户端协议

/// Socket 客户端协议
///
/// 提供 Socket.IO 风格的事件驱动通信接口。
/// 主应用基于 SocketIO 库实现，插件通过此协议使用。
public protocol SocketClientProtocol: AnyObject, Sendable {

    /// 连接状态
    var isConnected: Bool { get }

    /// 连接到服务器
    func connect()

    /// 断开连接
    func disconnect()

    /// 监听自定义事件
    ///
    /// - Parameters:
    ///   - event: 事件名称
    ///   - callback: 回调函数，参数为事件数据数组
    func on(_ event: String, callback: @escaping @Sendable @MainActor ([Any]) -> Void)

    /// 监听客户端事件
    ///
    /// - Parameters:
    ///   - event: 客户端事件类型
    ///   - callback: 回调函数
    func onClientEvent(_ event: SocketClientEvent, callback: @escaping @Sendable @MainActor () -> Void)

    /// 发送消息
    ///
    /// - Parameters:
    ///   - event: 事件名称
    ///   - data: 事件数据
    func emit(_ event: String, _ data: [String: Any])

    /// 发送消息并等待确认
    ///
    /// - Parameters:
    ///   - event: 事件名称
    ///   - data: 事件数据
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调，参数为确认数据
    func emitWithAck(
        _ event: String,
        _ data: [String: Any],
        timeout: TimeInterval,
        completion: @escaping @Sendable @MainActor ([Any]) -> Void
    )

    /// 移除指定事件的所有监听器
    ///
    /// - Parameter event: 事件名称
    func off(_ event: String)

    /// 移除所有监听器
    func offAll()
}

// MARK: - Socket 服务协议

/// Socket 服务协议
///
/// 由主应用实现，通过 HostBridge 提供给插件使用。
/// 插件可以通过此服务创建 Socket 客户端连接。
public protocol SocketServiceProtocol: AnyObject, Sendable {

    /// 创建 Socket 客户端
    ///
    /// - Parameters:
    ///   - url: 服务器地址
    ///   - namespace: Socket.IO namespace（如 "/daemon"）
    ///   - config: 客户端配置
    /// - Returns: Socket 客户端实例
    func createClient(
        url: URL,
        namespace: String,
        config: SocketClientConfig
    ) -> SocketClientProtocol
}
