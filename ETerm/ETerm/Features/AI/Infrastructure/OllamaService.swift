//
//  OllamaService.swift
//  ETerm
//
//  Ollama 本地 AI 服务 - 提供命令补全、错误解释等智能功能的基础设施
//

import Foundation
import Combine

// MARK: - 配置

struct OllamaSettings: Codable, Equatable {
    var baseURL: String = "http://localhost:11434"
    var connectionTimeout: TimeInterval = 2.0
    var model: String = "qwen3:0.6b"
    var warmUpOnStart: Bool = true
    var keepAlive: String = "5m"

    static var `default`: OllamaSettings { OllamaSettings() }

    var isValid: Bool {
        !baseURL.isEmpty && URL(string: baseURL) != nil && !model.isEmpty
    }
}

// MARK: - 状态

enum OllamaStatus: Equatable {
    case unknown
    case notInstalled
    case notRunning
    case modelNotFound
    case ready
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .unknown: return "未知"
        case .notInstalled: return "未安装 Ollama"
        case .notRunning: return "Ollama 未运行"
        case .modelNotFound: return "模型未找到"
        case .ready: return "就绪"
        case .error(let msg): return "错误: \(msg)"
        }
    }
}

// MARK: - 错误

enum OllamaError: LocalizedError {
    case notReady(status: OllamaStatus)
    case invalidURL
    case requestFailed(status: Int, body: String?)
    case decodingFailed
    case connectionFailed(Error)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notReady(let status):
            return "Ollama 服务未就绪: \(status.displayText)"
        case .invalidURL:
            return "无效的 Ollama 地址"
        case .requestFailed(let status, let body):
            if let body = body, !body.isEmpty {
                return "请求失败 (HTTP \(status)): \(body)"
            }
            return "请求失败 (HTTP \(status))"
        case .decodingFailed:
            return "响应解析失败"
        case .connectionFailed(let error):
            return "连接失败: \(error.localizedDescription)"
        case .timeout:
            return "请求超时"
        case .cancelled:
            return "请求已取消"
        }
    }
}

// MARK: - 生成选项

struct GenerateOptions {
    var numPredict: Int = 100
    var temperature: Double = 0.7
    var stop: [String] = []
    var raw: Bool = false

    static var `default`: GenerateOptions { GenerateOptions() }

    /// 快速响应模式：用于命令补全等低延迟场景
    static var fast: GenerateOptions {
        GenerateOptions(numPredict: 10, temperature: 0.0, stop: ["\n", ".", ",", ":", ";"], raw: true)
    }
}

// MARK: - API 模型

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: [String: AnyCodable]?
    let raw: Bool?
    let keepAlive: String?

    init(model: String, prompt: String, stream: Bool = false, options: GenerateOptions, keepAlive: String? = nil) {
        self.model = model
        self.prompt = prompt
        self.stream = stream
        self.raw = options.raw ? true : nil
        self.keepAlive = keepAlive

        var opts: [String: AnyCodable] = [:]
        opts["num_predict"] = AnyCodable(options.numPredict)
        opts["temperature"] = AnyCodable(options.temperature)
        if !options.stop.isEmpty {
            opts["stop"] = AnyCodable(options.stop)
        }
        self.options = opts.isEmpty ? nil : opts
    }
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
    let done: Bool
    let context: [Int]?
    let totalDuration: Int?
    let loadDuration: Int?
    let promptEvalDuration: Int?
    let evalCount: Int?
    let evalDuration: Int?

    enum CodingKeys: String, CodingKey {
        case response, done, context
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalDuration = "prompt_eval_duration"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let size: Int?
        let digest: String?
    }
    let models: [Model]
}

private struct OllamaErrorResponse: Decodable {
    let error: String
}

// MARK: - 协议

protocol OllamaServiceProtocol {
    var status: OllamaStatus { get }
    var statusPublisher: AnyPublisher<OllamaStatus, Never> { get }

    func generate(prompt: String, options: GenerateOptions?) async throws -> String
    func checkHealth() async -> Bool
    func warmUp() async
}

// MARK: - 服务实现

final class OllamaService: OllamaServiceProtocol, ObservableObject {
    static let shared = OllamaService()

    @Published private(set) var settings: OllamaSettings
    @Published private(set) var status: OllamaStatus = .unknown

    var statusPublisher: AnyPublisher<OllamaStatus, Never> {
        $status.eraseToAnyPublisher()
    }

    private let session: URLSession
    private var keepAliveTimer: Timer?
    private let configFilePath: String

    private init() {
        self.configFilePath = ETermPaths.ollamaConfig

        // 配置 URLSession（短超时）
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 10.0
        self.session = URLSession(configuration: config)

        // 加载配置
        self.settings = Self.loadSettings(from: configFilePath)

        // 启动时检查状态
        Task {
            await checkHealth()
            if settings.warmUpOnStart && status.isReady {
                await warmUp()
            }
        }
    }

    // MARK: - 配置管理

    private static func loadSettings(from path: String) -> OllamaSettings {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let settings = try? JSONDecoder().decode(OllamaSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func updateSettings(_ newSettings: OllamaSettings) {
        settings = newSettings
        saveSettings()

        // 配置变更后重新检查状态
        Task {
            await checkHealth()
        }
    }

    private func saveSettings() {
        do {
            try ETermPaths.ensureParentDirectory(for: configFilePath)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            logError("保存 Ollama 配置失败: \(error)")
        }
    }

    // MARK: - 生成

    func generate(prompt: String, options: GenerateOptions? = nil) async throws -> String {
        guard status.isReady else {
            throw OllamaError.notReady(status: status)
        }

        guard let baseURL = URL(string: settings.baseURL) else {
            throw OllamaError.invalidURL
        }

        let opts = options ?? .default
        let requestBody = OllamaGenerateRequest(
            model: settings.model,
            prompt: prompt,
            stream: false,
            options: opts,
            keepAlive: settings.keepAlive
        )

        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = settings.connectionTimeout
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.requestFailed(status: -1, body: nil)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = parseErrorBody(data)
            throw OllamaError.requestFailed(status: httpResponse.statusCode, body: errorBody)
        }

        guard let result = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data) else {
            throw OllamaError.decodingFailed
        }

        return result.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 健康检查

    @discardableResult
    func checkHealth() async -> Bool {
        // 1. 检查 Ollama 是否安装
        guard isOllamaInstalled() else {
            await MainActor.run { status = .notInstalled }
            return false
        }

        // 2. 检查 API 是否响应
        guard await isAPIResponding() else {
            await MainActor.run { status = .notRunning }
            return false
        }

        // 3. 检查模型是否存在
        guard await isModelInstalled() else {
            await MainActor.run { status = .modelNotFound }
            return false
        }

        await MainActor.run { status = .ready }
        return true
    }

    private func isOllamaInstalled() -> Bool {
        // 检查常见的安装路径
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
            NSHomeDirectory() + "/.ollama/ollama"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        // 也可以尝试用 which 命令（但这里简化处理）
        return false
    }

    private func isAPIResponding() async -> Bool {
        guard let baseURL = URL(string: settings.baseURL) else {
            return false
        }

        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0  // 快速超时

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func isModelInstalled() async -> Bool {
        guard let baseURL = URL(string: settings.baseURL) else {
            return false
        }

        let url = baseURL.appendingPathComponent("api/tags")

        do {
            let (data, _) = try await session.data(from: url)
            let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)

            // 检查模型名是否匹配（支持部分匹配，如 qwen3:0.6b 匹配 qwen3:0.6b-q4_0）
            let targetModel = settings.model.lowercased()
            return tagsResponse.models.contains { model in
                model.name.lowercased().hasPrefix(targetModel) ||
                model.name.lowercased() == targetModel
            }
        } catch {
            return false
        }
    }

    // MARK: - 预热 & 保活

    func warmUp() async {
        guard settings.warmUpOnStart, status.isReady else { return }

        // 发送一个简单请求预热模型
        _ = try? await generate(
            prompt: "hi",
            options: GenerateOptions(numPredict: 1, temperature: 0.0)
        )

        // 启动保活定时器
        await MainActor.run {
            startKeepAlive()
        }
    }

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()

        // 每 60 秒 ping 一次保持模型热状态
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.ping() }
        }
    }

    private func ping() async {
        guard status.isReady else { return }

        // 空请求保持模型加载
        _ = try? await generate(
            prompt: "",
            options: GenerateOptions(numPredict: 0)
        )
    }

    func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - 辅助方法

    private func parseErrorBody(_ data: Data) -> String? {
        if let errorResponse = try? JSONDecoder().decode(OllamaErrorResponse.self, from: data) {
            return errorResponse.error
        }
        return String(data: data, encoding: .utf8)
    }

    /// 获取已安装的模型列表
    func listModels() async -> [String] {
        guard let baseURL = URL(string: settings.baseURL) else {
            return []
        }

        let url = baseURL.appendingPathComponent("api/tags")

        do {
            let (data, _) = try await session.data(from: url)
            let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tagsResponse.models.map { $0.name }
        } catch {
            return []
        }
    }
}

// MARK: - AnyCodable Helper

private struct AnyCodable: Encodable {
    private let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [String]:
            try container.encode(array)
        case let array as [Int]:
            try container.encode(array)
        case let dict as [String: Any]:
            let encodableDict = dict.mapValues { AnyCodable($0) }
            try container.encode(encodableDict)
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "AnyCodable cannot encode \(type(of: value))"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
}

// MARK: - Logging Helper

private func logError(_ message: String) {
    #if DEBUG
    print("[OllamaService] ERROR: \(message)")
    #endif
}
