//
//  VlaudeClient.swift
//  VlaudeKit
//
//  Socket 客户端 - 通过 ETermKit 的 SocketService 连接 vlaude-server
//
//  协议：伪装为 daemon，复用现有的 daemon 协议
//

import Foundation
import ETermKit

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

final class VlaudeClient {
    weak var delegate: VlaudeClientDelegate?

    private var socket: SocketClientProtocol?
    private(set) var isConnected = false

    private var serverURL: URL?
    private var deviceName: String = "Mac"

    /// Socket 服务（由主应用通过 HostBridge 提供）
    private weak var socketService: SocketServiceProtocol?

    /// Session 读取器（FFI）
    private lazy var sessionReader = SessionReader()

    /// 共享数据库桥接（可选，用于缓存查询和搜索）
    private var sharedDb: SharedDbBridge?

    // MARK: - Init

    init(socketService: SocketServiceProtocol?) {
        self.socketService = socketService
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

    /// 连接到服务器
    /// - Parameters:
    ///   - urlString: 服务器地址（如 http://nas:3000）
    ///   - deviceName: 设备名称
    func connect(to urlString: String, deviceName: String) {
        guard let socketService = socketService else {
            print("[VlaudeClient] SocketService not available")
            return
        }

        guard let url = URL(string: urlString) else {
            print("[VlaudeClient] Invalid URL: \(urlString)")
            return
        }

        // 如果已连接到同一地址且设备名相同，不重复连接
        if isConnected, serverURL == url, self.deviceName == deviceName {
            return
        }

        // 断开旧连接
        disconnect()

        // 确保 SharedDb 已初始化（可能之前被 disconnect() 释放）
        if sharedDb == nil {
            initSharedDb()
        }

        self.serverURL = url
        self.deviceName = deviceName

        // 创建 Socket 客户端配置
        var config = SocketClientConfig()
        config.reconnects = true
        config.reconnectWait = 5
        config.reconnectAttempts = -1  // 无限重试
        config.forceWebsockets = true
        config.compress = true
        config.log = false

        // 通过 SocketService 创建客户端
        socket = socketService.createClient(
            url: url,
            namespace: "/daemon",
            config: config
        )

        setupEventHandlers()

        print("[VlaudeClient] Connecting to \(urlString)/daemon")
        socket?.connect()
    }

    /// 断开连接
    func disconnect() {
        if isConnected {
            // 发送离线通知
            reportOffline()
        }

        socket?.disconnect()
        socket = nil
        isConnected = false
        serverURL = nil

        // 释放 SharedDbBridge Writer（确保 daemon 能接管）
        releaseSharedDb()
    }

    /// 释放 SharedDbBridge（线程安全）
    private func releaseSharedDb() {
        guard let db = sharedDb else { return }
        try? db.release()
        sharedDb = nil
    }

    // MARK: - Connection Handling

    /// 处理连接成功（首次连接或重连）
    private func handleConnected() {
        isConnected = true

        // 发送注册和上线通知
        register()
        reportOnline()

        // 推送初始数据
        pushInitialData()

        // 通知 delegate
        delegate?.vlaudeClientDidConnect(self)
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        // 先移除旧的事件处理器，避免重复注册
        socket.offAll()

        // 连接成功
        socket.onClientEvent(.connect) { [weak self] in
            guard let self = self else { return }
            print("[VlaudeKit] Socket connected")
            self.handleConnected()
        }

        // 重连成功（关键：服务器重启后会触发这个事件）
        socket.onClientEvent(.reconnect) { [weak self] in
            guard let self = self else { return }
            print("[VlaudeKit] Socket reconnected")
            self.handleConnected()
        }

        // 重连尝试
        socket.onClientEvent(.reconnectAttempt) { [weak self] in
            guard self != nil else { return }
            print("[VlaudeKit] Reconnect attempt...")
        }

        // 断开连接
        socket.onClientEvent(.disconnect) { [weak self] in
            guard let self = self else { return }
            print("[VlaudeKit] Socket disconnected")
            self.isConnected = false
            self.delegate?.vlaudeClientDidDisconnect(self)
        }

        // 连接错误
        socket.onClientEvent(.error) { [weak self] in
            guard self != nil else { return }
            print("[VlaudeKit] Socket error")
        }

        // 服务器关闭通知
        socket.on("server-shutdown") { [weak self] _ in
            print("[VlaudeKit] Server shutdown notification")
            self?.isConnected = false
        }

        // 注入请求
        socket.on("server:injectToEterm") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let text = dict["text"] as? String else {
                return
            }
            self.delegate?.vlaudeClient(self, didReceiveInject: sessionId, text: text)
        }

        // Mobile 查看状态
        socket.on("server:mobileViewing") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let isViewing = dict["isViewing"] as? Bool else {
                return
            }
            self.delegate?.vlaudeClient(self, didReceiveMobileViewing: sessionId, isViewing: isViewing)
        }

        // 创建会话请求（旧方式）
        socket.on("server:createSessionInEterm") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let projectPath = dict["projectPath"] as? String else {
                return
            }

            let prompt = dict["prompt"] as? String
            let requestId = dict["requestId"] as? String
            self.delegate?.vlaudeClient(self, didReceiveCreateSession: projectPath, prompt: prompt, requestId: requestId)
        }

        // MARK: - 新 WebSocket 事件（统一接口）

        // 创建会话请求（新方式）
        socket.on("server:createSession") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let projectPath = dict["projectPath"] as? String,
                  let requestId = dict["requestId"] as? String else {
                return
            }

            let prompt = dict["prompt"] as? String
            self.delegate?.vlaudeClient(self, didReceiveCreateSessionNew: projectPath, prompt: prompt, requestId: requestId)
        }

        // 发送消息请求
        socket.on("server:sendMessage") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let text = dict["text"] as? String,
                  let requestId = dict["requestId"] as? String else {
                return
            }

            let projectPath = dict["projectPath"] as? String
            let clientId = dict["clientId"] as? String
            self.delegate?.vlaudeClient(self, didReceiveSendMessage: sessionId, text: text, projectPath: projectPath, clientId: clientId, requestId: requestId)
        }

        // 检查 loading 状态请求
        socket.on("server:checkLoading") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let requestId = dict["requestId"] as? String else {
                return
            }

            let projectPath = dict["projectPath"] as? String
            self.delegate?.vlaudeClient(self, didReceiveCheckLoading: sessionId, projectPath: projectPath, requestId: requestId)
        }

        // 数据请求：项目列表
        socket.on("server:requestProjectData") { [weak self] data in
            guard let self = self else { return }
            let dict = data.first as? [String: Any] ?? [:]
            self.handleRequestProjectData(dict)
        }

        // 数据请求：会话列表
        socket.on("server:requestSessionMetadata") { [weak self] data in
            guard let self = self else { return }
            let dict = data.first as? [String: Any] ?? [:]
            self.handleRequestSessionMetadata(dict)
        }

        // 数据请求：会话消息
        socket.on("server:requestSessionMessages") { [weak self] data in
            guard let self = self else { return }
            let dict = data.first as? [String: Any] ?? [:]
            self.handleRequestSessionMessages(dict)
        }

        // 数据请求：全文搜索（需要 SharedDb）
        socket.on("server:requestSearch") { [weak self] data in
            guard let self = self else { return }
            let dict = data.first as? [String: Any] ?? [:]
            self.handleRequestSearch(dict)
        }
    }

    // MARK: - Uplink Events (VlaudeKit → Server)

    /// 注册
    /// 注意：使用普通 emit，不等待 ACK（与 Rust daemon 保持一致）
    private func register() {
        let data: [String: Any] = [
            "hostname": deviceName,
            "platform": "darwin",
            "version": "1.0.0"
        ]
        print("[VlaudeKit] 📤 发送 daemon:register hostname=\(deviceName)")
        socket?.emit("daemon:register", data)
    }

    /// 上线通知
    private func reportOnline() {
        let data: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        print("[VlaudeKit] 📤 发送 daemon:etermOnline")
        socket?.emit("daemon:etermOnline", data)
    }

    /// 离线通知
    private func reportOffline() {
        guard isConnected else { return }

        let data: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        socket?.emit("daemon:etermOffline", data)
    }

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
        socket?.emit("daemon:etermSessionAvailable", data)
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

        socket?.emit("daemon:etermSessionUnavailable", data)
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

        socket?.emit("daemon:etermSessionCreated", data)
    }

    // MARK: - 新 WebSocket 响应（统一接口）

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

        var data: [String: Any] = [
            "requestId": requestId,
            "success": success
        ]
        if let sessionId = sessionId { data["sessionId"] = sessionId }
        if let encodedDirName = encodedDirName { data["encodedDirName"] = encodedDirName }
        if let transcriptPath = transcriptPath { data["transcriptPath"] = transcriptPath }
        if let error = error { data["error"] = error }

        socket?.emit("daemon:sessionCreatedResult", data)
    }

    /// 响应 sendMessage 结果
    func emitSendMessageResult(
        requestId: String,
        success: Bool,
        message: String? = nil,
        via: String? = nil
    ) {
        guard isConnected else { return }

        var data: [String: Any] = [
            "requestId": requestId,
            "success": success
        ]
        if let message = message { data["message"] = message }
        if let via = via { data["via"] = via }

        socket?.emit("daemon:sendMessageResult", data)
    }

    /// 响应 checkLoading 结果
    func emitCheckLoadingResult(requestId: String, loading: Bool) {
        guard isConnected else { return }

        let data: [String: Any] = [
            "requestId": requestId,
            "loading": loading
        ]

        socket?.emit("daemon:checkLoadingResult", data)
    }

    // MARK: - Connection Test

    /// 测试连接（用于设置页面）
    static func testConnection(
        using socketService: SocketServiceProtocol?,
        to urlString: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let socketService = socketService else {
            completion(.failure(NSError(domain: "VlaudeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "SocketService not available"])))
            return
        }

        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "VlaudeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var config = SocketClientConfig()
        config.reconnects = false
        config.forceWebsockets = true
        config.log = false

        let socket = socketService.createClient(
            url: url,
            namespace: "/daemon",
            config: config
        )

        var completed = false

        // 设置超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard !completed else { return }
            completed = true
            socket.disconnect()
            completion(.failure(NSError(domain: "VlaudeClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Connection timeout"])))
        }

        socket.onClientEvent(.connect) {
            guard !completed else { return }
            completed = true
            socket.disconnect()
            completion(.success("Connected successfully"))
        }

        socket.onClientEvent(.error) {
            guard !completed else { return }
            completed = true
            socket.disconnect()
            completion(.failure(NSError(domain: "VlaudeClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Connection failed"])))
        }

        socket.connect()
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

        // 构建会话文件路径
        let encodedDir = SessionReader.encodePath(projectPath) ?? projectPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessionPath = "\(home)/.claude/projects/\(encodedDir)/\(sessionId).jsonl"

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

        var data: [String: Any] = [
            "projects": projects.map { project in
                let dict: [String: Any] = [
                    "path": project.path,
                    "encodedName": project.encodedName,
                    "name": project.name,
                    "sessionCount": project.sessionCount,
                    "lastModified": project.lastActive
                ]
                return dict
            }
        ]

        if let requestId = requestId {
            data["requestId"] = requestId
        }

        socket?.emit("daemon:projectData", data)
    }

    /// 上报会话元数据
    private func reportSessionMetadata(sessions: [SessionMeta], projectPath: String?, requestId: String?) {
        guard isConnected else { return }

        var data: [String: Any] = [
            "sessions": sessions.map { session in
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
        ]

        if let projectPath = projectPath {
            data["projectPath"] = projectPath
        }

        if let requestId = requestId {
            data["requestId"] = requestId
        }

        socket?.emit("daemon:sessionMetadata", data)
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
            return dict
        }

        var data: [String: Any] = [
            "sessionId": sessionId,
            "projectPath": projectPath,
            "messages": messagesData,
            "total": total,
            "hasMore": hasMore
        ]

        if let requestId = requestId {
            data["requestId"] = requestId
        }

        socket?.emit("daemon:sessionMessages", data)
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

        socket?.emit("daemon:searchResults", data)
    }

    // MARK: - Project Update

    /// 上报项目更新（当有新活动时通知服务器）
    /// - Parameter projectPath: 项目路径
    func reportProjectUpdate(projectPath: String) {
        guard isConnected else { return }

        let data: [String: Any] = [
            "projectPath": projectPath,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        print("[VlaudeKit] 📤 发送 daemon:projectUpdate projectPath=\(projectPath)")
        socket?.emit("daemon:projectUpdate", data)
    }

    // MARK: - Real-time Message Push

    /// 推送单条消息给 Server（由 SessionWatcher 调用）
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - message: 消息
    func pushMessage(sessionId: String, message: RawMessage) {
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

        let role = (msgDict["message"] as? [String: Any])?["role"] as? String ?? "unknown"
        print("[VlaudeKit] 📤 发送 daemon:newMessage sessionId=\(sessionId) role=\(role)")
        socket?.emit("daemon:newMessage", [
            "sessionId": sessionId,
            "message": msgDict
        ])
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
        socket?.emit("daemon:newMessage", [
            "sessionId": sessionId,
            "message": msgDict
        ])
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
