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
            redisHost: "localhost",
            redisPort: 6379,
            redisPassword: nil,
            daemonTTL: 30
        )
    }

    /// 验证配置是否有效
    var isValid: Bool {
        guard enabled else { return false }
        // 只需要 Redis 配置有效
        return !redisHost.isEmpty
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

// MARK: - 连接状态

public enum VlaudeConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
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

    /// 连接状态
    @Published public private(set) var connectionStatus: VlaudeConnectionStatus = .disconnected

    /// 更新连接状态（由 VlaudePlugin 调用）
    public func updateConnectionStatus(_ status: VlaudeConnectionStatus) {
        if connectionStatus != status {
            connectionStatus = status
            NotificationCenter.default.post(
                name: .vlaudeConnectionStatusDidChange,
                object: nil,
                userInfo: ["status": status]
            )
        }
    }

    /// 请求手动重连（由 UI 调用）
    public func requestReconnect() {
        guard connectionStatus == .disconnected else { return }
        NotificationCenter.default.post(
            name: .vlaudeReconnectRequested,
            object: nil
        )
    }

    private init() {
        // 从文件加载配置，否则使用默认值
        if let fileConfig = Self.loadFromFile(path: configFilePath) {
            self.config = fileConfig
        } else {
            self.config = .default
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
            // Save failed silently
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
    static let vlaudeConnectionStatusDidChange = Notification.Name("VlaudeConnectionStatusDidChange")
    static let vlaudeReconnectRequested = Notification.Name("VlaudeReconnectRequested")
}
