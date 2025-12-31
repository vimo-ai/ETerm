//
//  VlaudeConfig.swift
//  VlaudeKit
//
//  配置管理 - 持久化到 JSON 文件
//

import Foundation
import Combine
import ETermKit

// MARK: - 配置结构

public struct VlaudeConfig: Codable, Equatable {
    /// 服务器地址（如 http://nas:3000）
    var serverURL: String

    /// 是否启用
    var enabled: Bool

    /// 设备名称（用于 daemon:register）
    var deviceName: String

    static var `default`: VlaudeConfig {
        VlaudeConfig(
            serverURL: "",
            enabled: false,
            deviceName: Host.current().localizedName ?? "Mac"
        )
    }

    /// 验证配置是否有效
    var isValid: Bool {
        guard enabled else { return false }
        guard !serverURL.isEmpty else { return false }
        guard URL(string: serverURL) != nil else { return false }
        return true
    }
}

// MARK: - 配置管理器

public final class VlaudeConfigManager: ObservableObject {
    public static let shared = VlaudeConfigManager()

    private static let configFilePath: String = {
        try? ETermPaths.ensureDirectory(ETermPaths.config)
        return ETermPaths.config + "/vlaude.json"
    }()

    private let configFilePath = VlaudeConfigManager.configFilePath

    @Published public var config: VlaudeConfig {
        didSet {
            if config != oldValue {
                saveConfig()
                // 通知配置变更
                NotificationCenter.default.post(
                    name: .vlaudeConfigDidChange,
                    object: nil,
                    userInfo: ["config": config]
                )
            }
        }
    }

    private init() {
        // 从文件加载配置，否则使用默认值
        if let fileConfig = Self.loadFromFile(path: configFilePath) {
            self.config = fileConfig
            print("[VlaudeKit] Loaded config: serverURL=\(fileConfig.serverURL), enabled=\(fileConfig.enabled)")
        } else {
            self.config = .default
            print("[VlaudeKit] Using default config")
        }
    }

    // MARK: - 持久化

    private func saveConfig() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            print("[VlaudeKit] Failed to save config: \(error)")
        }
    }

    private static func loadFromFile(path: String) -> VlaudeConfig? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode(VlaudeConfig.self, from: data)
            return config
        } catch {
            print("[VlaudeKit] Failed to load config: \(error)")
            return nil
        }
    }

    // MARK: - 公开方法

    /// 重置为默认配置
    public func resetToDefault() {
        config = .default
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let vlaudeConfigDidChange = Notification.Name("VlaudeConfigDidChange")
}
