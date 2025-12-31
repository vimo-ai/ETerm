//
//  AIConfigManager.swift
//  ETerm
//
//  AI 配置管理器 - 支持持久化到 JSON 文件
//

import Foundation
import Combine
import ETermKit

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

    private let configFilePath = ETermPaths.aiConfig

    @Published var config: AIConfig {
        didSet {
            saveConfig()
        }
    }

    private init() {
        // 配置优先级：JSON 文件 > 迁移数据 > 环境变量 > 默认值
        if let fileConfig = Self.loadFromFile(path: configFilePath) {
            self.config = fileConfig
        } else if let migratedConfig = Self.migrateFromUserDefaults() {
            // MARK: - Migration (TODO: Remove after v1.1)
            // 从旧的 UserDefaults 迁移数据
            self.config = migratedConfig
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

    /// 保存配置到 JSON 文件
    private func saveConfig() {
        do {
            // 确保父目录存在
            try ETermPaths.ensureParentDirectory(for: configFilePath)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            logError("保存 AI 配置失败: \(error)")
        }
    }

    /// 从 JSON 文件加载配置（静态方法，供 init 调用）
    private static func loadFromFile(path: String) -> AIConfig? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode(AIConfig.self, from: data)
            return config
        } catch {
            logError("加载 AI 配置失败: \(error)")
            return nil
        }
    }

    // MARK: - Migration (TODO: Remove after v1.1)

    /// 从旧的 UserDefaults 迁移数据（静态方法，供 init 调用）
    private static func migrateFromUserDefaults() -> AIConfig? {
        let suiteName = "com.vimo.claude.ETerm.settings"
        let userDefaultsKey = "ai_config"

        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else {
            return nil
        }

        // 清除旧数据
        defaults.removeObject(forKey: userDefaultsKey)

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
