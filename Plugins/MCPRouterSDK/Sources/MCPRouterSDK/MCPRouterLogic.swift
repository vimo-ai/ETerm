// MCPRouterLogic.swift
// MCPRouterSDK
//
// MCP Router 插件逻辑 - 在 Extension Host 进程中运行

import Foundation
import ETermKit

/// MCP Router 插件逻辑入口
@objc(MCPRouterLogic)
public final class MCPRouterLogic: NSObject, PluginLogic {

    public static var id: String { "com.eterm.mcp-router" }

    private var host: HostBridge?
    private var router: MCPRouterBridge?
    private var isRunning = false
    private var currentPort: UInt16 = 19104

    // Workspace storage
    private var workspaces: [WorkspaceConfig] = []

    private struct WorkspaceConfig: Codable {
        var token: String
        var name: String
        var projectPath: String
        var isDefault: Bool
        var serverOverrides: [String: Bool]
        var flattenOverrides: [String: Bool]

        init(token: String = UUID().uuidString.prefix(8).lowercased().description,
             name: String,
             projectPath: String,
             isDefault: Bool = false) {
            self.token = token
            self.name = name
            self.projectPath = projectPath
            self.isDefault = isDefault
            self.serverOverrides = [:]
            self.flattenOverrides = [:]
        }
    }

    public required override init() {
        super.init()
        print("[MCPRouterLogic] Initialized")
    }

    public func activate(host: HostBridge) {
        self.host = host
        print("[MCPRouterLogic] Activated")

        // 初始化日志
        MCPRouterBridge.initLogging()

        // 初始化 Router
        do {
            router = try MCPRouterBridge()
            print("[MCPRouterLogic] Router initialized, version: \(MCPRouterBridge.version)")

            // 加载服务器配置
            loadServerConfigs()

            // 加载工作区配置
            loadWorkspaces()

            // 自动启动
            start()
        } catch {
            print("[MCPRouterLogic] Failed to initialize router: \(error)")
            updateUI(error: error.localizedDescription)
        }
    }

    public func deactivate() {
        print("[MCPRouterLogic] Deactivating...")
        stop()
        router = nil
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        print("[MCPRouterLogic] Event: \(eventName)")
    }

    public func handleCommand(_ commandId: String) {
        print("[MCPRouterLogic] Command: \(commandId)")

        switch commandId {
        case "mcp-router.start":
            start()
        case "mcp-router.stop":
            stop()
        case "mcp-router.reload":
            reload()
        case "mcp-router.setPort":
            // 需要参数，通过 handleRequest 处理
            break
        case "mcp-router.setFullMode":
            // 需要参数，通过 handleRequest 处理
            break
        default:
            break
        }
    }

    /// 处理带参数的请求
    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        print("[MCPRouterLogic] Request: \(requestId) params: \(params)")

        switch requestId {
        case "getServers":
            return getServersResponse()

        case "addServer":
            return addServerFromParams(params)

        case "removeServer":
            guard let name = params["name"] as? String else {
                return ["success": false, "error": "Missing server name"]
            }
            return removeServerByName(name)

        case "updateServer":
            return updateServerFromParams(params)

        case "setServerEnabled":
            guard let name = params["name"] as? String,
                  let enabled = params["enabled"] as? Bool else {
                return ["success": false, "error": "Missing name or enabled"]
            }
            return setServerEnabledByName(name, enabled: enabled)

        case "setServerFlattenMode":
            guard let name = params["name"] as? String,
                  let flatten = params["flatten"] as? Bool else {
                return ["success": false, "error": "Missing name or flatten"]
            }
            return setServerFlattenModeByName(name, flatten: flatten)

        case "setPort":
            guard let port = params["port"] as? Int else {
                return ["success": false, "error": "Missing port"]
            }
            return setPortValue(UInt16(port))

        case "setFullMode":
            guard let fullMode = params["fullMode"] as? Bool else {
                return ["success": false, "error": "Missing fullMode"]
            }
            return setFullModeValue(fullMode)

        case "importServers":
            guard let json = params["json"] as? String else {
                return ["success": false, "error": "Missing json"]
            }
            return importServersFromJSON(json)

        case "exportServers":
            return exportServersToJSON()

        case "getWorkspaces":
            return getWorkspacesResponse()

        case "setWorkspaceServerEnabled":
            guard let token = params["token"] as? String,
                  let serverName = params["serverName"] as? String,
                  let enabled = params["enabled"] as? Bool else {
                return ["success": false, "error": "Missing params"]
            }
            return setWorkspaceServerEnabled(token: token, serverName: serverName, enabled: enabled)

        case "setWorkspaceFlattenMode":
            guard let token = params["token"] as? String,
                  let serverName = params["serverName"] as? String,
                  let flatten = params["flatten"] as? Bool else {
                return ["success": false, "error": "Missing params"]
            }
            return setWorkspaceFlattenMode(token: token, serverName: serverName, flatten: flatten)

        case "resetWorkspaceOverrides":
            guard let token = params["token"] as? String else {
                return ["success": false, "error": "Missing token"]
            }
            return resetWorkspaceOverrides(token: token)

        default:
            return ["success": false, "error": "Unknown request: \(requestId)"]
        }
    }

    // MARK: - Request Handlers

    private func getServersResponse() -> [String: Any] {
        guard let router = router,
              let servers = try? router.listServers() else {
            return ["success": true, "servers": []]
        }

        let serverList = servers.map { server -> [String: Any] in
            [
                "name": server.name,
                "type": server.serverType.rawValue,
                "enabled": server.enabled,
                "flattenMode": server.flattenMode,
                "description": server.description ?? "",
                "url": server.url ?? "",
                "command": server.command ?? "",
                "args": server.args ?? [],
                "env": server.env ?? [:]
            ]
        }
        return ["success": true, "servers": serverList]
    }

    private func addServerFromParams(_ params: [String: Any]) -> [String: Any] {
        guard let router = router,
              let name = params["name"] as? String,
              let type = params["type"] as? String else {
            return ["success": false, "error": "Missing required params"]
        }

        do {
            if type == "http" {
                guard let url = params["url"] as? String else {
                    return ["success": false, "error": "Missing url for HTTP server"]
                }
                let desc = params["description"] as? String ?? ""
                try router.addHTTPServer(name: name, url: url, description: desc)
            } else if type == "stdio" {
                guard let command = params["command"] as? String else {
                    return ["success": false, "error": "Missing command for stdio server"]
                }
                let args = params["args"] as? [String] ?? []
                let env = params["env"] as? [String: String] ?? [:]
                let config = MCPServerConfig.stdio(name: name, command: command, args: args, env: env)
                try router.addServer(config)
            }
            updateUI()
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func removeServerByName(_ name: String) -> [String: Any] {
        guard let router = router else {
            return ["success": false, "error": "Router not initialized"]
        }
        do {
            try router.removeServer(name: name)
            updateUI()
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func updateServerFromParams(_ params: [String: Any]) -> [String: Any] {
        guard let router = router,
              let name = params["name"] as? String else {
            return ["success": false, "error": "Missing server name"]
        }

        // 先删除旧的，再添加新的
        do {
            try router.removeServer(name: name)
        } catch {
            // 忽略删除错误
        }

        return addServerFromParams(params)
    }

    private func setServerEnabledByName(_ name: String, enabled: Bool) -> [String: Any] {
        guard let router = router else {
            return ["success": false, "error": "Router not initialized"]
        }
        do {
            try router.setServerEnabled(name: name, enabled: enabled)
            updateUI()
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func setServerFlattenModeByName(_ name: String, flatten: Bool) -> [String: Any] {
        guard let router = router else {
            return ["success": false, "error": "Router not initialized"]
        }
        do {
            try router.setServerFlattenMode(name: name, flatten: flatten)
            updateUI()
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func setPortValue(_ port: UInt16) -> [String: Any] {
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }
        currentPort = port
        if wasRunning {
            start()
        }
        updateUI()
        return ["success": true]
    }

    private func setFullModeValue(_ fullMode: Bool) -> [String: Any] {
        guard let router = router else {
            return ["success": false, "error": "Router not initialized"]
        }
        do {
            try router.setExposeManagementTools(fullMode)
            updateUI()
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func importServersFromJSON(_ json: String) -> [String: Any] {
        guard let router = router else {
            return ["success": false, "error": "Router not initialized"]
        }
        do {
            try router.loadServersFromJSON(json)
            updateUI()
            return ["success": true]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func exportServersToJSON() -> [String: Any] {
        guard let router = router,
              let servers = try? router.listServers() else {
            return ["success": true, "json": "[]"]
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(servers)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            return ["success": true, "json": json]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    // MARK: - Server Config

    private func loadServerConfigs() {
        guard let router = router else { return }

        // 从 Claude 配置加载服务器
        let claudeConfigPath = NSHomeDirectory() + "/.claude.json"

        if FileManager.default.fileExists(atPath: claudeConfigPath),
           let data = FileManager.default.contents(atPath: claudeConfigPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcpServers = json["mcpServers"] as? [String: Any] {

            for (name, config) in mcpServers {
                guard let configDict = config as? [String: Any] else { continue }

                // 跳过 mcp-router 自身
                if name == "mcp-router" { continue }

                do {
                    if let serverType = configDict["type"] as? String {
                        if serverType == "http", let url = configDict["url"] as? String {
                            try router.addHTTPServer(name: name, url: url)
                            print("[MCPRouterLogic] Added HTTP server: \(name)")
                        } else if serverType == "stdio",
                                  let command = configDict["command"] as? String {
                            let args = configDict["args"] as? [String] ?? []
                            let env = configDict["env"] as? [String: String] ?? [:]
                            let config = MCPServerConfig.stdio(
                                name: name,
                                command: command,
                                args: args,
                                env: env
                            )
                            try router.addServer(config)
                            print("[MCPRouterLogic] Added stdio server: \(name)")
                        }
                    }
                } catch {
                    print("[MCPRouterLogic] Failed to add server \(name): \(error)")
                }
            }
        }
    }

    // MARK: - Control

    private func start() {
        guard let router = router, !isRunning else { return }

        do {
            try router.startServer(port: currentPort)
            isRunning = true
            print("[MCPRouterLogic] Started on port \(currentPort)")
            updateUI()
        } catch {
            print("[MCPRouterLogic] Failed to start: \(error)")
            updateUI(error: error.localizedDescription)
        }
    }

    private func stop() {
        guard let router = router, isRunning else { return }

        do {
            try router.stopServer()
            isRunning = false
            print("[MCPRouterLogic] Stopped")
            updateUI()
        } catch {
            print("[MCPRouterLogic] Failed to stop: \(error)")
        }
    }

    private func reload() {
        stop()
        router = nil

        do {
            router = try MCPRouterBridge()
            loadServerConfigs()
            start()
        } catch {
            print("[MCPRouterLogic] Failed to reload: \(error)")
            updateUI(error: error.localizedDescription)
        }
    }

    // MARK: - UI

    private func updateUI(error: String? = nil) {
        var servers: [[String: Any]] = []
        if let router = router,
           let serverList = try? router.listServers() {
            servers = serverList.map { server in
                [
                    "name": server.name,
                    "type": server.serverType.rawValue,
                    "enabled": server.enabled,
                    "flattenMode": server.flattenMode,
                    "description": server.description ?? "",
                    "url": server.url ?? "",
                    "command": server.command ?? ""
                ]
            }
        }

        let statusMessage: String
        if let error = error {
            statusMessage = "Error: \(error)"
        } else if isRunning {
            statusMessage = "Running on port \(currentPort) (\(servers.count) servers)"
        } else {
            statusMessage = "Stopped"
        }

        host?.updateViewModel(Self.id, data: [
            "isRunning": isRunning,
            "port": Int(currentPort),
            "serverCount": servers.count,
            "servers": servers,
            "statusMessage": statusMessage,
            "version": MCPRouterBridge.version,
            "exposeManagementTools": router?.getExposeManagementTools() ?? false
        ])
    }

    // MARK: - Workspace Management

    private func loadWorkspaces() {
        let configPath = NSHomeDirectory() + "/.eterm/plugins/MCPRouter/workspaces.json"

        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath) else {
            // 创建默认工作区
            ensureDefaultWorkspace()
            return
        }

        do {
            workspaces = try JSONDecoder().decode([WorkspaceConfig].self, from: data)
            ensureDefaultWorkspace()
            print("[MCPRouterLogic] Loaded \(workspaces.count) workspaces")
        } catch {
            print("[MCPRouterLogic] Failed to load workspaces: \(error)")
            ensureDefaultWorkspace()
        }
    }

    private func saveWorkspaces() {
        let pluginDir = NSHomeDirectory() + "/.eterm/plugins/MCPRouter"
        let configPath = pluginDir + "/workspaces.json"

        do {
            try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(workspaces)
            try data.write(to: URL(fileURLWithPath: configPath))
        } catch {
            print("[MCPRouterLogic] Failed to save workspaces: \(error)")
        }
    }

    private func ensureDefaultWorkspace() {
        if !workspaces.contains(where: { $0.isDefault }) {
            let defaultWs = WorkspaceConfig(
                token: "default",
                name: "Default",
                projectPath: "",
                isDefault: true
            )
            workspaces.insert(defaultWs, at: 0)
            saveWorkspaces()
        }
    }

    private func getWorkspacesResponse() -> [String: Any] {
        let workspaceList = workspaces.map { ws -> [String: Any] in
            [
                "token": ws.token,
                "name": ws.name,
                "projectPath": ws.projectPath,
                "isDefault": ws.isDefault,
                "serverOverrides": ws.serverOverrides,
                "flattenOverrides": ws.flattenOverrides
            ]
        }
        return ["success": true, "workspaces": workspaceList]
    }

    private func setWorkspaceServerEnabled(token: String, serverName: String, enabled: Bool) -> [String: Any] {
        guard let index = workspaces.firstIndex(where: { $0.token == token }) else {
            return ["success": false, "error": "Workspace not found"]
        }

        workspaces[index].serverOverrides[serverName] = enabled
        saveWorkspaces()
        return ["success": true]
    }

    private func setWorkspaceFlattenMode(token: String, serverName: String, flatten: Bool) -> [String: Any] {
        guard let index = workspaces.firstIndex(where: { $0.token == token }) else {
            return ["success": false, "error": "Workspace not found"]
        }

        workspaces[index].flattenOverrides[serverName] = flatten
        saveWorkspaces()
        return ["success": true]
    }

    private func resetWorkspaceOverrides(token: String) -> [String: Any] {
        guard let index = workspaces.firstIndex(where: { $0.token == token }) else {
            return ["success": false, "error": "Workspace not found"]
        }

        workspaces[index].serverOverrides.removeAll()
        workspaces[index].flattenOverrides.removeAll()
        saveWorkspaces()
        return ["success": true]
    }
}
