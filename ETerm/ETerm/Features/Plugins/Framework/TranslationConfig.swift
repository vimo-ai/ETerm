//
//  TranslationConfig.swift
//  ETerm
//
//  翻译插件配置管理 - 支持持久化到 JSON 文件
//

import Foundation
import Combine
import ETermKit

// MARK: - 翻译插件配置

struct TranslationPluginConfig: Codable, Equatable {
    var dispatcherModel: String
    var analysisModel: String
    var translationModel: String

    static var `default`: TranslationPluginConfig {
        TranslationPluginConfig(
            dispatcherModel: "qwen-flash",
            analysisModel: "qwen3-max",
            translationModel: "qwen-mt-flash"
        )
    }
}

// MARK: - 翻译插件配置管理器

final class TranslationPluginConfigManager: ObservableObject {
    static let shared = TranslationPluginConfigManager()

    private let configFilePath = ETermPaths.translationConfig

    @Published var config: TranslationPluginConfig {
        didSet {
            saveConfig()
        }
    }

    private init() {
        // 配置优先级：JSON 文件 > 迁移数据 > 默认值
        if let fileConfig = Self.loadFromFile(path: configFilePath) {
            self.config = fileConfig
        } else if let migratedConfig = Self.migrateFromUserDefaults() {
            // MARK: - Migration (TODO: Remove after v1.1)
            // 从旧的 UserDefaults 迁移数据
            self.config = migratedConfig
        } else {
            self.config = .default
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
            logError("保存翻译插件配置失败: \(error)")
        }
    }

    /// 从 JSON 文件加载配置（静态方法，供 init 调用）
    private static func loadFromFile(path: String) -> TranslationPluginConfig? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode(TranslationPluginConfig.self, from: data)
            return config
        } catch {
            logError("加载翻译插件配置失败: \(error)")
            return nil
        }
    }

    // MARK: - Migration (TODO: Remove after v1.1)

    /// 从旧的 UserDefaults 迁移数据（静态方法，供 init 调用）
    private static func migrateFromUserDefaults() -> TranslationPluginConfig? {
        let suiteName = "com.vimo.claude.ETerm.settings"
        let userDefaultsKey = "translation_plugin_config"

        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(TranslationPluginConfig.self, from: data) else {
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
}
