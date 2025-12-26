//
//  Paths.swift
//  ClaudeMonitorKit
//
//  插件路径工具

import Foundation

/// 插件路径工具
enum ClaudeMonitorPaths {
    /// 插件数据目录
    static var dataDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.eterm/plugins/claude-monitor"
    }

    /// 用量历史存储路径
    static var usageHistory: String {
        return "\(dataDirectory)/usage_history.json"
    }

    /// 确保父目录存在
    static func ensureParentDirectory(for path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )
    }
}
