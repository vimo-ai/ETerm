// ExtensionHost.swift
// ETermExtensionHost
//
// Extension Host 核心逻辑

import Foundation
import ETermKit

/// Extension Host core
public actor ExtensionHost {
    private let socketPath: String
    private var connection: IPCConnection?
    private var plugins: [String: any PluginLogic] = [:]
    private var hostBridge: ExtensionHostBridge?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// 运行 Host
    public func run() async throws {
        // 连接到主进程
        log("Connecting to \(socketPath)...")
        let config = IPCConnectionConfig(socketPath: socketPath)
        let conn = IPCConnection(config: config)
        try await conn.connect()
        self.connection = conn

        log("Connected to main process")

        // 创建 HostBridge
        log("Creating HostBridge...")
        let bridge = ExtensionHostBridge(connection: conn)
        self.hostBridge = bridge
        log("HostBridge created")

        // 设置消息处理器
        log("Setting message handler...")
        await conn.setMessageHandler { [weak self] message in
            await self?.handleMessage(message)
        }
        log("Message handler set")

        // 先发送握手消息（在启动 receiveLoop 之前，避免 actor 阻塞）
        log("Sending handshake...")
        try await conn.send(IPCMessage(
            type: .handshake,
            payload: [
                "status": "ready",
                "protocolVersion": IPCProtocolVersion,
                "hostVersion": "1.0.0"
            ]
        ))
        log("Handshake sent")

        // 启动接收循环（握手发送后再启动，避免 poll() 阻塞 send()）
        log("Starting receive loop...")
        await conn.startReceiving()
        log("Receive loop started")

        log("Extension Host ready")

        // 保持运行
        while await conn.getState() == .connected {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        }

        log("Connection closed, shutting down")
        await shutdown()
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

            // 激活插件
            if let bridge = hostBridge {
                plugin.activate(host: bridge)
            }

            log("Activated plugin: \(pluginId)")

            // 发送成功响应
            try await connection?.send(IPCMessage.response(to: message, payload: [
                "status": "activated"
            ]))

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
            log("Deactivated plugin: \(pluginId)")
        }

        try? await connection?.send(IPCMessage.response(to: message, payload: [
            "status": "deactivated"
        ]))
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

        try? await connection?.send(IPCMessage.response(to: message))
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
        try? await connection?.send(IPCMessage.response(to: message, payload: result))
    }

    /// 处理服务调用
    private func handleServiceCall(_ message: IPCMessage) async {
        // TODO: 实现服务调用路由
        await sendError(to: message, code: "NOT_IMPLEMENTED", message: "Service call not implemented")
    }

    /// 发送错误响应
    private func sendError(to request: IPCMessage, code: String, message: String) async {
        try? await connection?.send(IPCMessage.error(to: request, code: code, message: message))
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

        // 断开连接
        await connection?.disconnect()
    }

    /// 日志
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        fputs("[\(timestamp)] [ExtensionHost] \(message)\n", stderr)
        fflush(stderr)  // 确保立即输出
    }
}
