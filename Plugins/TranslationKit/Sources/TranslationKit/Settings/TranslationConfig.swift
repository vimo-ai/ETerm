//
//  TranslationConfig.swift
//  TranslationKit
//
//  翻译插件配置管理 - 支持持久化到 JSON 文件
//

import Foundation
import Combine
import ETermKit

// MARK: - 翻译插件配置

public struct TranslationPluginConfig: Codable, Equatable {
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

public final class TranslationPluginConfigManager: ObservableObject {
    public static let shared = TranslationPluginConfigManager()

    private static let configFilePath: String = {
        try? ETermPaths.ensureDirectory(ETermPaths.config)
        return ETermPaths.config + "/translation.json"
    }()

    private let configFilePath = TranslationPluginConfigManager.configFilePath

    @Published var config: TranslationPluginConfig {
        didSet {
            saveConfig()
        }
    }

    private init() {
        // 配置优先级：JSON 文件 > 迁移数据 > 默认值
        print("[TranslationKit] 配置文件路径: \(configFilePath)")
        if let fileConfig = Self.loadFromFile(path: configFilePath) {
            self.config = fileConfig
            print("[TranslationKit] 从文件加载配置: dispatcher=\(fileConfig.dispatcherModel), analysis=\(fileConfig.analysisModel), translation=\(fileConfig.translationModel)")
        } else if let migratedConfig = Self.migrateFromUserDefaults() {
            // MARK: - Migration (TODO: Remove after v1.1)
            // 从旧的 UserDefaults 迁移数据
            self.config = migratedConfig
            print("[TranslationKit] 从 UserDefaults 迁移配置")
        } else {
            self.config = .default
            print("[TranslationKit] 使用默认配置")
        }
    }

    // MARK: - 持久化

    /// 保存配置到 JSON 文件
    private func saveConfig() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            print("[TranslationKit] 保存配置失败: \(error)")
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
            print("[TranslationKit] 加载配置失败: \(error)")
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
