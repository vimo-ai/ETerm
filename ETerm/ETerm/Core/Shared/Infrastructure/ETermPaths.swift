//
//  ETermPaths.swift
//  ETerm
//
//  统一的路径管理
//  定义所有 ETerm 数据存储路径常量
//

import Foundation

/// ETerm 统一路径管理
enum ETermPaths {

    // MARK: - 根目录

    /// ETerm 主目录: ~/.eterm
    static let root = NSHomeDirectory() + "/.eterm"

    // MARK: - 一级目录

    /// 配置目录: ~/.eterm/config
    static let config = root + "/config"

    /// 数据目录: ~/.eterm/data
    static let data = root + "/data"

    /// 插件目录: ~/.eterm/plugins
    static let plugins = root + "/plugins"

    /// 日志目录: ~/.eterm/logs
    static let logs = root + "/logs"

    /// 临时目录: ~/.eterm/tmp
    static let tmp = root + "/tmp"

    /// 缓存目录: ~/.eterm/cache
    static let cache = root + "/cache"

    // MARK: - 配置文件

    /// AI 配置文件: ~/.eterm/config/ai.json
    static let aiConfig = config + "/ai.json"

    /// 会话配置文件: ~/.eterm/config/session.json
    static let sessionConfig = config + "/session.json"

    // MARK: - 数据文件

    /// 单词数据库: ~/.eterm/data/words.db
    static let wordsDatabase = data + "/words.db"

    /// 工作区数据库: ~/.eterm/data/workspace.db
    static let workspaceDatabase = data + "/workspace.db"

    // MARK: - 插件相关

    /// 插件配置文件: ~/.eterm/plugins/plugins.json
    static let pluginsConfig = plugins + "/plugins.json"

    /// Claude Monitor 插件目录: ~/.eterm/plugins/claude-monitor
    static let claudeMonitorPlugin = plugins + "/claude-monitor"

    /// Claude Monitor 使用历史: ~/.eterm/plugins/claude-monitor/usage_history.json
    static let claudeMonitorUsageHistory = claudeMonitorPlugin + "/usage_history.json"

    /// English Learning 插件目录: ~/.eterm/plugins/english-learning
    static let englishLearningPlugin = plugins + "/english-learning"

    /// 翻译插件配置: ~/.eterm/plugins/english-learning/translation.json
    static let translationConfig = englishLearningPlugin + "/translation.json"

    // MARK: - 临时文件

    /// 剪贴板临时目录: ~/.eterm/tmp/clipboard
    static let clipboard = tmp + "/clipboard"

    // MARK: - Socket 路径（保持传统位置）

    /// Socket 路径: /tmp/eterm
    static let socket = "/tmp/eterm"

    /// Socket 文件路径: /tmp/eterm/eterm-{pid}.sock
    static func socketFile(pid: Int32) -> String {
        return "\(socket)/eterm-\(pid).sock"
    }

    // MARK: - 日志文件

    /// 获取当天日志文件路径: ~/.eterm/logs/debug-{date}.log
    static func logFile(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)
        return "\(logs)/debug-\(dateString).log"
    }

    /// 调试导出目录: ~/.eterm/logs/exports
    static let debugExports = logs + "/exports"

    // MARK: - 目录创建

    /// 创建所有必要的目录
    static func createDirectories() throws {
        let directories = [
            root,
            config,
            data,
            plugins,
            logs,
            tmp,
            cache,
            claudeMonitorPlugin,
            englishLearningPlugin,
            clipboard,
            socket,
            debugExports
        ]

        let fileManager = FileManager.default

        for directory in directories {
            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
        }
    }

    /// 确保目录存在（自动创建）
    static func ensureDirectory(_ path: String) throws {
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
    static func ensureParentDirectory(for filePath: String) throws {
        let parentDirectory = (filePath as NSString).deletingLastPathComponent
        try ensureDirectory(parentDirectory)
    }
}
