//
//  ETermPaths.swift
//  ETermKit
//
//  SDK 插件统一路径管理
//  支持 ETERM_HOME 环境变量覆盖
//

import Foundation

/// ETerm 统一路径管理（SDK 版本）
public enum ETermPaths {

    // MARK: - 根目录

    /// ETerm 主目录: ~/.eterm (可通过 ETERM_HOME 环境变量覆盖)
    public static let root: String = {
        if let customPath = ProcessInfo.processInfo.environment["ETERM_HOME"] {
            return customPath
        }
        return NSHomeDirectory() + "/.eterm"
    }()

    // MARK: - 一级目录

    /// 配置目录: ~/.eterm/config
    public static let config = root + "/config"

    /// 数据目录: ~/.eterm/data
    public static let data = root + "/data"

    /// 插件目录: ~/.eterm/plugins
    public static let plugins = root + "/plugins"

    /// 日志目录: ~/.eterm/logs
    public static let logs = root + "/logs"

    /// 临时目录: ~/.eterm/tmp
    public static let tmp = root + "/tmp"

    /// 缓存目录: ~/.eterm/cache
    public static let cache = root + "/cache"

    /// 运行时目录: ~/.eterm/run
    public static let run = root + "/run"

    /// 插件 Socket 目录: ~/.eterm/run/sockets
    public static let sockets = run + "/sockets"

    // MARK: - 辅助方法

    /// 确保目录存在（自动创建）
    public static func ensureDirectory(_ path: String) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    /// 确保文件所在目录存在
    public static func ensureParentDirectory(for filePath: String) throws {
        let parentDirectory = (filePath as NSString).deletingLastPathComponent
        try ensureDirectory(parentDirectory)
    }
}
