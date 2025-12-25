//
//  MCPRouterIPCClient.swift
//  ETerm
//
//  MCP Router IPC 客户端 - 通过 IPC 调用 Extension Host 中的 MCPRouterLogic
//  替代原来直接调用 MCPRouterBridge 的方式
//

import Foundation

/// MCP Router IPC 客户端
///
/// 提供与 MCPRouterBridge 相同的 API，但内部通过 IPC 调用 Extension Host
@MainActor
final class MCPRouterIPCClient {

    static let shared = MCPRouterIPCClient()
    private let pluginId = "com.eterm.mcp-router"

    private init() {}

    // MARK: - Server Management

    /// 列出所有服务器
    func listServers() async throws -> [MCPServerConfigDTO] {
        let result = try await sendRequest("getServers")
        guard let serversData = result["servers"] as? [[String: Any]] else {
            return []
        }
        return serversData.compactMap { MCPServerConfigDTO(from: $0) }
    }

    /// 添加服务器
    func addServer(_ config: MCPServerConfigDTO) async throws {
        var params = config.toDictionary()
        let result = try await sendRequest("addServer", params: params)
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 移除服务器
    func removeServer(name: String) async throws {
        let result = try await sendRequest("removeServer", params: ["name": name])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 设置服务器启用状态
    func setServerEnabled(name: String, enabled: Bool) async throws {
        let result = try await sendRequest("setServerEnabled", params: ["name": name, "enabled": enabled])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 设置服务器平铺模式
    func setServerFlattenMode(name: String, flatten: Bool) async throws {
        let result = try await sendRequest("setServerFlattenMode", params: ["name": name, "flatten": flatten])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    // MARK: - Import/Export

    /// 导入服务器配置
    func importServers(json: String) async throws {
        let result = try await sendRequest("importServers", params: ["json": json])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 导出服务器配置
    func exportServers() async throws -> String {
        let result = try await sendRequest("exportServers")
        return result["json"] as? String ?? "[]"
    }

    // MARK: - Settings

    /// 设置端口
    func setPort(_ port: Int) async throws {
        let result = try await sendRequest("setPort", params: ["port": port])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 设置 Full 模式
    func setFullMode(_ fullMode: Bool) async throws {
        let result = try await sendRequest("setFullMode", params: ["fullMode": fullMode])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    // MARK: - Workspace Management

    /// 获取所有工作区
    func listWorkspaces() async throws -> [MCPWorkspaceDTO] {
        let result = try await sendRequest("getWorkspaces")
        guard let workspacesData = result["workspaces"] as? [[String: Any]] else {
            return []
        }
        return workspacesData.compactMap { MCPWorkspaceDTO(from: $0) }
    }

    /// 设置工作区的服务器启用状态
    func setWorkspaceServerEnabled(token: String, serverName: String, enabled: Bool) async throws {
        let result = try await sendRequest("setWorkspaceServerEnabled", params: [
            "token": token,
            "serverName": serverName,
            "enabled": enabled
        ])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 设置工作区的服务器平铺模式
    func setWorkspaceFlattenMode(token: String, serverName: String, flatten: Bool) async throws {
        let result = try await sendRequest("setWorkspaceFlattenMode", params: [
            "token": token,
            "serverName": serverName,
            "flatten": flatten
        ])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    /// 重置工作区覆盖
    func resetWorkspaceOverrides(token: String) async throws {
        let result = try await sendRequest("resetWorkspaceOverrides", params: ["token": token])
        if let error = result["error"] as? String {
            throw MCPRouterIPCError.operationFailed(error)
        }
    }

    // MARK: - Commands

    /// 启动服务
    func start() async throws {
        try await sendCommand("start")
    }

    /// 停止服务
    func stop() async throws {
        try await sendCommand("stop")
    }

    /// 重载服务
    func reload() async throws {
        try await sendCommand("reload")
    }

    // MARK: - Private

    private func sendRequest(_ requestId: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        return try await ExtensionHostManager.shared.sendRequest(
            pluginId: pluginId,
            requestId: requestId,
            params: params
        )
    }

    private func sendCommand(_ command: String) async throws {
        try await ExtensionHostManager.shared.getBridge()?.sendCommand(
            pluginId: pluginId,
            commandId: "mcp-router.\(command)"
        )
    }
}

// MARK: - DTO

/// 服务器配置 DTO（用于 IPC 传输）
struct MCPServerConfigDTO: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let serverType: String  // "http" or "stdio"
    let enabled: Bool
    let flattenMode: Bool
    let description: String?
    let url: String?
    let headers: [String: String]?
    let command: String?
    let args: [String]?
    let env: [String: String]?

    init(from dict: [String: Any]) {
        self.name = dict["name"] as? String ?? ""
        self.serverType = dict["type"] as? String ?? "http"
        self.enabled = dict["enabled"] as? Bool ?? true
        self.flattenMode = dict["flattenMode"] as? Bool ?? false
        self.description = dict["description"] as? String
        self.url = dict["url"] as? String
        self.headers = dict["headers"] as? [String: String]
        self.command = dict["command"] as? String
        self.args = dict["args"] as? [String]
        self.env = dict["env"] as? [String: String]
    }

    init(name: String, serverType: String, enabled: Bool = true, flattenMode: Bool = false,
         description: String? = nil, url: String? = nil, headers: [String: String]? = nil,
         command: String? = nil, args: [String]? = nil, env: [String: String]? = nil) {
        self.name = name
        self.serverType = serverType
        self.enabled = enabled
        self.flattenMode = flattenMode
        self.description = description
        self.url = url
        self.headers = headers
        self.command = command
        self.args = args
        self.env = env
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "type": serverType,
            "enabled": enabled,
            "flattenMode": flattenMode
        ]
        if let description = description { dict["description"] = description }
        if let url = url { dict["url"] = url }
        if let headers = headers { dict["headers"] = headers }
        if let command = command { dict["command"] = command }
        if let args = args { dict["args"] = args }
        if let env = env { dict["env"] = env }
        return dict
    }

    static func http(name: String, url: String, headers: [String: String]? = nil, description: String? = nil) -> MCPServerConfigDTO {
        MCPServerConfigDTO(name: name, serverType: "http", description: description, url: url, headers: headers)
    }

    static func stdio(name: String, command: String, args: [String] = [], env: [String: String] = [:], description: String? = nil) -> MCPServerConfigDTO {
        MCPServerConfigDTO(name: name, serverType: "stdio", description: description, command: command, args: args, env: env)
    }
}

// MARK: - Workspace DTO

/// 工作区配置 DTO（用于 IPC 传输）
struct MCPWorkspaceDTO: Identifiable, Hashable {
    var id: String { token }
    let token: String
    let name: String
    let projectPath: String
    let isDefault: Bool
    let serverOverrides: [String: Bool]
    let flattenOverrides: [String: Bool]

    init(from dict: [String: Any]) {
        self.token = dict["token"] as? String ?? ""
        self.name = dict["name"] as? String ?? ""
        self.projectPath = dict["projectPath"] as? String ?? ""
        self.isDefault = dict["isDefault"] as? Bool ?? false
        self.serverOverrides = dict["serverOverrides"] as? [String: Bool] ?? [:]
        self.flattenOverrides = dict["flattenOverrides"] as? [String: Bool] ?? [:]
    }

    /// 获取 Server 的有效启用状态
    func isServerEnabled(_ serverName: String, serverConfig: MCPServerConfigDTO?, defaultWorkspace: MCPWorkspaceDTO?) -> Bool {
        if let override = serverOverrides[serverName] {
            return override
        }
        if isDefault {
            return serverConfig?.enabled ?? true
        }
        if let defaultWs = defaultWorkspace {
            return defaultWs.serverOverrides[serverName] ?? (serverConfig?.enabled ?? true)
        }
        return serverConfig?.enabled ?? true
    }

    /// 检查 Server 启用状态是否被用户修改过
    func isServerCustomized(_ serverName: String) -> Bool {
        serverOverrides[serverName] != nil
    }

    /// 获取 Server 的有效平铺模式状态
    func isFlattenEnabled(_ serverName: String, serverConfig: MCPServerConfigDTO?, defaultWorkspace: MCPWorkspaceDTO?) -> Bool {
        if let override = flattenOverrides[serverName] {
            return override
        }
        if isDefault {
            return serverConfig?.flattenMode ?? false
        }
        if let defaultWs = defaultWorkspace {
            return defaultWs.flattenOverrides[serverName] ?? (serverConfig?.flattenMode ?? false)
        }
        return serverConfig?.flattenMode ?? false
    }

    /// 检查 Server 平铺模式是否被用户修改过
    func isFlattenCustomized(_ serverName: String) -> Bool {
        flattenOverrides[serverName] != nil
    }
}

// MARK: - Error

enum MCPRouterIPCError: Error, LocalizedError {
    case operationFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            return message
        case .notConnected:
            return "Not connected to Extension Host"
        }
    }
}
