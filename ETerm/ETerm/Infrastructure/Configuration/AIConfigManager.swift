//
//  AIConfigManager.swift
//  ETerm
//
//  AI 配置管理器 - 支持持久化到 UserDefaults
//

import Foundation
import Combine

// MARK: - AI 配置模型

struct AIConfig: Codable, Equatable {
    var apiKey: String
    var baseURL: String

    static var `default`: AIConfig {
        AIConfig(
            apiKey: "",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
    }

    /// 从环境变量加载配置
    static func fromEnvironment() -> AIConfig {
        let apiKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] ?? ""
        let baseURL = ProcessInfo.processInfo.environment["DASHSCOPE_BASE_URL"] ?? "https://dashscope.aliyuncs.com/compatible-mode/v1"

        return AIConfig(
            apiKey: apiKey,
            baseURL: baseURL
        )
    }

    /// 验证配置是否有效
    var isValid: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && URL(string: baseURL) != nil
    }
}

// MARK: - 配置管理器

final class AIConfigManager: ObservableObject {
    static let shared = AIConfigManager()

    private let suiteName = "com.vimo.claude.ETerm.settings"
    private let userDefaultsKey = "ai_config"
    private var userDefaults: UserDefaults

    @Published var config: AIConfig {
        didSet {
            saveConfig()
        }
    }

    private init() {
        // 先初始化 userDefaults
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.userDefaults = defaults

        // 配置优先级：UserDefaults > 环境变量 > 默认值
        if let data = defaults.data(forKey: userDefaultsKey),
           let savedConfig = try? JSONDecoder().decode(AIConfig.self, from: data) {
            self.config = savedConfig
        } else {
            let envConfig = AIConfig.fromEnvironment()
            if envConfig.isValid {
                self.config = envConfig
            } else {
                self.config = .default
            }
        }
    }

    // MARK: - 持久化

    private func saveConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        userDefaults.set(data, forKey: userDefaultsKey)
    }

    private func loadFromUserDefaults() -> AIConfig? {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else {
            return nil
        }
        return config
    }

    // MARK: - 公开方法

    /// 重置为默认配置
    func resetToDefault() {
        config = .default
    }

    /// 测试连接
    func testConnection() async throws -> Bool {
        guard let url = URL(string: config.baseURL) else {
            throw DashScopeError.invalidBaseURL
        }

        guard !config.apiKey.isEmpty else {
            throw DashScopeError.missingAPIKey
        }

        // 创建临时客户端测试（使用默认模型）
        let testConfig = DashScopeClient.Configuration(
            apiKey: config.apiKey,
            baseURL: url,
            defaultModel: "qwen-flash"
        )

        let client = DashScopeClient(configuration: testConfig)

        // 发送一个简单的测试请求（使用默认模型）
        let testMessage = DashScopeMessage(role: "user", content: "hi")
        _ = try await client.chat(messages: [testMessage], model: "qwen-flash")

        return true
    }
}
