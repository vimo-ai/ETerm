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
    func vlaudeClient(_ client: VlaudeClient, didReceiveInject sessionId: String, text: String)

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
}

// MARK: - VlaudeClient

final class VlaudeClient: SocketClientBridgeDelegate {
    weak var delegate: VlaudeClientDelegate?

    /// Socket 桥接层（Rust FFI）
    private var socketBridge: SocketClientBridge?
    private(set) var isConnected = false

    private var serverURL: String?
    private var deviceName: String = "Mac"

    /// 是否使用 Redis 模式
    private var useRedisMode = false

    /// Session 读取器（FFI）
    private lazy var sessionReader = SessionReader()

    /// 共享数据库桥接（可选，用于缓存查询和搜索）
    private var sharedDb: SharedDbBridge?

    /// 当前活跃的 Session 列表（用于 Redis 更新）
    private var activeSessions: [String: String] = [:]  // sessionId -> projectPath

    // MARK: - Init

    init() {
        initSharedDb()
    }

    /// 初始化共享数据库（最佳努力）
    private func initSharedDb() {
        do {
            sharedDb = try SharedDbBridge()
            _ = try sharedDb?.register()
        } catch {
            sharedDb = nil
        }
    }

    // MARK: - Connection

    /// 连接到服务器（直连模式）
    /// - Parameters:
    ///   - urlString: 服务器地址（如 https://localhost:10005）
    ///   - deviceName: 设备名称
    func connect(to urlString: String, deviceName: String) {
        // 如果已连接到同一地址且设备名相同，不重复连接
        if isConnected, serverURL == urlString, self.deviceName == deviceName, !useRedisMode {
            return
        }

        // 断开旧连接
        disconnect()

        // 确保 SharedDb 已初始化（可能之前被 disconnect() 释放）
        if sharedDb == nil {
            initSharedDb()
        }

        self.serverURL = urlString
        self.deviceName = deviceName
        self.useRedisMode = false

        // 通过 Rust FFI 创建 Socket 客户端
        do {
            socketBridge = try SocketClientBridge(url: urlString, namespace: "/daemon")
            socketBridge?.delegate = self
            try socketBridge?.connect()
            print("[VlaudeClient] Connecting to \(urlString)/daemon (direct mode)")
        } catch {
            print("[VlaudeClient] Connection failed: \(error)")
        }
    }

    /// 连接到服务器（Redis 服务发现模式）
    /// - Parameters:
    ///   - config: VlaudeConfig 配置
    func connectWithRedis(config: VlaudeConfig) {
        // 断开旧连接
        disconnect()

        // 确保 SharedDb 已初始化
        if sharedDb == nil {
            initSharedDb()
        }

        self.serverURL = config.serverURL
        self.deviceName = config.deviceName
        self.useRedisMode = true

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
            try socketBridge?.connectWithDiscovery()
            print("[VlaudeClient] Connecting via Redis discovery (host=\(config.redisHost):\(config.redisPort))")
        } catch {
            print("[VlaudeClient] Redis connection failed: \(error)")
        }
    }

    /// 断开连接
    func disconnect() {
        if isConnected {
            // 发送离线通知
            try? socketBridge?.reportOffline()
        }

        socketBridge?.disconnect()
        socketBridge = nil
        isConnected = false
        serverURL = nil
        useRedisMode = false
        activeSessions.removeAll()

        // 释放 SharedDbBridge Writer（确保 daemon 能接管）
        releaseSharedDb()
    }

    // MARK: - Redis Session Tracking

    /// 添加活跃 Session（用于 Redis 模式）
    func addActiveSession(sessionId: String, projectPath: String) {
        activeSessions[sessionId] = projectPath
        syncSessionsToRedis()
    }

    /// 移除活跃 Session（用于 Redis 模式）
    func removeActiveSession(sessionId: String) {
        activeSessions.removeValue(forKey: sessionId)
        syncSessionsToRedis()
    }

    /// 同步 Session 列表到 Redis
    private func syncSessionsToRedis() {
        guard useRedisMode, isConnected else { return }

        let sessions = activeSessions.map { (sessionId, projectPath) in
            SessionInfo(sessionId: sessionId, projectPath: projectPath)
        }

        do {
            try socketBridge?.updateSessions(sessions)
            print("[VlaudeClient] Synced \(sessions.count) sessions to Redis")
        } catch {
            print("[VlaudeClient] Failed to sync sessions to Redis: \(error)")
        }
    }

    /// 释放 SharedDbBridge（线程安全）
    private func releaseSharedDb() {
        guard let db = sharedDb else { return }
        try? db.release()
        sharedDb = nil
    }

    // MARK: - SocketClientBridgeDelegate

    func socketClientDidConnect(_ bridge: SocketClientBridge) {
        print("[VlaudeKit] Socket connected")
        isConnected = true

        // 发送注册和上线通知
        do {
            try socketBridge?.register(hostname: deviceName, platform: "darwin", version: "1.0.0")
            print("[VlaudeKit] 📤 发送 daemon:register hostname=\(deviceName)")
            try socketBridge?.reportOnline()
            print("[VlaudeKit] 📤 发送 daemon:etermOnline")
        } catch {
            print("[VlaudeKit] Registration failed: \(error)")
        }

        // 推送初始数据
        pushInitialData()

        // 通知 delegate
        delegate?.vlaudeClientDidConnect(self)
    }

    func socketClientDidDisconnect(_ bridge: SocketClientBridge) {
        print("[VlaudeKit] Socket disconnected")
        isConnected = false
        delegate?.vlaudeClientDidDisconnect(self)
    }

    func socketClient(_ bridge: SocketClientBridge, didReceiveEvent event: String, data: [String: Any]) {
        switch event {
        case "server-shutdown":
            print("[VlaudeKit] Server shutdown notification")
            isConnected = false

        case ServerEvent.injectToEterm.rawValue:
            guard let sessionId = data["sessionId"] as? String,
                  let text = data["text"] as? String else { return }
            delegate?.vlaudeClient(self, didReceiveInject: sessionId, text: text)

        case ServerEvent.mobileViewing.rawValue:
            guard let sessionId = data["sessionId"] as? String,
                  let isViewing = data["isViewing"] as? Bool else { return }
            delegate?.vlaudeClient(self, didReceiveMobileViewing: sessionId, isViewing: isViewing)

        case ServerEvent.createSessionInEterm.rawValue:
            guard let projectPath = data["projectPath"] as? String else { return }
            let prompt = data["prompt"] as? String
            let requestId = data["requestId"] as? String
            delegate?.vlaudeClient(self, didReceiveCreateSession: projectPath, prompt: prompt, requestId: requestId)

        case ServerEvent.createSession.rawValue:
            guard let projectPath = data["projectPath"] as? String,
                  let requestId = data["requestId"] as? String else { return }
            let prompt = data["prompt"] as? String
            delegate?.vlaudeClient(self, didReceiveCreateSessionNew: projectPath, prompt: prompt, requestId: requestId)

        case ServerEvent.sendMessage.rawValue:
            guard let sessionId = data["sessionId"] as? String,
                  let text = data["text"] as? String,
                  let requestId = data["requestId"] as? String else { return }
            let projectPath = data["projectPath"] as? String
            let clientId = data["clientId"] as? String
            delegate?.vlaudeClient(self, didReceiveSendMessage: sessionId, text: text, projectPath: projectPath, clientId: clientId, requestId: requestId)

        case ServerEvent.checkLoading.rawValue:
            guard let sessionId = data["sessionId"] as? String,
                  let requestId = data["requestId"] as? String else { return }
            let projectPath = data["projectPath"] as? String
            delegate?.vlaudeClient(self, didReceiveCheckLoading: sessionId, projectPath: projectPath, requestId: requestId)

        case ServerEvent.requestProjectData.rawValue:
            handleRequestProjectData(data)

        case ServerEvent.requestSessionMetadata.rawValue:
            handleRequestSessionMetadata(data)

        case ServerEvent.requestSessionMessages.rawValue:
            handleRequestSessionMessages(data)

        case ServerEvent.requestSearch.rawValue:
            handleRequestSearch(data)

        default:
            break
        }
    }

    // MARK: - Uplink Events (VlaudeKit → Server)

    /// 上报 session 可用
    func reportSessionAvailable(sessionId: String, terminalId: Int, projectPath: String? = nil) {
        guard isConnected else {
            print("[VlaudeKit] ⚠️ reportSessionAvailable 跳过: 未连接")
            return
        }

        var data: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        if let path = projectPath {
            data["projectPath"] = path
        }

        print("[VlaudeKit] 📤 发送 daemon:etermSessionAvailable sessionId=\(sessionId)")
        try? socketBridge?.emit(event: "daemon:etermSessionAvailable", data: data)
    }

    /// 上报 session 不可用
    func reportSessionUnavailable(sessionId: String, projectPath: String? = nil) {
        guard isConnected else { return }

        var data: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        if let path = projectPath {
            data["projectPath"] = path
        }

        try? socketBridge?.emit(event: "daemon:etermSessionUnavailable", data: data)
    }

    /// 上报 session 创建完成（旧方式）
    func reportSessionCreated(requestId: String, sessionId: String, projectPath: String) {
        guard isConnected else { return }

        let data: [String: Any] = [
            "requestId": requestId,
            "sessionId": sessionId,
            "projectPath": projectPath,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        try? socketBridge?.emit(event: "daemon:etermSessionCreated", data: data)
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

        do {
            try socketBridge?.sendSessionCreatedResult(
                requestId: requestId,
                success: success,
                sessionId: sessionId,
                encodedDirName: encodedDirName,
                transcriptPath: transcriptPath,
                error: error
            )
        } catch {
            print("[VlaudeKit] sendSessionCreatedResult failed: \(error)")
        }
    }

    /// 响应 sendMessage 结果
    func emitSendMessageResult(
        requestId: String,
        success: Bool,
        message: String? = nil,
        via: String? = nil
    ) {
        guard isConnected else { return }

        do {
            try socketBridge?.sendMessageResult(requestId: requestId, success: success, message: message, via: via)
        } catch {
            print("[VlaudeKit] sendMessageResult failed: \(error)")
        }
    }

    /// 响应 checkLoading 结果
    func emitCheckLoadingResult(requestId: String, loading: Bool) {
        guard isConnected else { return }

        do {
            try socketBridge?.sendCheckLoadingResult(requestId: requestId, loading: loading)
        } catch {
            print("[VlaudeKit] sendCheckLoadingResult failed: \(error)")
        }
    }

    // MARK: - Connection Test

    /// 测试连接（用于设置页面）
    static func testConnection(
        to urlString: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            let bridge = try SocketClientBridge(url: urlString, namespace: "/daemon")

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
        let limit = (data["limit"] as? Int) ?? 0
        let requestId = data["requestId"] as? String

        guard let projects = sessionReader.listProjects(limit: UInt32(limit)) else {
            return
        }

        reportProjectData(projects: projects, requestId: requestId)
    }

    /// 处理会话列表请求
    private func handleRequestSessionMetadata(_ data: [String: Any]) {
        let projectPath = data["projectPath"] as? String
        let requestId = data["requestId"] as? String

        guard let sessions = sessionReader.listSessions(projectPath: projectPath) else {
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
        let orderStr = (data["order"] as? String) ?? "asc"
        let requestId = data["requestId"] as? String

        // 获取会话文件路径
        guard let sessionPath = sessionReader.getSessionPath(sessionId: sessionId) else {
            print("[VlaudeClient] Session not found: \(sessionId)")
            return
        }

        guard let result = sessionReader.readMessages(
            sessionPath: sessionPath,
            limit: UInt32(limit),
            offset: UInt32(offset),
            orderAsc: orderStr == "asc"
        ) else {
            return
        }

        reportSessionMessages(
            sessionId: sessionId,
            projectPath: projectPath,
            messages: result.messages,
            total: result.total,
            hasMore: result.hasMore,
            requestId: requestId,
            transcriptPath: sessionPath
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
                "path": project.path,
                "encodedName": project.encodedName,
                "name": project.name,
                "sessionCount": project.sessionCount,
                "lastModified": project.lastActive
            ]
        }

        do {
            try socketBridge?.reportProjectData(projects: projectsData, requestId: requestId)
        } catch {
            print("[VlaudeKit] reportProjectData failed: \(error)")
        }
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
            return dict
        }

        do {
            try socketBridge?.reportSessionMetadata(sessions: sessionsData, projectPath: projectPath, requestId: requestId)
        } catch {
            print("[VlaudeKit] reportSessionMetadata failed: \(error)")
        }
    }

    /// 上报会话消息
    private func reportSessionMessages(
        sessionId: String,
        projectPath: String,
        messages: [RawMessage],
        total: Int,
        hasMore: Bool,
        requestId: String?,
        transcriptPath: String? = nil
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

            // 解析结构化内容块
            if let path = transcriptPath,
               let blocks = ContentBlockParser.readMessage(from: path, uuid: msg.uuid) {
                dict["contentBlocks"] = blocks.map { block -> [String: Any] in
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
                        return ["type": "thinking", "text": text]
                    case .unknown(let raw):
                        return ["type": "unknown", "raw": raw]
                    }
                }
            }

            return dict
        }

        do {
            try socketBridge?.reportSessionMessages(
                sessionId: sessionId,
                projectPath: projectPath,
                messages: messagesData,
                total: total,
                hasMore: hasMore,
                requestId: requestId
            )
        } catch {
            print("[VlaudeKit] reportSessionMessages failed: \(error)")
        }
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

        try? socketBridge?.emit(event: "daemon:searchResults", data: data)
    }

    // MARK: - Project Update

    /// 上报项目更新（当有新活动时通知服务器）
    /// - Parameter projectPath: 项目路径
    func reportProjectUpdate(projectPath: String) {
        guard isConnected else { return }

        print("[VlaudeKit] 📤 发送 daemon:projectUpdate projectPath=\(projectPath)")
        try? socketBridge?.notifyProjectUpdate(projectPath: projectPath, metadata: nil)
    }

    // MARK: - Real-time Message Push

    /// 推送单条消息给 Server（由 SessionWatcher 调用）
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - message: 消息
    ///   - contentBlocks: 结构化内容块（可选）
    func pushMessage(sessionId: String, message: RawMessage, contentBlocks: [ContentBlock]? = nil) {
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
                    return ["type": "thinking", "text": text]
                case .unknown(let raw):
                    return ["type": "unknown", "raw": raw]
                }
            }
        }

        let role = (msgDict["message"] as? [String: Any])?["role"] as? String ?? "unknown"
        print("[VlaudeKit] 📤 发送 daemon:newMessage sessionId=\(sessionId) role=\(role) blocks=\(contentBlocks?.count ?? 0)")
        try? socketBridge?.notifyNewMessage(sessionId: sessionId, message: msgDict)
    }

    /// 推送新消息给 Server（让 iOS 实时看到）
    /// 注意：此方法已被 SessionWatcher + pushMessage 替代，保留用于兼容
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - transcriptPath: JSONL 文件路径
    func pushNewMessages(sessionId: String, transcriptPath: String) {
        print("[VlaudeKit] 📨 pushNewMessages 被调用: sessionId=\(sessionId)")

        guard isConnected else {
            print("[VlaudeKit] ⚠️ pushNewMessages 跳过: 未连接")
            return
        }

        // 读取最新的消息（倒序取最后一条）
        guard let result = sessionReader.readMessages(
            sessionPath: transcriptPath,
            limit: 1,
            offset: 0,
            orderAsc: false
        ), !result.messages.isEmpty else {
            print("[VlaudeKit] ⚠️ pushNewMessages 跳过: 无法读取消息")
            return
        }

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

        // 推送给 Server
        let role = (msgDict["message"] as? [String: Any])?["role"] as? String ?? "unknown"
        print("[VlaudeKit] 📤 发送 daemon:newMessage sessionId=\(sessionId) role=\(role)")
        try? socketBridge?.notifyNewMessage(sessionId: sessionId, message: msgDict)
    }

    /// 推送初始数据（连接成功后调用）
    /// 注意：VlaudeKit 只负责报告 ETerm 中当前打开的会话，不推送历史数据
    /// 历史数据由 Rust daemon 负责推送
    func pushInitialData() {
        // No-op: ETerm sessions are reported individually
    }

    // MARK: - SharedDb Write Operations

    /// 索引会话到 SharedDb（当收到 claude.responseComplete 事件时调用）
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
