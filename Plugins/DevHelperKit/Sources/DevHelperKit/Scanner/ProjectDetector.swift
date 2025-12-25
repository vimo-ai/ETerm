// ProjectDetector.swift
// DevHelperKit
//
// 项目检测器协议和数据模型

import Foundation

// MARK: - 数据模型

/// 检测到的项目
public struct DetectedProject: Identifiable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let type: String           // "node", "rust", "go"
    public let scripts: [ProjectScript]

    public init(id: UUID = UUID(), name: String, path: String, type: String, scripts: [ProjectScript]) {
        self.id = id
        self.name = name
        self.path = path
        self.type = type
        self.scripts = scripts
    }
}

/// 项目脚本
public struct ProjectScript: Identifiable, Codable, Sendable {
    public let id: UUID
    public let name: String           // "dev", "build", "test"
    public let command: String        // "pnpm dev", "cargo build"
    public let displayName: String?   // 可选的显示名称

    public init(id: UUID = UUID(), name: String, command: String, displayName: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.displayName = displayName
    }
}

// MARK: - 项目检测器协议

/// 项目检测器 - 每种项目类型实现此协议
public protocol ProjectDetector {
    /// 要查找的配置文件名（如 "package.json", "Cargo.toml"）
    var configFileName: String { get }

    /// 项目类型标识（如 "node", "rust", "go"）
    var projectType: String { get }

    /// 该项目类型需要跳过的目录
    var skipDirectories: Set<String> { get }

    /// 解析配置文件，返回项目信息
    /// - Parameters:
    ///   - configPath: 配置文件路径
    ///   - folderPath: 项目文件夹路径
    /// - Returns: 检测到的项目，如果解析失败返回 nil
    func parse(configPath: URL, folderPath: URL) -> DetectedProject?
}
