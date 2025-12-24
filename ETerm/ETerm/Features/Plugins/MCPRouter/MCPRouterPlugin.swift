//
//  MCPRouterPlugin.swift
//  ETerm
//
//  MCP Router 插件 - 在 ETerm 中运行 MCP Router 服务
//

import Foundation
import AppKit
import Combine
import SwiftUI

final class MCPRouterPlugin: Plugin, ObservableObject {
    static let id = "mcp-router"
    static let name = "MCP Router"
    static let version = "1.0.0"

    // MARK: - Published Properties (for UI binding)

    @Published private(set) var isRunning = false
    @Published private(set) var currentPort: UInt16 = 19104
    @Published private(set) var statusMessage = "未启动"
    @Published var autoStart = true
    @Published var fullMode = false  // Light/Full 模式

    // MARK: - Private Properties

    private var router: MCPRouterBridge?
    private weak var context: PluginContext?

    /// 单例访问（供设置界面使用）
    static var shared: MCPRouterPlugin?

    required init() {
        Self.shared = self
        loadSettings()
    }

    func activate(context: PluginContext) {
        self.context = context

        // 初始化日志
        MCPRouterBridge.initLogging()

        // 注册服务
        let service: MCPRouterService = MCPRouterServiceImpl(plugin: self)
        context.services.register(service, from: Self.id)

        // 注册侧边栏设置入口
        registerSidebarTabs(context: context)

        // 自动启动
        if autoStart {
            start()
        }

    }

    private func registerSidebarTabs(context: PluginContext) {
        let settingsTab = SidebarTab(
            id: "mcp-router-settings",
            title: "MCP Router",
            icon: "server.rack"
        ) {
            AnyView(MCPRouterSettingsView())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: settingsTab)
    }

    func deactivate() {
        stop()
        router = nil
        Self.shared = nil
        logInfo("[MCPRouter] Plugin deactivated")
    }

    // MARK: - Public Control Methods

    func start() {
        guard !isRunning else {
            statusMessage = "已在运行中"
            return
        }

        do {
            router = try MCPRouterBridge()

            // 加载服务器配置
            loadServerConfigs()

            // 设置 Full Mode
            try router?.setExposeManagementTools(fullMode)

            // 启动 HTTP 服务
            try router?.startServer(port: currentPort)
            isRunning = true
            statusMessage = "运行中 (端口 \(currentPort))"

        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
            logError("[MCPRouter] Failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else {
            statusMessage = "未在运行"
            return
        }

        do {
            try router?.stopServer()
            isRunning = false
            statusMessage = "已停止"
            logInfo("[MCPRouter] Server stopped")
        } catch {
            statusMessage = "停止失败: \(error.localizedDescription)"
            logError("[MCPRouter] Failed to stop: \(error.localizedDescription)")
        }
    }

    func restart() {
        stop()
        start()
    }

    func setPort(_ port: UInt16) {
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

    // MARK: - Settings Persistence

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let port = defaults.object(forKey: "MCPRouter.port") as? UInt16, port > 0 {
            currentPort = port
        }
        autoStart = defaults.bool(forKey: "MCPRouter.autoStart")
        fullMode = defaults.bool(forKey: "MCPRouter.fullMode")
        // 默认开启自动启动
        if defaults.object(forKey: "MCPRouter.autoStart") == nil {
            autoStart = true
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(currentPort, forKey: "MCPRouter.port")
        defaults.set(autoStart, forKey: "MCPRouter.autoStart")
        defaults.set(fullMode, forKey: "MCPRouter.fullMode")
    }

    func updateAutoStart(_ enabled: Bool) {
        autoStart = enabled
        saveSettings()
    }

    func updateFullMode(_ enabled: Bool) {
        fullMode = enabled
        try? router?.setExposeManagementTools(enabled)
        saveSettings()
    }

    // MARK: - Server Config

    private func loadServerConfigs() {
        let configPath = ETermPaths.mcpRouterServers
        guard FileManager.default.fileExists(atPath: configPath) else { return }

        do {
            let jsonContent = try String(contentsOfFile: configPath, encoding: .utf8)
            try router?.loadServersFromJSON(jsonContent)
            logDebug("[MCPRouter] Loaded server configs")
        } catch {
            logWarn("[MCPRouter] Failed to load server configs: \(error)")
        }
    }

    /// 保存服务器配置到文件
    func saveServerConfigs() {
        guard let servers = try? router?.listServers() else { return }

        do {
            try ETermPaths.ensureDirectory(ETermPaths.mcpRouterPlugin)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(servers)
            try data.write(to: URL(fileURLWithPath: ETermPaths.mcpRouterServers))
        } catch {
            logWarn("[MCPRouter] Failed to save server configs: \(error)")
        }
    }

    // MARK: - Info

    var port: UInt16 { currentPort }
    var running: Bool { isRunning }
    var version: String { MCPRouterBridge.version }

    var endpointURL: String {
        "http://localhost:\(currentPort)"
    }

    /// 暴露 Bridge 给设置界面使用
    var routerBridge: MCPRouterBridge? { router }
}

// MARK: - Service Protocol

/// MCP Router 服务协议
protocol MCPRouterService {
    var isRunning: Bool { get }
    var port: UInt16 { get }
    var endpointURL: String { get }
    func start()
    func stop()
    func restart()
}

/// MCP Router 服务实现
private class MCPRouterServiceImpl: MCPRouterService {
    private weak var plugin: MCPRouterPlugin?

    init(plugin: MCPRouterPlugin?) {
        self.plugin = plugin
    }

    var isRunning: Bool {
        plugin?.running ?? false
    }

    var port: UInt16 {
        plugin?.port ?? 19104
    }

    var endpointURL: String {
        plugin?.endpointURL ?? "http://localhost:19104"
    }

    func start() {
        plugin?.start()
    }

    func stop() {
        plugin?.stop()
    }

    func restart() {
        plugin?.restart()
    }
}
