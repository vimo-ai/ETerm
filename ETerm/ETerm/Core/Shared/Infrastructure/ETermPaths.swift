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

    // MARK: - Vimo 组织根目录

    /// Vimo 组织根目录: ~/.vimo (可通过 VIMO_HOME 环境变量覆盖)
    static let vimoRoot: String = {
        if let customPath = ProcessInfo.processInfo.environment["VIMO_HOME"] {
            return customPath
        }
        return NSHomeDirectory() + "/.vimo"
    }()

    // MARK: - ETerm 根目录

    /// ETerm 主目录: ~/.vimo/eterm (可通过 ETERM_HOME 环境变量覆盖)
    static let root: String = {
        if let customPath = ProcessInfo.processInfo.environment["ETERM_HOME"] {
            return customPath
        }
        return vimoRoot + "/eterm"
    }()

    // MARK: - 共享数据目录

    /// 共享数据库目录: ~/.vimo/db
    static let sharedDb = vimoRoot + "/db"

    /// Claude 会话数据库: ~/.vimo/db/ai-cli-session.db
    static let claudeSessionDatabase = sharedDb + "/ai-cli-session.db"

    // MARK: - 一级目录

    /// 配置目录: ~/.vimo/eterm/config
    static let config = root + "/config"

    /// 数据目录: ~/.vimo/eterm/data
    static let data = root + "/data"

    /// 插件目录: ~/.vimo/eterm/plugins
    static let plugins = root + "/plugins"

    /// 日志目录: ~/.vimo/eterm/logs
    static let logs = root + "/logs"

    /// 临时目录: ~/.vimo/eterm/tmp
    static let tmp = root + "/tmp"

    /// 缓存目录: ~/.vimo/eterm/cache
    static let cache = root + "/cache"

    // MARK: - 配置文件

    /// AI 配置文件: ~/.vimo/eterm/config/ai.json
    static let aiConfig = config + "/ai.json"

    /// Ollama 配置文件: ~/.vimo/eterm/config/ollama.json
    static let ollamaConfig = config + "/ollama.json"

    /// AI Socket 文件: ~/.vimo/eterm/tmp/ai.sock
    static let aiSocket = tmp + "/ai.sock"

    /// 会话配置文件: ~/.vimo/eterm/config/session.json
    static let sessionConfig = config + "/session.json"

    // MARK: - 数据文件

    /// 单词数据库: ~/.vimo/eterm/data/words.db
    static let wordsDatabase = data + "/words.db"

    /// 工作区数据库: ~/.vimo/eterm/data/workspace.db
    static let workspaceDatabase = data + "/workspace.db"

    // MARK: - 插件相关

    /// 插件配置文件: ~/.vimo/eterm/plugins/plugins.json
    static let pluginsConfig = plugins + "/plugins.json"

    /// SDK 插件配置文件: ~/.vimo/eterm/plugins/sdk-plugins.json
    static let sdkPluginsConfig = plugins + "/sdk-plugins.json"

    /// Bundle 插件配置文件: ~/.vimo/eterm/plugins/bundle-plugins.json
    static let bundlePluginsConfig = plugins + "/bundle-plugins.json"

    /// Claude Monitor 插件目录: ~/.vimo/eterm/plugins/claude-monitor
    static let claudeMonitorPlugin = plugins + "/claude-monitor"

    /// Claude Monitor 使用历史: ~/.vimo/eterm/plugins/claude-monitor/usage_history.json
    static let claudeMonitorUsageHistory = claudeMonitorPlugin + "/usage_history.json"

    /// English Learning 插件目录: ~/.vimo/eterm/plugins/english-learning
    static let englishLearningPlugin = plugins + "/english-learning"

    /// 翻译插件配置: ~/.vimo/eterm/config/translation.json
    /// 与 SDK 插件 (TranslationKit/WritingKit) 共享配置
    static let translationConfig = config + "/translation.json"

    /// MCP Router 插件目录: ~/.vimo/eterm/plugins/mcp-router
    static let mcpRouterPlugin = plugins + "/mcp-router"

    /// MCP Router 服务器配置: ~/.vimo/eterm/plugins/mcp-router/servers.json
    static let mcpRouterServers = mcpRouterPlugin + "/servers.json"

    /// MCP Router 工作区配置: ~/.vimo/eterm/plugins/mcp-router/workspaces.json
    static let mcpRouterWorkspaces = mcpRouterPlugin + "/workspaces.json"

    // MARK: - 临时文件

    /// 剪贴板临时目录: ~/.vimo/eterm/tmp/clipboard
    static let clipboard = tmp + "/clipboard"

    // MARK: - 脚本目录

    /// 脚本目录: ~/.vimo/eterm/scripts
    static let scripts = root + "/scripts"

    /// Claude Hook 脚本路径
    static let claudeHookScript = scripts + "/claude_hook.sh"

    /// Claude Hook 默认版本（用于版本对比）
    static let claudeHookDefault = scripts + "/.claude_hook.sh.default"

    // MARK: - 运行时目录

    /// 运行时目录: ~/.vimo/eterm/run
    static let run = root + "/run"

    /// 插件 Socket 目录: ~/.vimo/eterm/run/sockets
    ///
    /// 插件在此目录创建 Unix Domain Socket。
    /// 环境变量 ETERM_SOCKET_DIR 指向此目录。
    static let sockets = run + "/sockets"

    /// 获取插件 socket 路径
    ///
    /// - Parameter namespace: socket namespace（如 "claude"）
    /// - Returns: `~/.vimo/eterm/run/sockets/{namespace}.sock`
    static func socketPath(for namespace: String) -> String {
        return "\(sockets)/\(namespace).sock"
    }

    // MARK: - Socket 路径（传统位置，逐步废弃）

    /// Socket 路径: /tmp/eterm
    @available(*, deprecated, message: "Use ETermPaths.sockets instead")
    static let socket = "/tmp/eterm"

    /// Socket 文件路径: /tmp/eterm/eterm-{pid}.sock
    @available(*, deprecated, message: "Use ETermPaths.socketPath(for:) instead")
    static func socketFile(pid: Int32) -> String {
        return "\(socket)/eterm-\(pid).sock"
    }

    // MARK: - 日志文件

    /// 获取当天日志文件路径: ~/.vimo/eterm/logs/debug-{date}.log
    static func logFile(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)
        return "\(logs)/debug-\(dateString).log"
    }

    /// 调试导出目录: ~/.vimo/eterm/logs/exports
    static let debugExports = logs + "/exports"

    // MARK: - 目录创建

    /// 创建所有必要的目录
    static func createDirectories() throws {
        let fileManager = FileManager.default

        // 普通目录（默认权限）
        let directories = [
            vimoRoot,
            sharedDb,
            root,
            config,
            data,
            plugins,
            logs,
            tmp,
            cache,
            claudeMonitorPlugin,
            englishLearningPlugin,
            mcpRouterPlugin,
            clipboard,
            run,
            scripts,
            debugExports
        ]

        for directory in directories {
            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
        }

        // Socket 目录（权限 0700，防止其他用户访问）
        if !fileManager.fileExists(atPath: sockets) {
            try fileManager.createDirectory(
                atPath: sockets,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // 设置环境变量（供子进程使用）
        setenv("ETERM_SOCKET_DIR", sockets, 1)
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
