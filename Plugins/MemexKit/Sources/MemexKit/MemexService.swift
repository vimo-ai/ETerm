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
        initSharedDb()
    }

    /// 初始化 SharedDb（最佳努力）
    private func initSharedDb() {
        do {
            sharedDb = try SharedDbBridge()
            _ = try sharedDb?.register()
            print("[MemexService] SharedDb initialized")
        } catch {
            print("[MemexService] SharedDb not available: \(error)")
            sharedDb = nil
        }
    }

    // MARK: - Lifecycle

    /// 启动服务
    public func start() throws {
        guard !isRunning else { return }

        // 确保 SharedDb 已初始化（可能之前被 stop() 释放）
        if sharedDb == nil {
            initSharedDb()
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

        // 数据目录（统一在 $ETERM_HOME/memex 下，不污染 ~ 目录）
        let dataDir = URL(fileURLWithPath: ETermPaths.root)
            .appendingPathComponent("memex")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // 设置环境变量（通过 MEMEX_DATA_DIR 告诉 memex-rs 数据目录位置）
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["RUST_LOG"] = "memex=info"
        env["MEMEX_DATA_DIR"] = dataDir.path
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
        // 1. 释放 SharedDbBridge Writer（必须在停止进程前释放，确保 daemon 能接管）
        releaseSharedDb()

        // 2. 停止自己管理的进程
        if let process = self.process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            self.process = nil
        }

        // 3. 杀掉端口上的 memex 进程（可能是外部启动的或上次未正确关闭的）
        killMemexOnPort()
    }

    /// 释放 SharedDbBridge（线程安全，SharedDbBridge 内部用 queue.sync 保护）
    private nonisolated func releaseSharedDb() {
        guard let db = sharedDb else { return }
        do {
            try db.release()
            print("[MemexService] SharedDb released")
        } catch {
            print("[MemexService] SharedDb release failed: \(error)")
        }
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
        // 1. 插件 Bundle 内的 Lib 目录 (Contents/Lib/memex)
        let bundlePath = Bundle(for: MemexService.self).bundlePath
        let bundleLibPath = bundlePath + "/Contents/Lib/memex"
        if FileManager.default.isExecutableFile(atPath: bundleLibPath) {
            return bundleLibPath
        }

        // 2. 插件源码目录 (开发时使用)
        let devLibPath = (bundlePath as NSString).deletingLastPathComponent + "/Lib/memex"
        if FileManager.default.isExecutableFile(atPath: devLibPath) {
            return devLibPath
        }

        // 3. $ETERM_HOME/bin
        let etermBin = ETermPaths.root + "/bin/memex"
        if FileManager.default.isExecutableFile(atPath: etermBin) {
            return etermBin
        }

        // 4. /usr/local/bin (brew install)
        let usrLocalBin = "/usr/local/bin/memex"
        if FileManager.default.isExecutableFile(atPath: usrLocalBin) {
            return usrLocalBin
        }

        // 5. PATH
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["memex"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }

        return nil
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

    /// 搜索（优先使用 SharedDb，回退到 HTTP API）
    public func search(query: String, limit: Int = 20) async throws -> [MemexSearchResult] {
        // 优先使用 SharedDb
        if let sharedDb = sharedDb {
            do {
                let safeLimit = max(1, min(limit, 100))
                let results = try sharedDb.search(query: query, limit: safeLimit)
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
            } catch {
                print("[MemexService] SharedDb search failed, falling back to HTTP: \(error)")
            }
        }

        // 回退到 HTTP API
        var components = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MemexServiceError.requestFailed
        }

        let results = try JSONDecoder().decode([MemexSearchResultDTO].self, from: data)
        return results.map { $0.toModel() }
    }

    /// 获取统计信息（优先使用 SharedDb，回退到 HTTP API）
    public func getStats() async throws -> MemexStats {
        // 优先使用 SharedDb
        if let sharedDb = sharedDb {
            do {
                let stats = try sharedDb.getStats()
                return MemexStats(
                    projectCount: Int(stats.projectCount),
                    sessionCount: Int(stats.sessionCount),
                    messageCount: Int(stats.messageCount),
                    semanticSearchEnabled: false,  // SharedDb 不支持语义搜索
                    aiChatEnabled: false
                )
            } catch {
                print("[MemexService] SharedDb getStats failed, falling back to HTTP: \(error)")
            }
        }

        // 回退到 HTTP API
        let url = baseURL.appendingPathComponent("api/stats")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MemexServiceError.requestFailed
        }

        return try JSONDecoder().decode(MemexStats.self, from: data)
    }

    /// 触发采集
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

    /// 索引指定会话（精确索引，替代 file watcher 轮询）
    /// - Parameter path: JSONL 会话文件路径
    ///
    /// 优先尝试 HTTP API，失败时回退到 SharedDb 直写
    public func indexSession(path: String) async throws {
        // 1. 如果 HTTP 服务运行中，优先用 HTTP
        if isRunning || isPortInUse(port) {
            do {
                try await indexSessionViaHTTP(path: path)
                return
            } catch {
                print("[MemexService] HTTP indexSession failed, trying SharedDb: \(error)")
            }
        }

        // 2. 回退到 SharedDb 直写
        try await indexSessionViaSharedDb(path: path)
    }

    /// 通过 HTTP API 索引会话
    private func indexSessionViaHTTP(path: String) async throws {
        let url = baseURL.appendingPathComponent("api/index")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["path": path]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MemexServiceError.requestFailed
        }
    }

    /// 通过 SharedDb 直接写入会话
    private func indexSessionViaSharedDb(path: String) async throws {
        guard let sharedDb = sharedDb else {
            throw MemexServiceError.sharedDbNotAvailable
        }

        // 检查是否为 Writer，如果不是尝试接管
        if sharedDb.role != .writer {
            let health = try sharedDb.checkWriterHealth()
            if health == .timeout || health == .released {
                guard try sharedDb.tryTakeover() else {
                    throw MemexServiceError.notWriter
                }
            } else {
                throw MemexServiceError.notWriter
            }
        }

        // 使用 session-reader-ffi 解析会话（正确读取 cwd 解决中文路径问题）
        guard let session = sessionReader.parseSessionForIndex(jsonlPath: path) else {
            print("[MemexService] No messages to index in \(path)")
            return
        }

        // 转换消息格式
        let messages = session.messages.map { msg in
            MessageInput(
                uuid: msg.uuid,
                role: msg.role == "user" ? "human" : "assistant",
                content: msg.content,
                timestamp: msg.timestamp,
                sequence: msg.sequence
            )
        }

        guard !messages.isEmpty else {
            print("[MemexService] No messages to index in \(path)")
            return
        }

        // 写入数据库
        let projectId = try sharedDb.upsertProject(
            path: session.projectPath,
            name: session.projectName,
            source: "claude-code"
        )
        try sharedDb.upsertSession(sessionId: session.sessionId, projectId: projectId)
        let inserted = try sharedDb.insertMessages(sessionId: session.sessionId, messages: messages)

        print("[MemexService] Indexed \(inserted) messages via SharedDb for session \(session.sessionId)")
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
    case notWriter
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
        case .notWriter:
            return "Not a Writer, cannot write to SharedDb"
        case .fileReadFailed:
            return "Failed to read JSONL file"
        }
    }
}
