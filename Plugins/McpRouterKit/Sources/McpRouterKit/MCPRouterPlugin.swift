//
//  MCPRouterPlugin.swift
//  McpRouterKit
//
//  MCP Router 插件入口点
//

import Foundation
import AppKit
import Combine
import SwiftUI

/// MCP Router 插件入口类
///
/// 通过 NSPrincipalClass 机制被 ETerm PluginLoader 加载和激活
@objc @MainActor
public final class MCPRouterPlugin: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isRunning = false
    @Published var currentPort: UInt16 = 19104
    @Published private(set) var statusMessage = "未启动"
    @Published var autoStart = true
    @Published var fullMode = false

    // MARK: - Private Properties

    private var router: MCPRouterBridge?
    private var isHttpServerRunning = false

    /// 单例（供 UI 访问）
    @objc public static var shared: MCPRouterPlugin? {
        _shared
    }

    private static var _shared: MCPRouterPlugin?

    public override init() {
        super.init()

        // 第一个被创建的实例自动成为 shared（防止 PluginLoader 直接创建导致多实例）
        if Self._shared == nil {
            Self._shared = self
        }

        loadSettings()

        // 立即初始化 router（不启动 HTTP 服务）
        do {
            router = try MCPRouterBridge()
            loadServerConfigs()
        } catch {
            statusMessage = "初始化失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Public Access

    /// 暴露 Bridge 给设置界面使用
    public var routerBridge: MCPRouterBridge? { router }

    public var port: UInt16 { currentPort }
    public var running: Bool { isRunning }
    public var version: String { MCPRouterBridge.version }
    public var endpointURL: String { "http://localhost:\(currentPort)" }

    // MARK: - Plugin Lifecycle (called by PluginLoader via Objective-C runtime)

    /// 激活插件（通过 PluginLoader 调用）
    @objc public func activate() {
        // 初始化日志
        MCPRouterBridge.initLogging()

        // 注册侧边栏（通过通知机制，避免直接依赖 PluginContext）
        registerUI()

        // 自动启动
        if autoStart {
            start()
        }
    }

    /// 停用插件
    @objc public func deactivate() {
        if isHttpServerRunning {
            stop()
        }
        router = nil
    }

    // MARK: - UI Registration

    private func registerUI() {
        // 通过通知机制注册 UI，避免直接依赖 ETerm 类型
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("ETerm.RegisterSidebarTab"),
                object: nil,
                userInfo: [
                    "pluginId": "mcp-router",
                    "pluginName": "MCP Router",
                    "tabId": "mcp-router-settings",
                    "title": "MCP Router",
                    "icon": "server.rack",
                    "viewProvider": { () -> AnyView in
                        AnyView(MCPRouterSettingsView())
                    }
                ]
            )
        }
    }

    // MARK: - Control Methods

    public func start() {
        guard !isRunning else {
            statusMessage = "已在运行中"
            return
        }

        do {
            // 如果 router 尚未初始化，先初始化
            if router == nil {
                router = try MCPRouterBridge()
                loadServerConfigs()
            }

            // 设置模式
            try router?.setExposeManagementTools(fullMode)

            // 启动 HTTP 服务
            try router?.startServer(port: currentPort)
            isRunning = true
            isHttpServerRunning = true
            statusMessage = "运行中 (端口 \(currentPort))"
        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
        }
    }

    public func stop() {
        guard isRunning else { return }

        do {
            try router?.stopServer()
            isRunning = false
            isHttpServerRunning = false
            statusMessage = "已停止"
        } catch {
            statusMessage = "停止失败: \(error.localizedDescription)"
        }
    }

    public func restart() {
        stop()
        start()
    }

    public func setPort(_ port: UInt16) {
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }
        currentPort = port
        saveSettings()
        if wasRunning {
            start()
        }
    }

    public func updateAutoStart(_ enabled: Bool) {
        autoStart = enabled
        saveSettings()
    }

    public func updateFullMode(_ enabled: Bool) {
        fullMode = enabled
        try? router?.setExposeManagementTools(enabled)
        saveSettings()
    }

    /// 保存服务器配置到文件
    public func saveServerConfigs() {
        guard router != nil else { return }
        guard let servers = try? router?.listServers() else { return }

        do {
            let pluginDir = "\(NSHomeDirectory())/.eterm/plugins/McpRouter"
            try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(servers)
            let configPath = "\(pluginDir)/servers.json"
            try data.write(to: URL(fileURLWithPath: configPath))
        } catch {
            // 保存失败，静默处理
        }
    }

    // MARK: - Configuration

    private func loadSettings() {
        let defaults = UserDefaults.standard
        autoStart = defaults.bool(forKey: "mcpRouter.autoStart")
        fullMode = defaults.bool(forKey: "mcpRouter.fullMode")
        currentPort = UInt16(defaults.integer(forKey: "mcpRouter.port"))
        if currentPort == 0 {
            currentPort = 19104
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(autoStart, forKey: "mcpRouter.autoStart")
        defaults.set(fullMode, forKey: "mcpRouter.fullMode")
        defaults.set(Int(currentPort), forKey: "mcpRouter.port")
    }

    private func loadServerConfigs() {
        let configPath = "\(NSHomeDirectory())/.eterm/plugins/McpRouter/servers.json"
        guard FileManager.default.fileExists(atPath: configPath) else { return }

        do {
            let jsonContent = try String(contentsOfFile: configPath, encoding: .utf8)
            try router?.loadServersFromJSON(jsonContent)
        } catch {
            // 加载失败，静默处理
        }

        // 同时加载 workspaces.json（如果存在）
        let workspacePath = "\(NSHomeDirectory())/.eterm/plugins/McpRouter/workspaces.json"
        if FileManager.default.fileExists(atPath: workspacePath) {
            do {
                let jsonContent = try String(contentsOfFile: workspacePath, encoding: .utf8)
                try router?.loadWorkspacesFromJSON(jsonContent)
            } catch {
                // 加载失败，静默处理
            }
        }
    }
}
