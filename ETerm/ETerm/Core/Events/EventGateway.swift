//
//  EventGateway.swift
//  ETerm
//
//  事件网关 - 核心组件
//  监听 NotificationCenter 事件，推送到 Socket 和日志
//

import Foundation
import ETermKit

/// 事件网关
///
/// 监听插件 emit 的事件，通过 Unix Domain Socket 推送给外部进程。
/// 外部进程（如调度器 Claude）可通过 `nc -U ~/.vimo/eterm/run/events/claude/responseComplete.sock`
/// 监听特定事件。
///
/// ## 使用方式
/// ```bash
/// # 监听所有 Claude 完成事件
/// nc -U ~/.vimo/eterm/run/events/claude/responseComplete.sock
///
/// # 监听所有 Claude 相关事件
/// nc -U ~/.vimo/eterm/run/events/claude.sock
///
/// # 监听所有事件
/// nc -U ~/.vimo/eterm/run/events/all.sock
/// ```
final class EventGateway {

    /// 单例
    static let shared = EventGateway()

    /// Socket 服务器列表
    private var socketServers: [String: EventSocketServer] = [:]

    /// 锁（保护 socketServers 和 isRunning）
    private let lock = NSLock()

    /// 日志写入器
    private var logWriter: EventLogWriter?

    /// 是否已启动
    private(set) var isRunning = false

    /// NotificationCenter 观察者
    private var observer: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    /// 启动事件网关
    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        // 创建日志写入器
        logWriter = EventLogWriter(logDirectory: ETermPaths.logs)
        logWriter?.start()

        // 创建所有 socket 服务器
        createSocketServers()

        // 监听 NotificationCenter 事件
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.PluginEvent"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleNotification(notification)
        }

        isRunning = true
        logInfo("[EventGateway] Started, sockets: \(ETermPaths.eventsSocketDirectory)")
    }

    /// 停止事件网关
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }

        // 移除观察者
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        // 停止所有 socket 服务器
        for (_, server) in socketServers {
            server.stop()
        }
        socketServers.removeAll()

        // 停止日志写入器
        logWriter?.stop()
        logWriter = nil

        isRunning = false
        logInfo("[EventGateway] Stopped")
    }

    // MARK: - Socket Server Management

    /// 创建所有 socket 服务器
    private func createSocketServers() {
        // 聚合 socket
        createServer(pattern: "all", path: socketPath(for: "all"))
        createServer(pattern: "claude", path: socketPath(for: "claude"))
        createServer(pattern: "terminal", path: socketPath(for: "terminal"))

        // 精确匹配 socket（Claude 相关）
        for eventType in GatewayEvent.EventType.allCases {
            let pattern = eventType.rawValue
            let path = socketPath(for: pattern)
            createServer(pattern: pattern, path: path)
        }
    }

    private func createServer(pattern: String, path: String) {
        let server = EventSocketServer(socketPath: path, pattern: pattern)
        if server.start() {
            socketServers[pattern] = server
        } else {
            logError("[EventGateway] Failed to start socket: \(path)")
        }
    }

    /// 获取 socket 路径
    private func socketPath(for pattern: String) -> String {
        let components = pattern.split(separator: ".")

        if components.count == 1 {
            // 聚合 socket: all.sock, claude.sock, terminal.sock
            return "\(ETermPaths.eventsSocketDirectory)/\(pattern).sock"
        } else {
            // 精确匹配: claude/responseComplete.sock
            let dir = String(components[0])
            let name = components.dropFirst().joined(separator: ".")
            return "\(ETermPaths.eventsSocketDirectory)/\(dir)/\(name).sock"
        }
    }

    // MARK: - Event Handling

    private func handleNotification(_ notification: Notification) {
        guard let eventName = notification.userInfo?["eventName"] as? String,
              let payload = notification.userInfo?["payload"] as? [String: Any] else {
            return
        }

        let event = GatewayEvent(
            name: eventName,
            timestamp: Date(),
            payload: payload
        )

        // 发布事件
        publish(event)
    }

    /// 发布事件
    ///
    /// 将事件推送到所有匹配的 socket，并写入日志。
    func publish(_ event: GatewayEvent) {
        // 获取服务器快照（短暂持锁）
        lock.lock()
        let servers = Array(socketServers.values)
        let writer = logWriter
        lock.unlock()

        // 推送到所有 socket 服务器
        for server in servers {
            server.broadcast(event)
        }

        // 写入日志
        writer?.write(event)
    }
}

// MARK: - ETermPaths Extension

extension ETermPaths {
    /// 事件 Socket 目录: ~/.vimo/eterm/run/events
    static var eventsSocketDirectory: String {
        return "\(run)/events"
    }
}
