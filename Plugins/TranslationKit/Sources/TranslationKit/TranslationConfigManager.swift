//
//  TranslationConfigManager.swift
//  TranslationKit
//
//  Translation Plugin Configuration Manager

import Foundation

// MARK: - Configuration Model

/// 翻译插件配置
public struct TranslationConfig: Codable, Equatable, Sendable {
    public var dispatcherModel: String
    public var analysisModel: String
    public var translationModel: String

    public static var `default`: TranslationConfig {
        TranslationConfig(
            dispatcherModel: "qwen-flash",
            analysisModel: "qwen3-max",
            translationModel: "qwen-mt-flash"
        )
    }

    public init(
        dispatcherModel: String,
        analysisModel: String,
        translationModel: String
    ) {
        self.dispatcherModel = dispatcherModel
        self.analysisModel = analysisModel
        self.translationModel = translationModel
    }
}

// MARK: - Configuration Manager

/// 翻译插件配置管理器
final class TranslationConfigManager: @unchecked Sendable {

    private let configFilePath: String
    private(set) var config: TranslationConfig

    init() {
        self.configFilePath = Self.defaultConfigPath()
        self.config = Self.loadConfig(from: configFilePath)
    }

    // MARK: - Public Methods

    /// 更新配置
    func updateConfig(
        dispatcherModel: String,
        analysisModel: String,
        translationModel: String
    ) {
        config = TranslationConfig(
            dispatcherModel: dispatcherModel,
            analysisModel: analysisModel,
            translationModel: translationModel
        )
        saveConfig()
    }

    /// 重置为默认配置
    func resetToDefault() {
        config = .default
        saveConfig()
    }

    // MARK: - Private

    private static func defaultConfigPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.eterm/plugins/Translation/config.json"
    }

    private static func loadConfig(from path: String) -> TranslationConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            return .default
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(TranslationConfig.self, from: data)
        } catch {
            return .default
        }
    }

    private func saveConfig() {
        do {
            let parentDir = (configFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            // 保存失败，静默处理
        }
    }
}
