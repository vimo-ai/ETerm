//
//  TranslationConfig.swift
//  ETerm
//
//  翻译插件配置管理
//

import Foundation
import Combine

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

    private let suiteName = "com.vimo.claude.ETerm.settings"
    private let userDefaultsKey = "translation_plugin_config"
    private var userDefaults: UserDefaults

    @Published var config: TranslationPluginConfig {
        didSet {
            saveConfig()
        }
    }

    private init() {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.userDefaults = defaults

        // 尝试从 UserDefaults 加载配置，否则使用默认值
        if let data = defaults.data(forKey: userDefaultsKey),
           let savedConfig = try? JSONDecoder().decode(TranslationPluginConfig.self, from: data) {
            self.config = savedConfig
        } else {
            self.config = .default
        }
    }

    // MARK: - 持久化

    private func saveConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        userDefaults.set(data, forKey: userDefaultsKey)
    }

    // MARK: - 公开方法

    /// 重置为默认配置
    func resetToDefault() {
        config = .default
    }
}
