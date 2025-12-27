// ExtensionHost.swift
// ETermExtensionHost
//
// Extension Host 核心逻辑
//
// 改造后的架构：
// - Host 作为 IPC 服务端，常驻运行
// - ETerm 作为客户端连接到 Host
// - 支持多个 ETerm 实例连接
// - 客户端断开后 Host 继续运行

import Foundation
import ETermKit

/// Host 生命周期配置
public enum HostLifecycle: String, Codable, Sendable {
    case exitWithClient    // 最后一个客户端断开后退出
    case persist1Hour      // 保持 1 小时
    case persist5Hours     // 保持 5 小时
    case persist24Hours    // 保持 24 小时
    case persistForever    // 永久运行

    var timeoutSeconds: TimeInterval? {
        switch self {
        case .exitWithClient: return 0
        case .persist1Hour: return 3600
        case .persist5Hours: return 18000
        case .persist24Hours: return 86400
        case .persistForever: return nil
        }
    }
}

/// Extension Host core
///
/// 注意：当前设计假设单客户端连接。
/// 虽然 connections 字典支持多连接，但 hostBridge 只指向最后一个连接，
/// 插件状态也是全局共享的。多实例连接会导致：
/// - 只有最后连接的客户端收到插件 UI 更新
/// - 插件实例被后来者覆盖
/// 如果需要多实例支持，需重构为 per-connection 的插件和 bridge 管理。
public actor ExtensionHost {
    private let socketPath: String
    private var server: IPCServer?
    private var connections: [UUID: IPCConnection] = [:]  // 当前假设单客户端
    private var plugins: [String: any PluginLogic] = [:]
    private var hostBridge: ExtensionHostBridge?
    /// 每个插件的独立 bridge wrapper（pluginId -> wrapper）
    private var pluginBridges: [String: PluginHostBridgeWrapper] = [:]

    /// 生命周期配置
    private var lifecycle: HostLifecycle = .persist1Hour
    private var lastClientDisconnectTime: Date?
    private var isRunning = true

    public init(socketPath: String, lifecycle: HostLifecycle = .persist1Hour) {
        self.socketPath = socketPath
        self.lifecycle = lifecycle
    }

    /// 运行 Host（作为服务端）
    public func run() async throws {
        log("Starting Extension Host as server...")
        log("Socket path: \(socketPath)")
        log("Lifecycle: \(lifecycle.rawValue)")

        // 清理旧的 socket 文件
        try? FileManager.default.removeItem(atPath: socketPath)

        // 创建目录（如果不存在）
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)

        // 启动 IPC 服务端
        let config = IPCConnectionConfig(socketPath: socketPath)
        server = IPCServer(config: config)
        try await server?.start()

        log("Extension Host listening on \(socketPath)")

        // 写入 PID 文件（供 ETerm 检测 Host 存活）
        writePIDFile()

        // 主循环：接受连接 + 生命周期检查
        while isRunning {
            // 并发：接受新连接
            async let acceptTask: () = acceptNewConnection()

            // 检查生命周期
            checkLifecycle()

            // 等待一段时间
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            _ = await acceptTask
        }

        log("Extension Host shutting down...")
        await shutdown()
    }

    /// 接受新连接
    private func acceptNewConnection() async {
        guard let srv = server else { return }

        do {
            // 非阻塞方式尝试接受连接
            let conn = try await srv.acceptConnection()
            let connectionId = UUID()
            connections[connectionId] = conn

            log("New client connected: \(connectionId)")

            // 创建 HostBridge（如果还没有）
            if hostBridge == nil {
                hostBridge = ExtensionHostBridge(connection: conn)
            } else {
                // 更新 bridge 使用最新连接
                hostBridge?.updateConnection(conn)
            }

            // 设置消息处理器
            await conn.setMessageHandler { [weak self] message in
                await self?.handleMessage(message, from: connectionId)
            }

            // 发送握手响应
            try await conn.send(IPCMessage(
                type: .handshake,
                payload: [
                    "status": "ready",
                    "protocolVersion": IPCProtocolVersion,
                    "hostVersion": "1.0.0",
                    "loadedPlugins": Array(plugins.keys)
                ]
            ))

            // 启动接收循环
            await conn.startReceiving()

            // 监控连接状态
            Task {
                await monitorConnection(connectionId)
            }

        } catch {
            // accept 超时或其他错误，忽略继续
        }
    }

    /// 监控连接状态
    private func monitorConnection(_ connectionId: UUID) async {
        guard let conn = connections[connectionId] else { return }

        while await conn.getState() == .connected {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        }

        log("Client disconnected: \(connectionId)")
        connections.removeValue(forKey: connectionId)
        lastClientDisconnectTime = Date()
    }

    /// 检查生命周期
    private func checkLifecycle() {
        // 如果有活跃连接，重置断开时间
        if !connections.isEmpty {
            lastClientDisconnectTime = nil
            return
        }

        // 没有连接时，检查是否应该退出
        guard let timeout = lifecycle.timeoutSeconds else {
            // persistForever，永不退出
            return
        }

        if timeout == 0 {
            // exitWithClient，立即退出
            log("No clients connected, exiting (lifecycle: exitWithClient)")
            isRunning = false
            return
        }

        // 检查超时
        if let disconnectTime = lastClientDisconnectTime {
            let elapsed = Date().timeIntervalSince(disconnectTime)
            if elapsed >= timeout {
                log("Idle timeout reached (\(Int(elapsed))s), exiting")
                isRunning = false
            }
        } else {
            // 首次进入无连接状态
            lastClientDisconnectTime = Date()
        }
    }

    /// 写入 PID 文件
    private func writePIDFile() {
        let pidPath = (socketPath as NSString).deletingPathExtension + ".pid"
        let pid = ProcessInfo.processInfo.processIdentifier
        try? "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)
        log("PID file written: \(pidPath)")
    }

    /// 清理 PID 文件
    private func cleanupPIDFile() {
        let pidPath = (socketPath as NSString).deletingPathExtension + ".pid"
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// 处理消息（带连接 ID）
    private func handleMessage(_ message: IPCMessage, from connectionId: UUID) async {
        await handleMessage(message)
    }

    /// 处理消息
    private func handleMessage(_ message: IPCMessage) async {
        switch message.type {
        case .activate:
            await handleActivate(message)

        case .deactivate:
            await handleDeactivate(message)

        case .event:
            await handleEvent(message)

        case .commandInvoke:
            await handleCommand(message)

        case .pluginRequest:
            await handlePluginRequest(message)

        case .serviceCall:
            await handleServiceCall(message)

        case .response, .error:
            // response/error 消息应由 pendingRequests 处理，这里忽略
            break

        default:
            log("Unknown message type: \(message.type)")
        }
    }

    /// 处理插件激活
    private func handleActivate(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing pluginId")
            return
        }

        let payload = message.rawPayload
        guard let bundlePath = payload["bundlePath"] as? String else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing bundlePath")
            return
        }

        do {
            // 加载 manifest
            let manifest = try PluginManifest.load(from: bundlePath)

            // 加载 Bundle
            guard let bundle = Bundle(path: bundlePath) else {
                throw PluginError.bundleLoadFailed(reason: "Cannot load bundle at \(bundlePath)")
            }

            guard bundle.load() else {
                throw PluginError.bundleLoadFailed(reason: "Bundle.load() failed")
            }

            // 获取 principal class（先尝试 bundle.principalClass，再用 NSClassFromString）
            let principalClass: any PluginLogic.Type
            if let cls = bundle.principalClass as? any PluginLogic.Type {
                principalClass = cls
            } else if let cls = NSClassFromString(manifest.principalClass) as? any PluginLogic.Type {
                principalClass = cls
            } else {
                // 打印调试信息
                log("bundle.principalClass = \(String(describing: bundle.principalClass))")
                log("NSClassFromString(\(manifest.principalClass)) = \(String(describing: NSClassFromString(manifest.principalClass)))")
                throw PluginError.principalClassNotFound(className: manifest.principalClass)
            }

            // 创建插件实例
            let plugin = principalClass.init()
            plugins[pluginId] = plugin

            // 为该插件创建独立的 bridge wrapper
            if let bridge = hostBridge {
                let wrapper = PluginHostBridgeWrapper(pluginId: pluginId, bridge: bridge)
                pluginBridges[pluginId] = wrapper
                plugin.activate(host: wrapper)
            }

            log("Activated plugin: \(pluginId)")

            // 发送成功响应
            await sendResponse(to: message, payload: ["status": "activated"])

        } catch {
            await sendError(to: message, code: "ACTIVATION_FAILED", message: error.localizedDescription)
        }
    }

    /// 处理插件停用
    private func handleDeactivate(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing pluginId")
            return
        }

        if let plugin = plugins.removeValue(forKey: pluginId) {
            plugin.deactivate()
            pluginBridges.removeValue(forKey: pluginId)
            log("Deactivated plugin: \(pluginId)")
        }

        await sendResponse(to: message, payload: ["status": "deactivated"])
    }

    /// 处理事件
    private func handleEvent(_ message: IPCMessage) async {
        let payload = message.rawPayload
        guard let eventName = payload["eventName"] as? String else {
            return
        }

        // 如果指定了 pluginId，只发给该插件
        if let pluginId = message.pluginId {
            if let plugin = plugins[pluginId] {
                plugin.handleEvent(eventName, payload: payload)
            }
        } else {
            // 广播给所有插件
            for (_, plugin) in plugins {
                plugin.handleEvent(eventName, payload: payload)
            }
        }
    }

    /// 处理命令
    private func handleCommand(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing pluginId")
            return
        }

        let payload = message.rawPayload
        guard let commandId = payload["commandId"] as? String else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing commandId")
            return
        }

        if let plugin = plugins[pluginId] {
            plugin.handleCommand(commandId)
        }

        await sendResponse(to: message)
    }

    /// 处理插件请求
    private func handlePluginRequest(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing pluginId")
            return
        }

        let payload = message.rawPayload
        guard let requestId = payload["requestId"] as? String else {
            await sendError(to: message, code: "INVALID_REQUEST", message: "Missing requestId")
            return
        }

        let params = payload["params"] as? [String: Any] ?? [:]

        guard let plugin = plugins[pluginId] else {
            await sendError(to: message, code: "PLUGIN_NOT_FOUND", message: "Plugin \(pluginId) not found")
            return
        }

        // 调用插件的 handleRequest
        let result = plugin.handleRequest(requestId, params: params)

        // 发送响应
        await sendResponse(to: message, payload: result)
    }

    /// 处理服务调用（主进程转发来的请求，调用本地插件的服务）
    private func handleServiceCall(_ message: IPCMessage) async {
        guard let targetPluginId = message.rawPayload["targetPluginId"] as? String,
              let serviceName = message.rawPayload["name"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing targetPluginId or name")
            return
        }

        let params = message.rawPayload["params"] as? [String: Any] ?? [:]

        // 调用 hostBridge 中注册的服务处理器
        guard let bridge = hostBridge else {
            await sendError(to: message, code: "NOT_READY", message: "HostBridge not initialized")
            return
        }

        if let result = bridge.handleServiceCall(pluginId: targetPluginId, name: serviceName, params: params) {
            await sendResponse(to: message, payload: ["result": result])
        } else {
            await sendError(to: message, code: "SERVICE_NOT_FOUND",
                          message: "Service \(targetPluginId).\(serviceName) not found in extension host")
        }
    }

    /// 发送错误响应（广播给所有连接）
    private func sendError(to request: IPCMessage, code: String, message: String) async {
        let errorMsg = IPCMessage.error(to: request, code: code, message: message)
        await broadcast(errorMsg)
    }

    /// 发送响应（广播给所有连接）
    private func sendResponse(to request: IPCMessage, payload: [String: Any] = [:]) async {
        let response = IPCMessage.response(to: request, payload: payload)
        await broadcast(response)
    }

    /// 广播消息给所有连接
    private func broadcast(_ message: IPCMessage) async {
        for (_, conn) in connections {
            try? await conn.send(message)
        }
    }

    /// 获取第一个可用连接
    private var firstConnection: IPCConnection? {
        connections.values.first
    }

    /// 关闭
    private func shutdown() async {
        log("Shutting down...")

        // 停用所有插件
        for (id, plugin) in plugins {
            plugin.deactivate()
            log("Deactivated plugin: \(id)")
        }
        plugins.removeAll()
        pluginBridges.removeAll()

        // 断开所有连接
        for (_, conn) in connections {
            await conn.disconnect()
        }
        connections.removeAll()

        // 停止服务端
        await server?.stop()

        // 清理 PID 文件
        cleanupPIDFile()
    }

    /// 日志
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        fputs("[\(timestamp)] [ExtensionHost] \(message)\n", stderr)
        fflush(stderr)  // 确保立即输出
    }
}
