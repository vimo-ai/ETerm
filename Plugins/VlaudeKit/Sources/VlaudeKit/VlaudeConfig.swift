//
//  VlaudeConfig.swift
//  VlaudeKit
//
//  配置管理 - 持久化到 JSON 文件
//

import Foundation
import Combine
import IOKit
import ETermKit

// MARK: - 配置结构

public struct VlaudeConfig: Codable, Equatable {
    /// 服务器地址（如 http://nas:3000）- 作为 fallback
    var serverURL: String

    /// 是否启用
    var enabled: Bool

    /// 设备名称（用于 daemon:register）
    var deviceName: String

    /// 设备 ID（唯一标识，自动生成）
    var deviceId: String

    // MARK: - Redis 配置

    /// 是否启用 Redis 服务发现
    var useRedis: Bool

    /// Redis 主机地址
    var redisHost: String

    /// Redis 端口
    var redisPort: UInt16

    /// Redis 密码（可选）
    var redisPassword: String?

    /// Daemon TTL（秒），默认 30 秒
    var daemonTTL: UInt64

    static var `default`: VlaudeConfig {
        VlaudeConfig(
            serverURL: "",
            enabled: false,
            deviceName: Host.current().localizedName ?? "Mac",
            deviceId: generateDeviceId(),
            useRedis: false,
            redisHost: "localhost",
            redisPort: 6379,
            redisPassword: nil,
            daemonTTL: 30
        )
    }

    /// 验证配置是否有效
    var isValid: Bool {
        guard enabled else { return false }

        // Redis 模式：只需要 Redis 配置有效
        if useRedis {
            return !redisHost.isEmpty
        }

        // 直连模式：需要服务器地址有效
        guard !serverURL.isEmpty else { return false }
        guard URL(string: serverURL) != nil else { return false }
        return true
    }

    /// 生成唯一设备 ID
    private static func generateDeviceId() -> String {
        // 优先使用硬件 UUID
        if let uuid = getHardwareUUID() {
            return "eterm-\(uuid.prefix(8))"
        }
        // 降级使用随机 UUID
        return "eterm-\(UUID().uuidString.prefix(8))"
    }

    /// 获取硬件 UUID
    private static func getHardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let uuidData = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }

        return uuidData
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
