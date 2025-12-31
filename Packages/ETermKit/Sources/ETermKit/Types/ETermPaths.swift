//
//  ETermPaths.swift
//  ETermKit
//
//  SDK 插件统一路径管理
//  支持 VIMO_HOME / ETERM_HOME 环境变量覆盖
//

import Foundation

/// ETerm 统一路径管理（SDK 版本）
public enum ETermPaths {

    // MARK: - Vimo 组织根目录

    /// Vimo 组织根目录: ~/.vimo (可通过 VIMO_HOME 环境变量覆盖)
    public static let vimoRoot: String = {
        if let customPath = ProcessInfo.processInfo.environment["VIMO_HOME"] {
            return customPath
        }
        return NSHomeDirectory() + "/.vimo"
    }()

    // MARK: - ETerm 根目录

    /// ETerm 主目录: ~/.vimo/eterm (可通过 ETERM_HOME 环境变量覆盖)
    public static let root: String = {
        if let customPath = ProcessInfo.processInfo.environment["ETERM_HOME"] {
            return customPath
        }
        return vimoRoot + "/eterm"
    }()

    // MARK: - 共享数据目录

    /// 共享数据库目录: ~/.vimo/db
    public static let sharedDb = vimoRoot + "/db"

    /// Claude 会话数据库: ~/.vimo/db/claude-session.db
    public static let claudeSessionDatabase = sharedDb + "/claude-session.db"

    // MARK: - 一级目录

    /// 配置目录: ~/.vimo/eterm/config
    public static let config = root + "/config"

    /// 数据目录: ~/.vimo/eterm/data
    public static let data = root + "/data"

    /// 插件目录: ~/.vimo/eterm/plugins
    public static let plugins = root + "/plugins"

    /// 日志目录: ~/.vimo/eterm/logs
    public static let logs = root + "/logs"

    /// 临时目录: ~/.vimo/eterm/tmp
    public static let tmp = root + "/tmp"

    /// 缓存目录: ~/.vimo/eterm/cache
    public static let cache = root + "/cache"

    /// 运行时目录: ~/.vimo/eterm/run
    public static let run = root + "/run"

    /// 插件 Socket 目录: ~/.vimo/eterm/run/sockets
    public static let sockets = run + "/sockets"

    // MARK: - 日志文件

    /// 获取当天日志文件路径: ~/.vimo/eterm/logs/debug-{date}.log
    public static func logFile(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)
        return "\(logs)/debug-\(dateString).log"
    }

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
