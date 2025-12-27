//
//  ProjectDetector.swift
//  ETerm
//
//  项目检测器协议和数据模型

import Foundation

// MARK: - 数据模型

/// 检测到的项目
struct DetectedProject: Identifiable {
    let id = UUID()
    let name: String
    let path: URL
    let type: String           // "node", "rust", "go"
    let scripts: [ProjectScript]
}

/// 项目脚本
struct ProjectScript: Identifiable {
    let id = UUID()
    let name: String           // "dev", "build", "test"
    let command: String        // "pnpm dev", "cargo build"
    let displayName: String?   // 可选的显示名称

    init(name: String, command: String, displayName: String? = nil) {
        self.name = name
        self.command = command
        self.displayName = displayName
    }
}

// MARK: - 项目检测器协议

/// 项目检测器 - 每种项目类型实现此协议
protocol ProjectDetector {
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
