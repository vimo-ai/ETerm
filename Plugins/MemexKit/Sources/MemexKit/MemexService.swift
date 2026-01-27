//
//  MemexService.swift
//  MemexKit
//
//  Memex HTTP 服务管理
//
//  职责：
//  - 启动/停止 memex HTTP 服务（子进程）
//  - 提供 HTTP API 客户端
//

import Foundation
import ETermKit
import SharedDbFFI

// MARK: - Search Order

/// 搜索排序方式
public enum MemexSearchOrderBy: String, Sendable {
    case score = "score"           // 相关性排序（默认）
    case timeDesc = "time_desc"    // 时间倒序（最新优先）
    case timeAsc = "time_asc"      // 时间正序（最早优先）

    func toSharedOrderBy() -> SharedSearchOrderBy {
        switch self {
        case .score: return .score
        case .timeDesc: return .timeDesc
        case .timeAsc: return .timeAsc
        }
    }
}

// MARK: - MemexService

/// Memex 服务管理器
@MainActor
public final class MemexService: @unchecked Sendable {
    public static let shared = MemexService()

    /// 服务端口
    public let port: UInt16 = 10013

    /// 服务进程（nonisolated 以支持 stop() 跨线程调用）
    private nonisolated(unsafe) var process: Process?

    /// SharedDb 桥接（nonisolated 以支持 stop() 跨线程释放）
    private nonisolated(unsafe) var sharedDb: SharedDbBridge?

    /// Agent Client（用于接收 Agent 事件推送）
    private nonisolated(unsafe) var agentClient: AgentClientBridge?

    /// Session Reader（用于解析 JSONL 文件）
    private lazy var sessionReader = SessionReader()

    /// 是否正在运行
    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// SharedDb 是否可用
    public var isSharedDbAvailable: Bool {
        sharedDb != nil
    }

    /// API 基础 URL
    public var baseURL: URL {
        URL(string: "http://localhost:\(port)")!
    }

    private init() {
        // 在后台线程初始化 SharedDb，完成后再初始化 AgentClient
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.initSharedDb()
        }
    }

    /// 初始化 SharedDb（在后台线程调用），完成后启动 AgentClient
    ///
    /// SharedDb 现在是只读的，写入和采集由 Agent 处理。
    private nonisolated func initSharedDb() {
        do {
            let db = try SharedDbBridge()

            // 回到主线程设置状态，然后在后台启动 AgentClient
            DispatchQueue.main.async { [weak self] in
                self?.sharedDb = db
                logInfo("[MemexKit] SharedDb connected (read-only)")

                // SharedDb 就绪后，在后台启动 AgentClient
                DispatchQueue.global(qos: .utility).async {
                    self?.initAgentClient()
                }
            }
        } catch {
            logWarn("[MemexKit] SharedDb init failed: \(error)")
            // SharedDb 初始化失败，仍然尝试启动 AgentClient（部分功能可用）
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.initAgentClient()
            }
        }
    }

    /// 重连尝试次数
    private nonisolated(unsafe) var reconnectAttempts: Int = 0

    /// 最大重连次数
    private let maxReconnectAttempts: Int = 5

    /// 初始化 AgentClient（在后台线程调用，内部回到主线程设置状态）
    ///
    /// 连接到 vimo-agent 订阅事件推送，当收到 NewMessages 事件时触发采集。
    private nonisolated func initAgentClient() {
        do {
            // 使用 plugin bundle 的 Lib 目录作为 agent 源（用于首次部署）
            let pluginBundle = Bundle(for: MemexPlugin.self)
            let client = try AgentClientBridge(component: "memexkit", bundle: pluginBundle)
            try client.connect()
            try client.subscribe(events: [.newMessages])

            // 回到主线程设置 delegate 和状态
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                client.delegate = self
                self.agentClient = client
                self.reconnectAttempts = 0
                logInfo("[MemexKit] AgentClient 已连接并订阅 NewMessages 事件")
            }
        } catch {
            DispatchQueue.main.async {
                logWarn("[MemexKit] AgentClient 初始化失败: \(error)")
            }
        }
    }

    /// 尝试重连 AgentClient
    private func attemptReconnect() async {
        guard reconnectAttempts < maxReconnectAttempts else {
            logWarn("[MemexKit] AgentClient 达到最大重连次数 (\(maxReconnectAttempts))，停止重连")
            return
        }

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)  // 指数退避，最大 30 秒
        logInfo("[MemexKit] AgentClient 将在 \(Int(delay)) 秒后尝试第 \(reconnectAttempts) 次重连")

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        // 在后台线程执行重连（FFI 使用 block_on 会阻塞）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.initAgentClient()
        }
    }

    // MARK: - Lifecycle

    /// 启动服务
    public func start() throws {
        guard !isRunning else { return }

        // 如果 SharedDb 未初始化，在后台重新初始化（可能之前被 stop() 释放）
        if sharedDb == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.initSharedDb()
            }
        }

        // 检查端口是否已被占用（可能外部已启动 memex）
        if isPortInUse(port) { return }

        // 查找 memex 二进制
        guard let binaryPath = findBinary() else {
            throw MemexServiceError.binaryNotFound
        }

        // 配置进程
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        // 数据目录（统一在 ~/.vimo/db 下，与 memex-rs 默认配置一致）
        // 不设置 MEMEX_DATA_DIR，让 memex-rs 使用默认值 ~/.vimo/db
        let dataDir = URL(fileURLWithPath: ETermPaths.vimoRoot)
            .appendingPathComponent("db")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // 设置环境变量
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["RUST_LOG"] = "memex=info"
        // MEMEX_DATA_DIR 不设置，使用默认值 ~/.vimo/db
        // 确保 PATH 包含 homebrew 和常用工具路径（归档需要 xz 等外部命令）
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(extraPaths):\(existingPath)"
        } else {
            env["PATH"] = extraPaths
        }
        process.environment = env
        process.currentDirectoryURL = dataDir

        // 重定向输出到文件（不打印到 Xcode 控制台）
        let logFile = dataDir.appendingPathComponent("memex.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let fileHandle = try? FileHandle(forWritingTo: logFile)
        process.standardOutput = fileHandle
        process.standardError = fileHandle

        // 启动进程
        try process.run()
        self.process = process

        // 等待服务就绪
        Task {
            await waitForReady()
        }
    }

    /// 停止服务（同步版本，用于 app 退出时调用）
    public nonisolated func stop() {
        // 1. 断开 AgentClient
        agentClient?.disconnect()
        agentClient = nil

        // 2. 释放 SharedDbBridge Writer（必须在停止进程前释放，确保 daemon 能接管）
        releaseSharedDb()

        // 3. 停止自己管理的进程
        if let process = self.process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            self.process = nil
        }

        // 4. 杀掉端口上的 memex 进程（可能是外部启动的或上次未正确关闭的）
        killMemexOnPort()
    }

    /// 释放 SharedDbBridge（deinit 会自动关闭连接）
    private nonisolated func releaseSharedDb() {
        sharedDb = nil
    }

    /// 杀掉端口上的 memex 进程
    private nonisolated func killMemexOnPort() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", "-i", ":\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
            lsof.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            // 可能有多个 PID（一行一个）
            for pidStr in output.components(separatedBy: .newlines) {
                guard let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) else { continue }
                kill(pid, SIGTERM)
            }
        } catch {
            // 静默失败
        }
    }

    /// 等待服务就绪
    private func waitForReady() async {
        for _ in 0..<30 {  // 最多等待 3 秒
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            if await checkHealth() { return }
        }
    }

    // MARK: - Binary Discovery

    /// 查找 memex 二进制
    private func findBinary() -> String? {
        let bin = ETermPaths.root + "/bin/memex"
        return FileManager.default.isExecutableFile(atPath: bin) ? bin : nil
    }

    // MARK: - Port Detection

    /// 检查端口是否已被占用
    private func isPortInUse(_ port: UInt16) -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    // MARK: - Health Check

    /// 检查服务健康状态
    public func checkHealth() async -> Bool {
        let url = baseURL.appendingPathComponent("health")
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - HTTP API Client

extension MemexService {

    /// 搜索（优先使用 HTTP API 获得向量搜索能力，回退到 FFI）
    /// - Parameters:
    ///   - query: 搜索关键词
    ///   - orderBy: 排序方式 (score/timeDesc/timeAsc)
    ///   - startDate: 开始日期（格式：YYYY-MM-DD，可选）
    ///   - endDate: 结束日期（格式：YYYY-MM-DD，可选）
    ///   - limit: 返回数量
    public func search(
        query: String,
        orderBy: MemexSearchOrderBy = .score,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int = 20
    ) async throws -> [MemexSearchResult] {
        // 优先使用 HTTP API（有向量搜索 + RRF 融合 + 日期过滤）
        if isRunning || isPortInUse(port) {
            do {
                var components = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
                var queryItems = [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "orderBy", value: orderBy.rawValue)
                ]
                if let startDate = startDate {
                    queryItems.append(URLQueryItem(name: "startDate", value: startDate))
                }
                if let endDate = endDate {
                    queryItems.append(URLQueryItem(name: "endDate", value: endDate))
                }
                components.queryItems = queryItems

                let (data, response) = try await URLSession.shared.data(from: components.url!)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw MemexServiceError.requestFailed
                }

                let results = try JSONDecoder().decode([MemexSearchResultDTO].self, from: data)
                return results.map { $0.toModel() }
            } catch {
                // HTTP 失败，fallback 到 FFI
            }
        }

        // 降级到 FFI（FTS only，无向量搜索，支持日期过滤）
        if let sharedDb = sharedDb {
            let safeLimit = max(1, min(limit, 100))
            let startTs = startDate.flatMap { dateToTimestamp($0, isStart: true) }
            let endTs = endDate.flatMap { dateToTimestamp($0, isStart: false) }
            let results = try sharedDb.searchFull(
                query: query,
                orderBy: orderBy.toSharedOrderBy(),
                startTimestamp: startTs,
                endTimestamp: endTs,
                limit: safeLimit
            )
            return results.map { r in
                MemexSearchResult(
                    id: r.messageId,
                    sessionId: r.sessionId,
                    projectId: r.projectId,
                    projectName: r.projectName,
                    messageType: r.role,
                    content: r.content,
                    snippet: r.snippet,
                    score: r.score,
                    timestamp: r.timestamp.map { String($0) }
                )
            }
        }

        throw MemexServiceError.serviceNotRunning
    }

    /// 将日期字符串 (YYYY-MM-DD) 转换为时间戳（毫秒）
    private func dateToTimestamp(_ date: String, isStart: Bool) -> Int64? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let parsed = formatter.date(from: date) else { return nil }

        let calendar = Calendar.current
        if isStart {
            // 一天的开始 00:00:00
            guard let startOfDay = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: parsed) else { return nil }
            return Int64(startOfDay.timeIntervalSince1970 * 1000)
        } else {
            // 一天的结束 23:59:59.999
            guard let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: parsed) else { return nil }
            return Int64(endOfDay.timeIntervalSince1970 * 1000) + 999
        }
    }

    /// 获取统计信息（混合模式：FFI 基础数据 + HTTP 扩展数据）
    public func getStats() async throws -> MemexStats {
        // 尝试从 HTTP 获取扩展数据（dbSize, startupDuration 等）
        var httpStats: MemexStats?
        let url = baseURL.appendingPathComponent("api/stats")
        if let (data, response) = try? await URLSession.shared.data(from: url),
           let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200 {
            httpStats = try? JSONDecoder().decode(MemexStats.self, from: data)
        }

        // 如果 HTTP 成功，直接返回完整数据
        if let stats = httpStats {
            return stats
        }

        // HTTP 失败时，回退到 SharedDb（只有基础数据）
        if let sharedDb = sharedDb {
            let stats = try sharedDb.getStats()
            return MemexStats(
                projectCount: Int(stats.projectCount),
                sessionCount: Int(stats.sessionCount),
                messageCount: Int(stats.messageCount),
                semanticSearchEnabled: false,
                aiChatEnabled: false,
                dbSizeBytes: nil,
                startupDurationMs: nil
            )
        }

        throw MemexServiceError.requestFailed
    }

    /// 触发全量采集（通过 HTTP API）
    public func collect() async throws {
        let url = baseURL.appendingPathComponent("api/collect")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MemexServiceError.requestFailed
        }
    }

    /// 按路径精确采集单个会话（Writer 直接写入）
    ///
    /// 当收到 AI CLI Event（如 aicli.responseComplete）时调用此方法。
    /// Writer 直接调用 FFI 写入数据库，FTS 索引通过触发器自动更新。
    /// - Parameter path: JSONL 文件路径
    ///
    /// 通过 AgentClient 通知 Agent 采集指定文件
    public func collectByPath(_ path: String) throws {
        guard let agentClient = agentClient else {
            throw MemexServiceError.agentNotConnected
        }
        try agentClient.notifyFileChange(path: path)
    }

    /// 索引指定会话（通过 Agent 采集）
    /// - Parameter path: JSONL 会话文件路径
    ///
    /// 通知 Agent 采集指定文件，Agent 会处理解析和写入
    public func indexSession(path: String) async throws {
        try collectByPath(path)
    }

    /// 触发 Compact 任务
    /// - Parameter sessionId: 会话 ID
    ///
    /// 通过 HTTP API 触发 compact（L1 + L2）
    /// 静默失败，不影响主流程
    public func triggerCompact(sessionId: String) async throws {
        guard isRunning || isPortInUse(port) else {
            throw MemexServiceError.serviceNotRunning
        }

        let url = baseURL.appendingPathComponent("api/compact/trigger")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["session_id": sessionId]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MemexServiceError.requestFailed
        }
    }

}

// MARK: - Public Types

/// 搜索结果
public struct MemexSearchResult: Identifiable, Sendable {
    public let id: Int64  // message_id
    public let sessionId: String
    public let projectId: Int64
    public let projectName: String
    public let messageType: String
    public let content: String
    public let snippet: String
    public let score: Double
    public let timestamp: String?
}

/// 统计信息
public struct MemexStats: Decodable, Sendable {
    public let projectCount: Int
    public let sessionCount: Int
    public let messageCount: Int
    public let semanticSearchEnabled: Bool?
    public let aiChatEnabled: Bool?
    /// 数据库文件大小（字节）
    public let dbSizeBytes: UInt64?
    /// 启动初始化耗时（毫秒）
    public let startupDurationMs: UInt64?
}

// MARK: - DTOs

/// 搜索结果 DTO（HTTP API 响应）
private struct MemexSearchResultDTO: Decodable {
    let message_id: Int64
    let session_id: String
    let project_id: Int64
    let project_name: String
    let type: String  // API 返回字段名是 "type"
    let content: String
    let snippet: String
    let score: Double
    let timestamp: String?

    func toModel() -> MemexSearchResult {
        MemexSearchResult(
            id: message_id,
            sessionId: session_id,
            projectId: project_id,
            projectName: project_name,
            messageType: type,
            content: content,
            snippet: snippet,
            score: score,
            timestamp: timestamp
        )
    }
}

// MARK: - Errors

public enum MemexServiceError: Error, LocalizedError {
    case binaryNotFound
    case requestFailed
    case serviceNotRunning
    case sharedDbNotAvailable
    case agentNotConnected
    case fileReadFailed

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Memex binary not found. Please install memex or place it in $ETERM_HOME/bin/"
        case .requestFailed:
            return "HTTP request failed"
        case .serviceNotRunning:
            return "Memex service is not running"
        case .sharedDbNotAvailable:
            return "SharedDb not available"
        case .agentNotConnected:
            return "Agent not connected"
        case .fileReadFailed:
            return "Failed to read JSONL file"
        }
    }
}

// MARK: - AgentClientDelegate

extension MemexService: AgentClientDelegate {
    nonisolated func agentClient(_ client: AgentClientBridge, didReceiveEvent event: AgentEvent) {
        switch event {
        case .newMessages(let data):
            // 在后台队列处理，避免阻塞主线程
            Task.detached(priority: .utility) {
                await self.handleAgentNewMessages(data)
            }

        case .sessionStart, .sessionEnd:
            // MemexKit 只关心 NewMessages 事件
            break
        }
    }

    nonisolated func agentClient(_ client: AgentClientBridge, didDisconnect error: Error?) {
        logWarn("[MemexKit] AgentClient 断开连接: \(error?.localizedDescription ?? "unknown")")

        // 尝试重连
        Task.detached(priority: .utility) {
            await self.attemptReconnect()
        }
    }

    /// 处理 Agent 推送的新消息事件
    ///
    /// 注意：虽然用了 Task.detached，但 MemexService 是 @MainActor，
    /// 所以这个方法仍会在主线程执行。FFI 调用必须在后台队列执行。
    private func handleAgentNewMessages(_ data: NewMessagesEvent) async {
        let path = data.path
        let sessionId = data.sessionId

        // FFI 调用（collectByPath → notifyFileChange）会阻塞，必须在后台队列执行
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { continuation.resume() }
                guard let self = self else { return }
                do {
                    try self.collectByPath(path)
                    logDebug("[MemexKit] 采集成功: \(sessionId)")
                } catch {
                    logWarn("[MemexKit] 采集失败: \(error)")
                }
            }
        }

        // triggerCompact 是 HTTP 请求，不会阻塞主线程
        try? await triggerCompact(sessionId: sessionId)
    }
}
