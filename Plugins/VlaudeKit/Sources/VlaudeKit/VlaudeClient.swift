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

    /// 收到注入请求
    func vlaudeClient(_ client: VlaudeClient, didReceiveInject sessionId: String, text: String)

    /// 收到 Mobile 查看状态
    func vlaudeClient(_ client: VlaudeClient, didReceiveMobileViewing sessionId: String, isViewing: Bool)

    /// 收到创建会话请求
    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?)
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
            // 注册为 Reader（VlaudeKit 主要读取数据）
            _ = try sharedDb?.register()
            print("[VlaudeClient] SharedDb initialized")
        } catch {
            print("[VlaudeClient] SharedDb not available: \(error)")
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
        do {
            try db.release()
            print("[VlaudeClient] SharedDb released")
        } catch {
            print("[VlaudeClient] SharedDb release failed: \(error)")
        }
        sharedDb = nil
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        // 连接成功
        socket.onClientEvent(.connect) { [weak self] in
            guard let self = self else { return }
            print("[VlaudeClient] Connected")
            self.isConnected = true

            // 发送注册和上线通知
            self.register()
            self.reportOnline()

            // 推送初始数据
            self.pushInitialData()

            // 通知 delegate
            self.delegate?.vlaudeClientDidConnect(self)
        }

        // 断开连接
        socket.onClientEvent(.disconnect) { [weak self] in
            guard let self = self else { return }
            print("[VlaudeClient] Disconnected")
            self.isConnected = false

            self.delegate?.vlaudeClientDidDisconnect(self)
        }

        // 连接错误
        socket.onClientEvent(.error) { [weak self] in
            print("[VlaudeClient] Error")
            _ = self
        }

        // 服务器关闭通知
        socket.on("server-shutdown") { [weak self] _ in
            print("[VlaudeClient] Server shutting down")
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

            print("[VlaudeClient] Received inject: session=\(sessionId)")

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

            print("[VlaudeClient] Mobile viewing: session=\(sessionId), isViewing=\(isViewing)")

            self.delegate?.vlaudeClient(self, didReceiveMobileViewing: sessionId, isViewing: isViewing)
        }

        // 创建会话请求
        socket.on("server:createSessionInEterm") { [weak self] data in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let projectPath = dict["projectPath"] as? String else {
                return
            }

            let prompt = dict["prompt"] as? String
            let requestId = dict["requestId"] as? String

            print("[VlaudeClient] Create session: projectPath=\(projectPath), requestId=\(requestId ?? "N/A")")

            self.delegate?.vlaudeClient(self, didReceiveCreateSession: projectPath, prompt: prompt, requestId: requestId)
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

        socket?.emit("daemon:register", data)
        print("[VlaudeClient] Register sent")
    }

    /// 上线通知
    private func reportOnline() {
        let data: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        socket?.emit("daemon:etermOnline", data)
        print("[VlaudeClient] Online sent")
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
        guard isConnected else { return }

        var data: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        if let path = projectPath {
            data["projectPath"] = path
        }

        socket?.emit("daemon:etermSessionAvailable", data)
        print("[VlaudeClient] SessionAvailable sent: \(sessionId)")
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
        print("[VlaudeClient] SessionUnavailable sent: \(sessionId)")
    }

    /// 上报 session 创建完成
    func reportSessionCreated(requestId: String, sessionId: String, projectPath: String) {
        guard isConnected else { return }

        let data: [String: Any] = [
            "requestId": requestId,
            "sessionId": sessionId,
            "projectPath": projectPath,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        socket?.emit("daemon:etermSessionCreated", data)
        print("[VlaudeClient] SessionCreated sent: \(sessionId)")
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
            print("[VlaudeClient] Failed to list projects")
            return
        }

        reportProjectData(projects: projects, requestId: requestId)
    }

    /// 处理会话列表请求
    private func handleRequestSessionMetadata(_ data: [String: Any]) {
        let projectPath = data["projectPath"] as? String
        let requestId = data["requestId"] as? String

        guard let sessions = sessionReader.listSessions(projectPath: projectPath) else {
            print("[VlaudeClient] Failed to list sessions")
            return
        }

        reportSessionMetadata(sessions: sessions, projectPath: projectPath, requestId: requestId)
    }

    /// 处理会话消息请求
    private func handleRequestSessionMessages(_ data: [String: Any]) {
        guard let sessionId = data["sessionId"] as? String,
              let projectPath = data["projectPath"] as? String else {
            print("[VlaudeClient] Missing sessionId or projectPath")
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
            print("[VlaudeClient] Failed to read messages for session: \(sessionId)")
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
            print("[VlaudeClient] Missing query for search")
            return
        }

        // Validate limit: clamp to 1-100 range to prevent UInt overflow
        let rawLimit = (data["limit"] as? Int) ?? 20
        let limit = max(1, min(rawLimit, 100))
        let projectId = data["projectId"] as? Int64
        let requestId = data["requestId"] as? String

        guard let sharedDb = sharedDb else {
            print("[VlaudeClient] Search not available - SharedDb not initialized")
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
            print("[VlaudeClient] Search failed: \(error)")
            reportSearchResults(results: [], query: query, requestId: requestId, error: error.localizedDescription)
        }
    }

    // MARK: - Data Reports (VlaudeKit → Server)

    /// 上报项目数据
    private func reportProjectData(projects: [ProjectInfo], requestId: String?) {
        guard isConnected else { return }

        var data: [String: Any] = [
            "projects": projects.map { project in
                var dict: [String: Any] = [
                    "path": project.path,
                    "encodedName": project.encodedName
                ]
                if let name = project.name { dict["name"] = name }
                if let count = project.sessionCount { dict["sessionCount"] = count }
                if let lastActive = project.lastActive { dict["lastModified"] = lastActive }
                return dict
            }
        ]

        if let requestId = requestId {
            data["requestId"] = requestId
        }

        socket?.emit("daemon:projectData", data)
        print("[VlaudeClient] Sent \(projects.count) projects")
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
        print("[VlaudeClient] Sent \(sessions.count) sessions")
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
            var dict: [String: Any] = [:]
            if let type = msg.type { dict["type"] = type }
            if let timestamp = msg.timestamp { dict["timestamp"] = timestamp }
            if let message = msg.message {
                var msgDict: [String: Any] = [:]
                if let role = message.role { msgDict["role"] = role }
                if let content = message.content { msgDict["content"] = content.value }
                dict["message"] = msgDict
            }
            return dict.isEmpty ? nil : dict
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
        print("[VlaudeClient] Sent \(messages.count) messages for session \(sessionId)")
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
        print("[VlaudeClient] Sent \(results.count) search results for '\(query)'")
    }

    /// 推送初始数据（连接成功后调用）
    /// 注意：VlaudeKit 只负责报告 ETerm 中当前打开的会话，不推送历史数据
    /// 历史数据由 Rust daemon 负责推送
    func pushInitialData() {
        print("[VlaudeClient] Ready (no initial data push, ETerm sessions will be reported individually)")
    }

    // MARK: - SharedDb Write Operations

    /// 索引会话到 SharedDb（当收到 claude.responseComplete 事件时调用）
    /// 使用 session-reader-ffi 正确解析路径（支持中文路径）
    /// - Parameter path: JSONL 会话文件路径
    func indexSession(path: String) {
        guard let sharedDb = sharedDb else {
            print("[VlaudeClient] SharedDb not available, skipping indexSession")
            return
        }

        // 检查是否为 Writer，如果不是尝试接管
        if sharedDb.role != .writer {
            do {
                let health = try sharedDb.checkWriterHealth()
                if health == .timeout || health == .released {
                    guard try sharedDb.tryTakeover() else {
                        print("[VlaudeClient] Cannot takeover Writer, skipping indexSession")
                        return
                    }
                } else {
                    print("[VlaudeClient] Not Writer and cannot takeover, skipping indexSession")
                    return
                }
            } catch {
                print("[VlaudeClient] Writer check failed: \(error)")
                return
            }
        }

        // 使用 session-reader-ffi 解析会话
        // 这会正确读取 JSONL 中的 cwd 字段来确定真实的项目路径
        guard let session = sessionReader.parseSessionForIndex(jsonlPath: path) else {
            print("[VlaudeClient] No messages to index in \(path)")
            return
        }

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
            let inserted = try sharedDb.insertMessages(sessionId: session.sessionId, messages: messages)
            print("[VlaudeClient] Indexed \(inserted) messages via SharedDb for session \(session.sessionId)")
        } catch {
            print("[VlaudeClient] Failed to write to SharedDb: \(error)")
        }
    }
}
