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

    /// 服务进程
    private var process: Process?

    /// 是否正在运行
    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// API 基础 URL
    public var baseURL: URL {
        URL(string: "http://localhost:\(port)")!
    }

    private init() {}

    // MARK: - Lifecycle

    /// 启动服务
    public func start() throws {
        guard !isRunning else { return }

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

    /// 停止服务
    public func stop() {
        guard let process = process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
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

    /// 搜索
    public func search(query: String, limit: Int = 20) async throws -> [MemexSearchResult] {
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

    /// 获取统计信息
    public func getStats() async throws -> MemexStats {
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
    public func indexSession(path: String) async throws {
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

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Memex binary not found. Please install memex or place it in $ETERM_HOME/bin/"
        case .requestFailed:
            return "HTTP request failed"
        case .serviceNotRunning:
            return "Memex service is not running"
        }
    }
}
