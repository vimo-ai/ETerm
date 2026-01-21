//
//  VlaudeClient.swift
//  VlaudeKit
//
//  Socket 客户端 - 通过 Rust FFI (SocketClientBridge) 连接 vlaude-server
//
//  架构：
//  - Socket 连接/数据同步 → SocketClientBridge (Rust FFI)
//  - ETerm 控制逻辑 → 本文件处理
//

import Foundation
import ETermKit
import SocketClientFFI

// MARK: - Delegate Protocol

protocol VlaudeClientDelegate: AnyObject {
    /// 连接成功
    func vlaudeClientDidConnect(_ client: VlaudeClient)

    /// 连接断开
    func vlaudeClientDidDisconnect(_ client: VlaudeClient)

    /// 收到注入请求（旧方式）
    /// - Parameters:
    ///   - client: VlaudeClient 实例
    ///   - sessionId: 会话 ID
    ///   - text: 消息内容
    ///   - clientMessageId: 客户端消息 ID（用于去重）
    func vlaudeClient(_ client: VlaudeClient, didReceiveInject sessionId: String, text: String, clientMessageId: String?)

    /// 收到 Mobile 查看状态
    func vlaudeClient(_ client: VlaudeClient, didReceiveMobileViewing sessionId: String, isViewing: Bool)

    /// 收到创建会话请求（旧方式）
    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?)

    // MARK: - 新 WebSocket 事件（统一接口）

    /// 收到创建会话请求（新方式）
    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSessionNew projectPath: String, prompt: String?, requestId: String)

    /// 收到发送消息请求
    func vlaudeClient(_ client: VlaudeClient, didReceiveSendMessage sessionId: String, text: String, projectPath: String?, clientId: String?, requestId: String)

    /// 收到检查 loading 状态请求
    func vlaudeClient(_ client: VlaudeClient, didReceiveCheckLoading sessionId: String, projectPath: String?, requestId: String)

    // MARK: - 权限响应

    /// 收到权限响应（iOS 审批结果）
    /// - Parameters:
    ///   - client: VlaudeClient 实例
    ///   - sessionId: 会话 ID
    ///   - action: 响应动作 (y/n/a 或自定义输入如 "n: 理由")
    ///   - toolUseId: 工具调用 ID（用于返回 ack）
    func vlaudeClient(_ client: VlaudeClient, didReceivePermissionResponse sessionId: String, action: String, toolUseId: String)
}

// MARK: - VlaudeClient

final class VlaudeClient: SocketClientBridgeDelegate {
    weak var delegate: VlaudeClientDelegate?

    /// Socket 桥接层（Rust FFI）
    private var socketBridge: SocketClientBridge?
    private(set) var isConnected = false

    private var serverURL: String?
    private var deviceName: String = "Mac"

    /// Session 读取器（FFI）- 用于文件操作（pushNewMessages, indexSession）
    private lazy var sessionReader = SessionReader()

    /// Vlaude FFI Bridge（优先使用，DB 查询更快）
    private let vlaudeFfi = VlaudeFfiBridge.shared

    /// 共享数据库桥接（可选，用于缓存查询和搜索）
    private var sharedDb: SharedDbBridge?

    /// 当前打开的 Session 列表（用于重连时重新上报）
    /// 注意：状态由 Server 的 StatusManager 统一管理，此处仅用于重连上报
    private var openSessions: [String: (projectPath: String, terminalId: Int)] = [:]

    /// 心跳定时器（每 30 秒发送一次，保持 Redis TTL 不过期）
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 30.0

    // MARK: - Init

    init() {
        initSharedDb()
    }

    /// 初始化共享数据库（最佳努力）
    private func initSharedDb() {
        do {
            sharedDb = try SharedDbBridge()
            let role = try sharedDb?.register()

            // 成为 Writer 后触发全量采集
            if role == .writer {
                triggerCollectAsync()
            }
        } catch {
            sharedDb = nil
        }
    }

    /// 异步执行全量采集（后台线程，不阻塞主线程）
    private func triggerCollectAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let sharedDb = self?.sharedDb else { return }

            do {
                let result = try sharedDb.collect()
                if result.messagesInserted > 0 {
                    print("[VlaudeKit] Collect: \(result.sessionsScanned) sessions, \(result.messagesInserted) messages")
                }
            } catch {
                // 静默失败，采集是 best-effort
            }
        }
    }

    // MARK: - Connection

    /// 连接到服务器（通过 Redis 服务发现）
    /// - Parameters:
    ///   - config: VlaudeConfig 配置
    func connect(config: VlaudeConfig) {
        // 断开旧连接
        disconnect()

        // 确保 SharedDb 已初始化
        if sharedDb == nil {
            initSharedDb()
        }

        self.serverURL = config.serverURL
        self.deviceName = config.deviceName

        // 构建 Redis 和 Daemon 配置
        let redisConfig = RedisConfig(
            host: config.redisHost,
            port: config.redisPort,
            password: config.redisPassword
        )

        let daemonConfig = DaemonConfig(
            deviceId: config.deviceId,
            deviceName: config.deviceName,
            platform: "darwin",
            version: "1.0.0",
            ttl: config.daemonTTL
        )

        // 通过 Rust FFI 创建带 Redis 的 Socket 客户端
        do {
            socketBridge = try SocketClientBridge(
                url: config.serverURL.isEmpty ? "https://localhost:10005" : config.serverURL,
                namespace: "/daemon",
                redis: redisConfig,
                daemon: daemonConfig
            )
            socketBridge?.delegate = self
            try socketBridge?.connect()
        } catch {
            // 连接失败时通知 delegate
            delegate?.vlaudeClientDidDisconnect(self)
        }
    }

    /// 断开连接
    func disconnect() {
        // Bug #1 修复：停止心跳定时器
        stopHeartbeatTimer()

        if isConnected {
            // 发送离线通知（新架构：daemon:offline 事件）
            emitDaemonOffline()
        }

        socketBridge?.disconnect()
        socketBridge = nil
        isConnected = false
        serverURL = nil
        openSessions.removeAll()

        // 释放 SharedDbBridge Writer（确保 daemon 能接管）
        releaseSharedDb()
    }

    /// 手动重连（使用当前配置）
    func reconnect() {
        let config = VlaudeConfigManager.shared.config
        guard config.isValid else { return }

        // 保留 openSessions，重连后需要重新上报
        let savedSessions = openSessions
        connect(config: config)
        openSessions = savedSessions
    }

    // MARK: - Status Events (新架构：ETerm 只发事件，Server 管理状态)

    /// 发送 daemon:online 事件
    private func emitDaemonOnline() {
        guard isConnected else { return }

        let config = VlaudeConfigManager.shared.config
        let data: [String: Any] = [
            "deviceId": config.deviceId,
            "deviceName": config.deviceName,
            "platform": "darwin",
            "version": "1.0.0"
        ]

        try? socketBridge?.emit(event: DaemonEvents.online, data: data)
    }

    /// 发送 daemon:offline 事件
    private func emitDaemonOffline() {
        guard isConnected else { return }

        let config = VlaudeConfigManager.shared.config
        let data: [String: Any] = [
            "deviceId": config.deviceId
        ]

        try? socketBridge?.emit(event: DaemonEvents.offline, data: data)
    }

    /// 发送 daemon:sessionStart 事件
    func emitSessionStart(sessionId: String, projectPath: String, terminalId: Int) {
        // 记录到 openSessions（用于重连上报）
        openSessions[sessionId] = (projectPath: projectPath, terminalId: terminalId)

        guard isConnected else { return }

        let config = VlaudeConfigManager.shared.config
        let data: [String: Any] = [
            "deviceId": config.deviceId,
            "sessionId": sessionId,
            "projectPath": projectPath,
            "terminalId": terminalId
        ]

        try? socketBridge?.emit(event: DaemonEvents.sessionStart, data: data)
    }

    /// 发送 daemon:sessionEnd 事件
    func emitSessionEnd(sessionId: String) {
        // 从 openSessions 移除
        openSessions.removeValue(forKey: sessionId)

        guard isConnected else { return }

        let config = VlaudeConfigManager.shared.config
        let data: [String: Any] = [
            "deviceId": config.deviceId,
            "sessionId": sessionId
        ]

        try? socketBridge?.emit(event: DaemonEvents.sessionEnd, data: data)
    }

    /// 发送 daemon:heartbeat 事件
    func emitHeartbeat() {
        guard isConnected else {
            reconnect()
            return
        }

        let config = VlaudeConfigManager.shared.config
        let data: [String: Any] = [
            "deviceId": config.deviceId
        ]

        do {
            try socketBridge?.emit(event: DaemonEvents.heartbeat, data: data)
        } catch {
            reconnect()
        }
    }

    /// 启动心跳定时器
    private func startHeartbeatTimer() {
        stopHeartbeatTimer()

        // 在主线程创建定时器
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: self.heartbeatInterval, repeats: true) { [weak self] _ in
                self?.emitHeartbeat()
            }
            // 确保定时器在 RunLoop 中运行
            if let timer = self.heartbeatTimer {
                RunLoop.current.add(timer, forMode: .common)
            }
        }
    }

    /// 停止心跳定时器
    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// 重连时重新上报所有 session（按架构文档 7.3 节）
    private func reportAllSessionsOnReconnect() {
        guard isConnected else { return }

        // 先发送 daemon:online
        emitDaemonOnline()

        // 再上报所有当前打开的 session
        let config = VlaudeConfigManager.shared.config
        for (sessionId, info) in openSessions {
            let data: [String: Any] = [
                "deviceId": config.deviceId,
                "sessionId": sessionId,
                "projectPath": info.projectPath,
                "terminalId": info.terminalId
            ]
            try? socketBridge?.emit(event: DaemonEvents.sessionStart, data: data)
        }
    }

    /// 通知会话列表更新（保留：iOS 需要刷新列表）
    private func notifySessionListUpdate(projectPath: String) {
        guard isConnected, !projectPath.isEmpty else { return }
        try? socketBridge?.notifySessionListUpdate(projectPath: projectPath)
    }

    /// 释放 SharedDbBridge（线程安全）
    private func releaseSharedDb() {
        guard let db = sharedDb else { return }
        try? db.release()
        sharedDb = nil
    }

    // MARK: - SocketClientBridgeDelegate

    func socketClientDidConnect(_ bridge: SocketClientBridge) {
        isConnected = true

        // 发送注册
        try? socketBridge?.register(hostname: deviceName, platform: "darwin", version: "1.0.0")

        // 新架构：发送 daemon:online 事件（替代 reportOnline）
        reportAllSessionsOnReconnect()

        // Bug #1 修复：启动心跳定时器
        startHeartbeatTimer()

        delegate?.vlaudeClientDidConnect(self)
    }

    func socketClientDidDisconnect(_ bridge: SocketClientBridge) {
        isConnected = false
        // Bug #1 修复：停止心跳定时器
        stopHeartbeatTimer()
        delegate?.vlaudeClientDidDisconnect(self)
    }

    func socketClient(_ bridge: SocketClientBridge, didReceiveEvent event: String, data: [String: Any]) {
        switch event {
        case "server-shutdown":
            isConnected = false

        case ServerEvents.injectToEterm:
            guard let sessionId = data["sessionId"] as? String,
                  let text = data["text"] as? String else { return }
            let clientMessageId = data["clientMessageId"] as? String
            delegate?.vlaudeClient(self, didReceiveInject: sessionId, text: text, clientMessageId: clientMessageId)

        case ServerEvents.mobileViewing:
            guard let sessionId = data["sessionId"] as? String,
                  let isViewing = data["isViewing"] as? Bool else { return }
            delegate?.vlaudeClient(self, didReceiveMobileViewing: sessionId, isViewing: isViewing)

        case ServerEvents.createSessionInEterm:
            guard let projectPath = data["projectPath"] as? String else { return }
            let prompt = data["prompt"] as? String
            let requestId = data["requestId"] as? String
            delegate?.vlaudeClient(self, didReceiveCreateSession: projectPath, prompt: prompt, requestId: requestId)

        case ServerEvents.createSession:
            guard let projectPath = data["projectPath"] as? String,
                  let requestId = data["requestId"] as? String else { return }
            let prompt = data["prompt"] as? String
            delegate?.vlaudeClient(self, didReceiveCreateSessionNew: projectPath, prompt: prompt, requestId: requestId)

        case ServerEvents.sendMessage:
            guard let sessionId = data["sessionId"] as? String,
                  let text = data["text"] as? String,
                  let requestId = data["requestId"] as? String else { return }
            let projectPath = data["projectPath"] as? String
            let clientId = data["clientId"] as? String
            delegate?.vlaudeClient(self, didReceiveSendMessage: sessionId, text: text, projectPath: projectPath, clientId: clientId, requestId: requestId)

        case ServerEvents.checkLoading:
            guard let sessionId = data["sessionId"] as? String,
                  let requestId = data["requestId"] as? String else { return }
            let projectPath = data["projectPath"] as? String
            delegate?.vlaudeClient(self, didReceiveCheckLoading: sessionId, projectPath: projectPath, requestId: requestId)

        case ServerEvents.requestProjectData:
            handleRequestProjectData(data)

        case ServerEvents.requestSessionMetadata:
            handleRequestSessionMetadata(data)

        case ServerEvents.requestSessionMessages:
            handleRequestSessionMessages(data)

        case ServerEvents.requestSearch:
            handleRequestSearch(data)

        case ServerEvents.permissionResponse:
            guard let sessionId = (data["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let action = data["action"] as? String else { return }
            let toolUseId = data["toolUseId"] as? String ?? ""
            delegate?.vlaudeClient(self, didReceivePermissionResponse: sessionId, action: action, toolUseId: toolUseId)

        default:
            break
        }
    }

    func socketClientDidReconnect(_ bridge: SocketClientBridge) {
        isConnected = true

        // 发送注册
        try? socketBridge?.register(hostname: deviceName, platform: "darwin", version: "1.0.0")

        // 新架构：重连时重新上报所有状态（按架构文档 7.3 节）
        reportAllSessionsOnReconnect()

        // Bug #1 修复：启动心跳定时器
        startHeartbeatTimer()

        delegate?.vlaudeClientDidConnect(self)
    }

    func socketClient(_ bridge: SocketClientBridge, reconnectFailed error: String) {
        // Keep isConnected = false, wait for next server online event
    }

    // MARK: - V3 Write Operation Results

    /// 响应 createSession 结果
    func emitSessionCreatedResult(
        requestId: String,
        success: Bool,
        sessionId: String? = nil,
        encodedDirName: String? = nil,
        transcriptPath: String? = nil,
        error: String? = nil
    ) {
        guard isConnected else { return }

        try? socketBridge?.sendSessionCreatedResult(
            requestId: requestId,
            success: success,
            sessionId: sessionId,
            encodedDirName: encodedDirName,
            transcriptPath: transcriptPath,
            error: error
        )
    }

    /// 响应 sendMessage 结果
    func emitSendMessageResult(
        requestId: String,
        success: Bool,
        message: String? = nil,
        via: String? = nil
    ) {
        guard isConnected else { return }
        try? socketBridge?.sendMessageResult(requestId: requestId, success: success, message: message, via: via)
    }

    /// 响应 checkLoading 结果
    func emitCheckLoadingResult(requestId: String, loading: Bool) {
        guard isConnected else { return }
        try? socketBridge?.sendCheckLoadingResult(requestId: requestId, loading: loading)
    }

    /// 发送权限请求到 iOS
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - terminalId: 终端 ID
    ///   - message: 权限请求消息（可选）
    ///   - toolUse: 工具详情（包含 name, input, id）
    func emitPermissionRequest(
        sessionId: String,
        terminalId: Int,
        message: String?,
        toolUse: [String: Any]? = nil
    ) {
        guard isConnected else { return }

        // 生成唯一请求 ID
        let requestId = UUID().uuidString

        // 从 toolUse 中提取字段（匹配 Server/iOS 期望的格式）
        let toolName = toolUse?["name"] as? String ?? "Unknown"
        let toolInput = toolUse?["input"] as? [String: Any] ?? [:]
        let toolUseId = toolUse?["id"] as? String ?? ""

        // 构建 description（显示在 iOS 上的内容）
        var description = toolName
        if let command = toolInput["command"] as? String {
            // Bash 工具：显示命令
            description = "\(toolName): \(command)"
        } else if let filePath = toolInput["file_path"] as? String {
            // 文件操作工具：显示路径
            description = "\(toolName): \(filePath)"
        } else if let pattern = toolInput["pattern"] as? String {
            // 搜索工具：显示模式
            description = "\(toolName): \(pattern)"
        }

        let data: [String: Any] = [
            "requestId": requestId,
            "sessionId": sessionId,
            "terminalId": terminalId,
            "toolName": toolName,
            "input": toolInput,
            "toolUseID": toolUseId,
            "description": description,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        try? socketBridge?.emit(event: DaemonEvents.permissionRequest, data: data)
    }

    /// 发送审批确认到 Server（转发给 iOS）
    /// - Parameters:
    ///   - toolUseId: 工具调用 ID
    ///   - sessionId: 会话 ID
    ///   - success: 是否成功写入终端
    ///   - message: 可选的消息
    func emitApprovalAck(toolUseId: String, sessionId: String, success: Bool, message: String? = nil) {
        guard isConnected else { return }

        let data: [String: Any] = [
            "toolUseId": toolUseId,
            "sessionId": sessionId,
            "success": success,
            "message": message ?? (success ? "已写入终端" : "写入失败"),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        try? socketBridge?.emit(event: DaemonEvents.approvalAck, data: data)
    }

    // MARK: - Connection Test

    /// 测试连接（用于设置页面）
    static func testConnection(
        config: VlaudeConfig,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            let redisConfig = RedisConfig(
                host: config.redisHost,
                port: config.redisPort,
                password: config.redisPassword
            )

            let daemonConfig = DaemonConfig(
                deviceId: config.deviceId + "-test",
                deviceName: config.deviceName,
                platform: "darwin",
                version: "1.0.0",
                ttl: 30
            )

            let bridge = try SocketClientBridge(
                url: config.serverURL.isEmpty ? "https://localhost:10005" : config.serverURL,
                namespace: "/daemon",
                redis: redisConfig,
                daemon: daemonConfig
            )

            var completed = false

            // 创建临时 delegate 处理连接结果
            class TestDelegate: SocketClientBridgeDelegate {
                var onConnect: (() -> Void)?
                var onDisconnect: (() -> Void)?

                func socketClientDidConnect(_ bridge: SocketClientBridge) {
                    onConnect?()
                }

                func socketClientDidDisconnect(_ bridge: SocketClientBridge) {
                    onDisconnect?()
                }

                func socketClient(_ bridge: SocketClientBridge, didReceiveEvent event: String, data: [String: Any]) {}

                func socketClientDidReconnect(_ bridge: SocketClientBridge) {}

                func socketClient(_ bridge: SocketClientBridge, reconnectFailed error: String) {}
            }

            let testDelegate = TestDelegate()

            // 注意：闭包需要强引用 bridge 和 testDelegate，防止被 ARC 提前释放
            // 因为 bridge.delegate 是 weak 引用，且回调是异步的
            testDelegate.onConnect = { [bridge, testDelegate] in
                _ = testDelegate // 防止 unused 警告，保持强引用
                guard !completed else { return }
                completed = true
                bridge.disconnect()
                completion(.success("Connected successfully"))
            }

            // 设置超时
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [bridge, testDelegate] in
                _ = testDelegate // 防止 unused 警告，保持强引用
                guard !completed else { return }
                completed = true
                bridge.disconnect()
                completion(.failure(NSError(domain: "VlaudeClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Connection timeout"])))
            }

            bridge.delegate = testDelegate
            try bridge.connect()

        } catch {
            completion(.failure(NSError(domain: "VlaudeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection failed: \(error.localizedDescription)"])))
        }
    }

    // MARK: - Data Request Handlers

    /// 处理项目列表请求
    private func handleRequestProjectData(_ data: [String: Any]) {
        let requestId = data["requestId"] as? String
        let limit = UInt32((data["limit"] as? Int) ?? 1000)
        let offset = UInt32((data["offset"] as? Int) ?? 0)

        guard let projects = vlaudeFfi.listProjectsLegacy(limit: limit, offset: offset) else {
            return
        }

        reportProjectData(projects: projects, requestId: requestId)
    }

    /// 处理会话列表请求
    private func handleRequestSessionMetadata(_ data: [String: Any]) {
        guard let projectPath = data["projectPath"] as? String else {
            return
        }
        let requestId = data["requestId"] as? String
        let limit = UInt32((data["limit"] as? Int) ?? 1000)
        let offset = UInt32((data["offset"] as? Int) ?? 0)

        guard let sessions = vlaudeFfi.listSessionsLegacy(projectPath: projectPath, limit: limit, offset: offset) else {
            return
        }

        reportSessionMetadata(sessions: sessions, projectPath: projectPath, requestId: requestId)
    }

    /// 处理会话消息请求
    private func handleRequestSessionMessages(_ data: [String: Any]) {
        guard let sessionId = data["sessionId"] as? String,
              let projectPath = data["projectPath"] as? String else {
            return
        }

        let limit = (data["limit"] as? Int) ?? 50
        let offset = (data["offset"] as? Int) ?? 0
        let requestId = data["requestId"] as? String

        guard let result = vlaudeFfi.getMessagesLegacy(sessionId: sessionId, limit: UInt32(limit), offset: UInt32(offset)) else {
            // 发送空响应避免超时
            reportSessionMessages(
                sessionId: sessionId,
                projectPath: projectPath,
                messages: [],
                total: 0,
                hasMore: false,
                requestId: requestId
            )
            return
        }

        reportSessionMessages(
            sessionId: sessionId,
            projectPath: projectPath,
            messages: result.messages,
            total: result.total,
            hasMore: result.hasMore,
            requestId: requestId
        )
    }

    /// 处理搜索请求（需要 SharedDb）
    private func handleRequestSearch(_ data: [String: Any]) {
        guard let query = data["query"] as? String else {
            return
        }

        // Validate limit: clamp to 1-100 range to prevent UInt overflow
        let rawLimit = (data["limit"] as? Int) ?? 20
        let limit = max(1, min(rawLimit, 100))
        let projectId = data["projectId"] as? Int64
        let requestId = data["requestId"] as? String

        guard let sharedDb = sharedDb else {
            reportSearchResults(results: [], query: query, requestId: requestId, error: "Search not available")
            return
        }

        do {
            let results: [SharedSearchResult]
            if let pid = projectId {
                results = try sharedDb.search(query: query, projectId: pid, limit: limit)
            } else {
                results = try sharedDb.search(query: query, limit: limit)
            }
            reportSearchResults(results: results, query: query, requestId: requestId, error: nil)
        } catch {
            reportSearchResults(results: [], query: query, requestId: requestId, error: error.localizedDescription)
        }
    }

    // MARK: - Data Reports (VlaudeKit → Server)

    /// 上报项目数据
    private func reportProjectData(projects: [ProjectInfo], requestId: String?) {
        guard isConnected else { return }

        let projectsData: [[String: Any]] = projects.map { project in
            [
                "projectPath": project.path,
                "name": project.name,
                "sessionCount": project.sessionCount,
                "lastActive": project.lastActive as Any
            ]
        }

        try? socketBridge?.reportProjectData(projects: projectsData, requestId: requestId)
    }

    /// 上报会话元数据
    private func reportSessionMetadata(sessions: [SessionMeta], projectPath: String?, requestId: String?) {
        guard isConnected else { return }

        let sessionsData: [[String: Any]] = sessions.map { session in
            var dict: [String: Any] = [
                "id": session.id,
                "projectPath": session.projectPath
            ]
            if let path = session.sessionPath { dict["path"] = path }
            if let name = session.projectName { dict["projectName"] = name }
            if let encoded = session.encodedDirName { dict["encodedDirName"] = encoded }
            if let modified = session.lastModified { dict["lastModified"] = modified }
            if let count = session.messageCount { dict["messageCount"] = count }
            return dict
        }

        try? socketBridge?.reportSessionMetadata(sessions: sessionsData, projectPath: projectPath, requestId: requestId)
    }

    /// 上报会话消息
    private func reportSessionMessages(
        sessionId: String,
        projectPath: String,
        messages: [RawMessage],
        total: Int,
        hasMore: Bool,
        requestId: String?
    ) {
        guard isConnected else { return }

        // 将 RawMessage 转换为字典格式
        let messagesData: [[String: Any]] = messages.compactMap { msg in
            var dict: [String: Any] = [
                "uuid": msg.uuid
            ]
            if let type = msg.type { dict["type"] = type }
            if let timestamp = msg.timestamp { dict["timestamp"] = timestamp }
            if let message = msg.message {
                var msgDict: [String: Any] = [:]
                if let role = message.role { msgDict["role"] = role }
                if let content = message.content { msgDict["content"] = content.value }
                dict["message"] = msgDict
            }

            // 使用 FFI 返回的 contentBlocks（已在 Rust 层解析）
            if let blocks = msg.contentBlocks {
                dict["contentBlocks"] = blocks
            }

            return dict
        }

        try? socketBridge?.reportSessionMessages(
            sessionId: sessionId,
            projectPath: projectPath,
            messages: messagesData,
            total: total,
            hasMore: hasMore,
            requestId: requestId
        )
    }

    /// 上报搜索结果
    private func reportSearchResults(results: [SharedSearchResult], query: String, requestId: String?, error: String?) {
        guard isConnected else { return }

        var data: [String: Any] = [
            "query": query,
            "results": results.map { result in
                var dict: [String: Any] = [
                    "messageId": result.messageId,
                    "sessionId": result.sessionId,
                    "projectId": result.projectId,
                    "projectName": result.projectName,
                    "role": result.role,
                    "content": result.content,
                    "snippet": result.snippet,
                    "score": result.score
                ]
                if let ts = result.timestamp {
                    dict["timestamp"] = ts
                }
                return dict
            },
            "count": results.count
        ]

        if let requestId = requestId {
            data["requestId"] = requestId
        }

        if let error = error {
            data["error"] = error
        }

        try? socketBridge?.emit(event: DaemonEvents.searchResults, data: data)
    }

    // MARK: - Real-time Message Push

    /// 推送单条消息给 Server（由 SessionWatcher 调用）
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - message: 消息
    ///   - contentBlocks: 结构化内容块（可选）
    ///   - clientMessageId: 客户端消息 ID（用于去重，可选）
    func pushMessage(sessionId: String, message: RawMessage, contentBlocks: [ContentBlock]? = nil, clientMessageId: String? = nil) {
        guard isConnected else { return }

        // 转换消息格式
        var msgDict: [String: Any] = [
            "uuid": message.uuid
        ]
        if let type = message.type { msgDict["type"] = type }
        if let timestamp = message.timestamp { msgDict["timestamp"] = timestamp }
        if let msg = message.message {
            var innerDict: [String: Any] = [:]
            if let role = msg.role { innerDict["role"] = role }
            if let content = msg.content { innerDict["content"] = content.value }
            msgDict["message"] = innerDict
        }

        // 添加 clientMessageId（用于 iOS 乐观更新去重）
        if let clientMsgId = clientMessageId {
            msgDict["clientMessageId"] = clientMsgId
        }

        // 添加结构化内容块
        if let blocks = contentBlocks {
            msgDict["contentBlocks"] = blocks.map { block -> [String: Any] in
                switch block {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .toolUse(let tool):
                    return [
                        "type": "tool_use",
                        "id": tool.id,
                        "name": tool.name,
                        "displayText": tool.displayText,
                        "iconName": tool.iconName,
                        "input": tool.input
                    ]
                case .toolResult(let result):
                    return [
                        "type": "tool_result",
                        "toolUseId": result.toolUseId,
                        "isError": result.isError,
                        "preview": result.preview,
                        "hasMore": result.hasMore,
                        "sizeDescription": result.sizeDescription,
                        "content": result.content
                    ]
                case .thinking(let text):
                    return ["type": "thinking", "thinking": text]
                case .unknown(let raw):
                    return ["type": "unknown", "raw": raw]
                }
            }
        }

        try? socketBridge?.notifyNewMessage(sessionId: sessionId, message: msgDict)
    }

    /// 推送新消息给 Server（让 iOS 实时看到）
    /// 注意：此方法已被 SessionWatcher + pushMessage 替代，保留用于兼容
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - transcriptPath: JSONL 文件路径
    func pushNewMessages(sessionId: String, transcriptPath: String) {
        guard isConnected else { return }

        // 读取最新的消息（倒序取最后一条）
        guard let result = sessionReader.readMessages(
            sessionPath: transcriptPath,
            limit: 1,
            offset: 0,
            orderAsc: false
        ), !result.messages.isEmpty else { return }

        // 转换消息格式
        let message = result.messages[0]
        var msgDict: [String: Any] = [
            "uuid": message.uuid
        ]
        if let type = message.type { msgDict["type"] = type }
        if let timestamp = message.timestamp { msgDict["timestamp"] = timestamp }
        if let msg = message.message {
            var innerDict: [String: Any] = [:]
            if let role = msg.role { innerDict["role"] = role }
            if let content = msg.content { innerDict["content"] = content.value }
            msgDict["message"] = innerDict
        }

        try? socketBridge?.notifyNewMessage(sessionId: sessionId, message: msgDict)
    }

    /// 推送初始数据（连接成功后调用）
    /// 注意：新架构下，状态上报由 reportAllSessionsOnReconnect() 处理
    /// 此方法保留为空，兼容旧代码
    func pushInitialData() {
        // 新架构：状态上报已移至 reportAllSessionsOnReconnect()
        // 历史数据由 Rust daemon 负责推送
    }

    // MARK: - SharedDb Write Operations

    /// 索引会话到 SharedDb（当收到 aicli.responseComplete 事件时调用）
    /// 使用 session-reader-ffi 正确解析路径（支持中文路径）
    /// - Parameter path: JSONL 会话文件路径
    func indexSession(path: String) {
        guard let sharedDb = sharedDb else { return }

        // 检查是否为 Writer，如果不是尝试接管
        if sharedDb.role != .writer {
            do {
                let health = try sharedDb.checkWriterHealth()
                if health == .timeout || health == .released {
                    guard try sharedDb.tryTakeover() else { return }
                } else {
                    return
                }
            } catch {
                return
            }
        }

        // 使用 session-reader-ffi 解析会话
        guard let session = sessionReader.parseSessionForIndex(jsonlPath: path) else { return }

        // 转换消息格式
        let messages = session.messages.map { msg in
            MessageInput(
                uuid: msg.uuid,
                role: msg.role,
                content: msg.content,
                timestamp: msg.timestamp,
                sequence: msg.sequence
            )
        }

        // 写入数据库
        do {
            let projectId = try sharedDb.upsertProject(
                path: session.projectPath,
                name: session.projectName,
                source: "claude-code"
            )
            try sharedDb.upsertSession(sessionId: session.sessionId, projectId: projectId)
            _ = try sharedDb.insertMessages(sessionId: session.sessionId, messages: messages)
        } catch {
            // Silently fail - indexing is best-effort
        }
    }
}
