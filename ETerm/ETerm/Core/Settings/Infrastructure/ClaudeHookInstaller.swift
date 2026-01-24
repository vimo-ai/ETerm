//
//  ClaudeHookInstaller.swift
//  ETerm
//
//  Claude Hook 安装管理器
//  负责检测、安装、更新 Claude hooks
//

import Foundation
import AppKit
import Combine
import ETermKit

/// Hook 安装状态
enum HookInstallStatus: Equatable {
    case notInstalled          // 未安装
    case installed             // 已安装，版本匹配
    case outdated              // 有更新可用
    case userModified          // 用户已修改脚本
    case partiallyInstalled    // 部分 hooks 已注册
    case error(String)         // 检测出错

    var displayText: String {
        switch self {
        case .notInstalled:
            return "未安装"
        case .installed:
            return "已安装"
        case .outdated:
            return "有更新"
        case .userModified:
            return "已修改"
        case .partiallyInstalled:
            return "部分安装"
        case .error(let message):
            return "错误: \(message)"
        }
    }

    var statusColor: String {
        switch self {
        case .installed:
            return "green"
        case .notInstalled, .outdated, .partiallyInstalled:
            return "orange"
        case .userModified:
            return "blue"
        case .error:
            return "red"
        }
    }
}

/// 需要注册的 hook 类型
enum ClaudeHookType: String, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case stop = "Stop"
    case notification = "Notification"
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"

    var description: String {
        switch self {
        case .sessionStart: return "会话开始"
        case .sessionEnd: return "会话结束"
        case .stop: return "会话完成"
        case .notification: return "通知"
        case .userPromptSubmit: return "用户输入"
        case .permissionRequest: return "权限请求"
        }
    }
}

/// Claude Hook 安装器
final class ClaudeHookInstaller: ObservableObject {

    static let shared = ClaudeHookInstaller()

    @Published private(set) var status: HookInstallStatus = .notInstalled
    @Published private(set) var installedHooks: [ClaudeHookType] = []
    @Published private(set) var isInstalling: Bool = false

    /// Claude settings.json 路径
    private var settingsPath: String {
        return NSHomeDirectory() + "/.claude/settings.json"
    }

    /// App bundle 中的源脚本路径
    private var bundleScriptPath: String? {
        return Bundle.main.path(forResource: "claude_hook", ofType: "sh")
    }

    private init() {
        checkStatus()
    }

    // MARK: - Public Methods

    /// 检查当前安装状态
    func checkStatus() {
        let fileManager = FileManager.default

        // 1. 检查目标脚本是否存在
        guard fileManager.fileExists(atPath: ETermPaths.claudeHookScript) else {
            status = .notInstalled
            installedHooks = []
            return
        }

        // 2. 检查 settings.json 中注册的 hooks
        installedHooks = getInstalledHooks()

        if installedHooks.isEmpty {
            status = .notInstalled
            return
        }

        if installedHooks.count < ClaudeHookType.allCases.count {
            status = .partiallyInstalled
            return
        }

        // 3. 检查脚本是否被修改
        if fileManager.fileExists(atPath: ETermPaths.claudeHookDefault) {
            if let currentScript = try? String(contentsOfFile: ETermPaths.claudeHookScript, encoding: .utf8),
               let defaultScript = try? String(contentsOfFile: ETermPaths.claudeHookDefault, encoding: .utf8) {
                if currentScript != defaultScript {
                    status = .userModified
                    return
                }
            }
        }

        // 4. 检查是否有更新（对比 bundle 版本与 .default）
        if let bundlePath = bundleScriptPath,
           let bundleScript = try? String(contentsOfFile: bundlePath, encoding: .utf8),
           let defaultScript = try? String(contentsOfFile: ETermPaths.claudeHookDefault, encoding: .utf8) {
            if bundleScript != defaultScript {
                status = .outdated
                return
            }
        }

        status = .installed
    }

    /// 获取已注册的 hook 类型
    func getInstalledHooks() -> [ClaudeHookType] {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: settingsPath),
              let data = fileManager.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return []
        }

        var installed = Set<ClaudeHookType>()
        let targetScript = ETermPaths.claudeHookScript

        for hookType in ClaudeHookType.allCases {
            if let hookArray = hooks[hookType.rawValue] as? [[String: Any]] {
                outerLoop: for matcher in hookArray {
                    if let hookList = matcher["hooks"] as? [[String: Any]] {
                        for hook in hookList {
                            if let command = hook["command"] as? String,
                               command.contains(targetScript) {
                                installed.insert(hookType)
                                break outerLoop
                            }
                        }
                    }
                }
            }
        }

        return Array(installed)
    }

    /// 安装或更新 hooks
    /// - Parameter force: 是否强制覆盖用户修改
    func install(force: Bool = false) async throws {
        await MainActor.run {
            isInstalling = true
        }

        defer {
            Task { @MainActor in
                isInstalling = false
                checkStatus()
            }
        }

        let fileManager = FileManager.default

        // 1. 确保目录存在
        try ETermPaths.ensureDirectory(ETermPaths.scripts)

        // 2. 复制脚本到用户目录
        guard let bundlePath = bundleScriptPath else {
            throw HookInstallError.bundleScriptNotFound
        }

        let shouldCopy: Bool
        if fileManager.fileExists(atPath: ETermPaths.claudeHookScript) {
            if force {
                shouldCopy = true
            } else if fileManager.fileExists(atPath: ETermPaths.claudeHookDefault) {
                // 检查是否被修改
                let currentScript = try String(contentsOfFile: ETermPaths.claudeHookScript, encoding: .utf8)
                let defaultScript = try String(contentsOfFile: ETermPaths.claudeHookDefault, encoding: .utf8)
                shouldCopy = (currentScript == defaultScript)
            } else {
                shouldCopy = true
            }
        } else {
            shouldCopy = true
        }

        if shouldCopy {
            // 复制脚本
            if fileManager.fileExists(atPath: ETermPaths.claudeHookScript) {
                try fileManager.removeItem(atPath: ETermPaths.claudeHookScript)
            }
            try fileManager.copyItem(atPath: bundlePath, toPath: ETermPaths.claudeHookScript)

            // 设置可执行权限
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ETermPaths.claudeHookScript)

            // 保存 .default 副本
            if fileManager.fileExists(atPath: ETermPaths.claudeHookDefault) {
                try fileManager.removeItem(atPath: ETermPaths.claudeHookDefault)
            }
            try fileManager.copyItem(atPath: bundlePath, toPath: ETermPaths.claudeHookDefault)
        }

        // 3. 注册 hooks 到 settings.json
        try registerHooks()
    }

    /// 打开 Claude settings.json 文件
    func openSettingsFile() {
        let url = URL(fileURLWithPath: settingsPath)
        NSWorkspace.shared.open(url)
    }

    /// 打开脚本目录
    func openScriptsDirectory() {
        NSWorkspace.shared.selectFile(ETermPaths.claudeHookScript, inFileViewerRootedAtPath: ETermPaths.scripts)
    }

    // MARK: - Private Methods

    private func registerHooks() throws {
        let fileManager = FileManager.default
        // 路径需要引用以支持空格
        let targetScript = ETermPaths.claudeHookScript
        let quotedScript = targetScript.replacingOccurrences(of: "\"", with: "\\\"")

        // 确保 ~/.claude 目录存在
        let claudeDir = NSHomeDirectory() + "/.claude"
        try fileManager.createDirectory(atPath: claudeDir, withIntermediateDirectories: true, attributes: nil)

        // 读取或创建 settings.json
        var settings: [String: Any]
        if fileManager.fileExists(atPath: settingsPath) {
            guard let data = fileManager.contents(atPath: settingsPath) else {
                throw HookInstallError.settingsFileError("无法读取文件")
            }

            // 尝试解析 JSON，如果失败则备份原文件
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = json
            } else {
                // JSON 无效，备份原文件后创建新配置
                let backupPath = settingsPath + ".backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: settingsPath, toPath: backupPath)
                settings = [:]
            }
        } else {
            settings = [:]
        }

        // 确保 hooks 对象存在
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // 为每个 hook 类型添加 ETerm hook
        for hookType in ClaudeHookType.allCases {
            var hookArray = hooks[hookType.rawValue] as? [[String: Any]] ?? []

            // 查找或创建全局 matcher（matcher 为空字符串）
            var globalMatcherIndex: Int? = nil
            for (index, matcher) in hookArray.enumerated() {
                if let matcherStr = matcher["matcher"] as? String, matcherStr.isEmpty {
                    globalMatcherIndex = index
                    break
                }
            }

            // 获取或创建全局 matcher
            var globalMatcher: [String: Any]
            if let index = globalMatcherIndex {
                globalMatcher = hookArray[index]
            } else {
                globalMatcher = ["matcher": "", "hooks": []]
            }

            var hookList = globalMatcher["hooks"] as? [[String: Any]] ?? []

            // 检查是否已存在
            let alreadyExists = hookList.contains { hook in
                if let command = hook["command"] as? String {
                    return command.contains(targetScript)
                }
                return false
            }

            if !alreadyExists {
                hookList.append([
                    "type": "command",
                    "command": "bash \"\(quotedScript)\""
                ])
                globalMatcher["hooks"] = hookList

                // 更新或添加全局 matcher
                if let index = globalMatcherIndex {
                    hookArray[index] = globalMatcher
                } else {
                    hookArray.append(globalMatcher)
                }
                hooks[hookType.rawValue] = hookArray
            }
        }

        settings["hooks"] = hooks

        // 写入 settings.json
        let jsonData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: URL(fileURLWithPath: settingsPath))
    }
}

// MARK: - Errors

enum HookInstallError: LocalizedError {
    case bundleScriptNotFound
    case settingsFileError(String)

    var errorDescription: String? {
        switch self {
        case .bundleScriptNotFound:
            return "无法找到 bundle 中的 hook 脚本"
        case .settingsFileError(let message):
            return "settings.json 处理错误: \(message)"
        }
    }
}
