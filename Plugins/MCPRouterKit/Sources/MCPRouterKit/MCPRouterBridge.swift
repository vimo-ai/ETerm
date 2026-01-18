//
//  MCPRouterBridge.swift
//  MCPRouterKit
//
//  MCP Router Rust Core 的 Swift 封装

import Foundation
import MCPRouterCore
import ETermKit

// MARK: - DTO Types

/// 服务器配置 DTO
public struct MCPServerConfigDTO: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let serverType: String  // "http" or "stdio"
    public var enabled: Bool
    public var flattenMode: Bool
    public let description: String?
    public let url: String?
    public let headers: [String: String]?
    public let command: String?
    public let args: [String]?
    public let env: [String: String]?

    public init(from dict: [String: Any]) {
        self.name = dict["name"] as? String ?? ""
        self.serverType = dict["type"] as? String ?? "http"
        self.enabled = dict["is_enabled"] as? Bool ?? true
        self.flattenMode = dict["flatten_mode"] as? Bool ?? false
        self.description = dict["description"] as? String
        self.url = dict["url"] as? String
        self.headers = dict["headers"] as? [String: String]
        self.command = dict["command"] as? String
        self.args = dict["args"] as? [String]
        self.env = dict["env"] as? [String: String]
    }

    public init(name: String, serverType: String, enabled: Bool = true, flattenMode: Bool = false,
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

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "type": serverType,
            "is_enabled": enabled,
            "flatten_mode": flattenMode
        ]
        if let description = description { dict["description"] = description }
        if let url = url { dict["url"] = url }
        if let headers = headers { dict["headers"] = headers }
        if let command = command { dict["command"] = command }
        if let args = args { dict["args"] = args }
        if let env = env { dict["env"] = env }
        return dict
    }

    public static func http(name: String, url: String, headers: [String: String]? = nil, description: String? = nil) -> MCPServerConfigDTO {
        MCPServerConfigDTO(name: name, serverType: "http", description: description, url: url, headers: headers)
    }

    public static func stdio(name: String, command: String, args: [String] = [], env: [String: String] = [:], description: String? = nil) -> MCPServerConfigDTO {
        MCPServerConfigDTO(name: name, serverType: "stdio", description: description, command: command, args: args, env: env)
    }
}

/// 工作区配置 DTO
public struct MCPWorkspaceDTO: Identifiable, Hashable {
    public var id: String { token }
    public let token: String
    public let name: String
    public let projectPath: String
    public let isDefault: Bool
    public let serverOverrides: [String: Bool]
    public let flattenOverrides: [String: Bool]

    public init(from dict: [String: Any]) {
        self.token = dict["token"] as? String ?? ""
        self.name = dict["name"] as? String ?? ""
        self.projectPath = dict["projectPath"] as? String ?? ""
        self.isDefault = dict["isDefault"] as? Bool ?? false
        self.serverOverrides = dict["serverOverrides"] as? [String: Bool] ?? [:]
        self.flattenOverrides = dict["flattenOverrides"] as? [String: Bool] ?? [:]
    }

    public init(token: String, name: String, projectPath: String, isDefault: Bool = false,
                serverOverrides: [String: Bool] = [:], flattenOverrides: [String: Bool] = [:]) {
        self.token = token
        self.name = name
        self.projectPath = projectPath
        self.isDefault = isDefault
        self.serverOverrides = serverOverrides
        self.flattenOverrides = flattenOverrides
    }

    public func toDictionary() -> [String: Any] {
        return [
            "token": token,
            "name": name,
            "project_path": projectPath,
            "is_default": isDefault,
            "server_overrides": serverOverrides,
            "flatten_overrides": flattenOverrides
        ]
    }

    public func isServerEnabled(_ serverName: String, serverConfig: MCPServerConfigDTO?, defaultWorkspace: MCPWorkspaceDTO?) -> Bool {
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

    public func isServerCustomized(_ serverName: String) -> Bool {
        serverOverrides[serverName] != nil
    }

    public func isFlattenEnabled(_ serverName: String, serverConfig: MCPServerConfigDTO?, defaultWorkspace: MCPWorkspaceDTO?) -> Bool {
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

    public func isFlattenCustomized(_ serverName: String) -> Bool {
        flattenOverrides[serverName] != nil
    }
}

// MARK: - Bridge

/// MCP Router Bridge - 封装 Rust FFI 调用
@MainActor
public final class MCPRouterBridge {

    public static let shared = MCPRouterBridge()

    private var handle: OpaquePointer?

    private init() {
        handle = mcp_router_create()
        // 从所有配置源加载服务器（claude.json + servers.json）
        loadAllServers()
        // 从文件加载 workspaces
        loadWorkspacesFromFile()
    }

    deinit {
        if let handle = handle {
            mcp_router_destroy(handle)
        }
    }

    // MARK: - Persistence (FFI)

    /// 从所有配置源加载服务器 (claude.json + servers.json)
    private func loadAllServers() {
        guard let handle = handle else { return }

        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_load_all_servers(handle, &errorPtr)

        if !success, let errorPtr = errorPtr {
            let error = String(cString: errorPtr)
            mcp_router_free_string(errorPtr)
            logError("[MCPRouter] Failed to load servers: \(error)")
        }
    }

    /// 从文件加载 Workspaces
    private func loadWorkspacesFromFile() {
        guard let handle = handle else { return }

        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_load_workspaces_from_file(handle, &errorPtr)

        if !success, let errorPtr = errorPtr {
            let error = String(cString: errorPtr)
            mcp_router_free_string(errorPtr)
            logError("[MCPRouter] Failed to load workspaces: \(error)")
        }
    }

    /// 保存 Workspaces 到文件
    public func saveWorkspacesToFile() throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_save_workspaces_to_file(handle, &errorPtr)

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 检查 mcp-router 是否已安装到 Claude 全局配置
    public static func isInstalledToClaudeGlobal() -> Bool {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = mcp_router_is_installed_to_claude_global(&errorPtr)
        if let errorPtr = errorPtr {
            mcp_router_free_string(errorPtr)
        }
        return result
    }

    /// 安装 mcp-router 到 Claude 全局配置
    public static func installToClaudeGlobal(port: UInt16) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_install_to_claude_global(port, &errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 从 Claude 全局配置卸载 mcp-router
    public static func uninstallFromClaudeGlobal() throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_uninstall_from_claude_global(&errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    // MARK: - Gemini Global Config

    /// 检查 mcp-router 是否已安装到 Gemini 全局配置
    public static func isInstalledToGeminiGlobal() -> Bool {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = mcp_router_is_installed_to_gemini_global(&errorPtr)
        if let errorPtr = errorPtr {
            mcp_router_free_string(errorPtr)
        }
        return result
    }

    /// 安装 mcp-router 到 Gemini 全局配置
    public static func installToGeminiGlobal(port: UInt16) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_install_to_gemini_global(port, &errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 从 Gemini 全局配置卸载 mcp-router
    public static func uninstallFromGeminiGlobal() throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_uninstall_from_gemini_global(&errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    // MARK: - OpenCode Global Config

    /// 检查 mcp-router 是否已安装到 OpenCode 全局配置
    public static func isInstalledToOpenCodeGlobal() -> Bool {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = mcp_router_is_installed_to_opencode_global(&errorPtr)
        if let errorPtr = errorPtr {
            mcp_router_free_string(errorPtr)
        }
        return result
    }

    /// 安装 mcp-router 到 OpenCode 全局配置
    public static func installToOpenCodeGlobal(port: UInt16) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_install_to_opencode_global(port, &errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 从 OpenCode 全局配置卸载 mcp-router
    public static func uninstallFromOpenCodeGlobal() throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_uninstall_from_opencode_global(&errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    // MARK: - Codex Global Config

    /// 检查 mcp-router 是否已安装到 Codex 全局配置
    public static func isInstalledToCodexGlobal() -> Bool {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = mcp_router_is_installed_to_codex_global(&errorPtr)
        if let errorPtr = errorPtr {
            mcp_router_free_string(errorPtr)
        }
        return result
    }

    /// 安装 mcp-router 到 Codex 全局配置
    public static func installToCodexGlobal(port: UInt16) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_install_to_codex_global(port, &errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 从 Codex 全局配置卸载 mcp-router
    public static func uninstallFromCodexGlobal() throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_uninstall_from_codex_global(&errorPtr)

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 添加服务器并持久化到配置文件
    /// - Parameters:
    ///   - config: 服务器配置
    ///   - target: 目标配置 - "global" 或 "project:/path/to/project"
    public func addServerAndPersist(_ config: MCPServerConfigDTO, target: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let dict = config.toDictionary()
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = jsonString.withCString { jsonPtr in
            target.withCString { targetPtr in
                mcp_router_add_server_and_persist(handle, jsonPtr, targetPtr, &errorPtr)
            }
        }

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 移除服务器并从配置文件持久化删除
    /// - Parameters:
    ///   - name: 服务器名称
    ///   - target: 目标配置 - "global" 或 "project:/path/to/project"
    public func removeServerAndPersist(name: String, target: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = name.withCString { namePtr in
            target.withCString { targetPtr in
                mcp_router_remove_server_and_persist(handle, namePtr, targetPtr, &errorPtr)
            }
        }

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 安装 mcp-router 到项目配置
    public static func installToProject(path: String, token: String, port: UInt16) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = path.withCString { pathPtr in
            token.withCString { tokenPtr in
                mcp_router_install_to_project(pathPtr, tokenPtr, port, &errorPtr)
            }
        }

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 从项目配置卸载 mcp-router
    public static func uninstallFromProject(path: String) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = path.withCString { pathPtr in
            mcp_router_uninstall_from_project(pathPtr, &errorPtr)
        }

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 获取项目配置中的 Workspace Token
    public static func getProjectToken(path: String) -> String? {
        var errorPtr: UnsafeMutablePointer<CChar>?

        let tokenPtr = path.withCString { pathPtr in
            mcp_router_get_project_token(pathPtr, &errorPtr)
        }

        if let errorPtr = errorPtr {
            mcp_router_free_string(errorPtr)
        }

        guard let tokenPtr = tokenPtr else {
            return nil
        }

        let token = String(cString: tokenPtr)
        mcp_router_free_string(tokenPtr)
        return token
    }

    /// 加载应用设置（从 ~/.vimo/mcp-router/settings.json）
    public static func loadSettings() -> MCPRouterSettings? {
        var errorPtr: UnsafeMutablePointer<CChar>?
        guard let jsonPtr = mcp_router_load_settings(&errorPtr) else {
            if let errorPtr = errorPtr {
                mcp_router_free_string(errorPtr)
            }
            return nil
        }

        let jsonString = String(cString: jsonPtr)
        mcp_router_free_string(jsonPtr)

        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return MCPRouterSettings(
            serverPort: dict["server_port"] as? Int ?? 19104,
            exposeManagementTools: dict["expose_management_tools"] as? Bool ?? false
        )
    }

    /// 保存应用设置
    public static func saveSettings(_ settings: MCPRouterSettings) throws {
        let dict: [String: Any] = [
            "server_port": settings.serverPort,
            "expose_management_tools": settings.exposeManagementTools
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MCPRouterError.operationFailed("Failed to encode settings")
        }

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = jsonString.withCString { jsonPtr in
            mcp_router_save_settings(jsonPtr, &errorPtr)
        }

        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }

    /// 初始化日志（启动时调用一次）
    public static func initLogging() {
        mcp_router_init_logging()
    }

    /// 获取库版本
    public static var version: String {
        guard let cStr = mcp_router_version() else {
            return "unknown"
        }
        let version = String(cString: cStr)
        mcp_router_free_string(cStr)
        return version
    }

    // MARK: - Server Management

    /// 批量加载服务器（会替换现有列表）
    public func loadServers(_ servers: [MCPServerConfigDTO]) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let array = servers.map { $0.toDictionary() }
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = jsonString.withCString { jsonPtr in
            mcp_router_load_servers_json(handle, jsonPtr, &errorPtr)
        }

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 列出所有服务器
    public func listServers() throws -> [MCPServerConfigDTO] {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        guard let jsonPtr = mcp_router_list_servers(handle) else {
            return []
        }

        let jsonString = String(cString: jsonPtr)
        mcp_router_free_string(jsonPtr)

        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { MCPServerConfigDTO(from: $0) }
    }

    /// 添加 HTTP 服务器
    public func addHTTPServer(name: String, url: String, description: String = "") throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = name.withCString { namePtr in
            url.withCString { urlPtr in
                description.withCString { descPtr in
                    mcp_router_add_http_server(handle, namePtr, urlPtr, descPtr, &errorPtr)
                }
            }
        }

        try checkResult(success: success, errorPtr: errorPtr)
            }

    /// 添加服务器（JSON 格式）
    public func addServer(_ config: MCPServerConfigDTO) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let dict = config.toDictionary()
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = jsonString.withCString { jsonPtr in
            mcp_router_add_server_json(handle, jsonPtr, &errorPtr)
        }

        try checkResult(success: success, errorPtr: errorPtr)
            }

    /// 移除服务器
    public func removeServer(name: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = name.withCString { namePtr in
            mcp_router_remove_server(handle, namePtr, &errorPtr)
        }

        try checkResult(success: success, errorPtr: errorPtr)
            }

    /// 设置服务器启用状态
    public func setServerEnabled(name: String, enabled: Bool) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = name.withCString { namePtr in
            mcp_router_set_server_enabled(handle, namePtr, enabled, &errorPtr)
        }

        try checkResult(success: success, errorPtr: errorPtr)
            }

    /// 设置服务器平铺模式
    public func setServerFlattenMode(name: String, flatten: Bool) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = name.withCString { namePtr in
            mcp_router_set_server_flatten_mode(handle, namePtr, flatten, &errorPtr)
        }

        try checkResult(success: success, errorPtr: errorPtr)
            }

    // MARK: - Workspace Management

    /// 加载工作区（JSON 格式）
    public func loadWorkspaces(_ workspaces: [MCPWorkspaceDTO]) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let array = workspaces.map { $0.toDictionary() }
        let jsonData = try JSONSerialization.data(withJSONObject: array)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

        var errorPtr: UnsafeMutablePointer<CChar>?

        let success = jsonString.withCString { jsonPtr in
            mcp_router_load_workspaces_json(handle, jsonPtr, &errorPtr)
        }

        try checkResult(success: success, errorPtr: errorPtr)
    }

    // MARK: - HTTP Server Control

    /// 启动 HTTP 服务
    public func startServer(port: UInt16) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_start_server(handle, port, &errorPtr)

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 停止 HTTP 服务
    public func stopServer() throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_stop_server(handle, &errorPtr)

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 获取状态
    public func getStatus() -> MCPRouterStatus? {
        guard let handle = handle else {
            return nil
        }

        guard let jsonPtr = mcp_router_get_status(handle) else {
            return nil
        }

        let jsonString = String(cString: jsonPtr)
        mcp_router_free_string(jsonPtr)

        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return MCPRouterStatus(
            isRunning: dict["is_running"] as? Bool ?? false,
            serverCount: dict["server_count"] as? Int ?? 0,
            enabledServerCount: dict["enabled_server_count"] as? Int ?? 0
        )
    }

    // MARK: - Settings

    /// 设置是否暴露管理工具（Full 模式）
    public func setExposeManagementTools(_ expose: Bool) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = mcp_router_set_expose_management_tools(handle, expose, &errorPtr)

        try checkResult(success: success, errorPtr: errorPtr)
    }

    /// 获取是否暴露管理工具
    public func getExposeManagementTools() -> Bool {
        guard let handle = handle else {
            return false
        }
        return mcp_router_get_expose_management_tools(handle)
    }

    // MARK: - Async Tool Calls (FFI-based, no HTTP)

    /// 异步调用工具（直接通过 FFI，不经过 HTTP）
    /// - Parameters:
    ///   - serverName: 服务器名称
    ///   - toolName: 工具名称
    ///   - arguments: 工具参数
    ///   - workspaceToken: 工作区 token（可选）
    ///   - timeout: 超时时间（秒，0 使用默认 120 秒）
    /// - Returns: JSON 格式的工具调用结果
    public func callToolAsync(
        serverName: String,
        toolName: String,
        arguments: [String: Any],
        workspaceToken: String? = nil,
        timeout: UInt32 = 0
    ) async throws -> String {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let argumentsData = try JSONSerialization.data(withJSONObject: arguments)
        guard let argumentsJson = String(data: argumentsData, encoding: .utf8) else {
            throw MCPRouterError.operationFailed("Failed to serialize arguments")
        }

        return try await withCheckedThrowingContinuation { continuation in
            // 将 continuation 包装成不透明指针
            let continuationPtr = Unmanaged.passRetained(
                ContinuationBox(continuation: continuation)
            ).toOpaque()

            var errorPtr: UnsafeMutablePointer<CChar>?

            let success = serverName.withCString { serverPtr in
                toolName.withCString { toolPtr in
                    argumentsJson.withCString { argsPtr in
                        if let token = workspaceToken {
                            return token.withCString { tokenPtr in
                                mcp_router_call_tool_async(
                                    handle,
                                    serverPtr,
                                    toolPtr,
                                    argsPtr,
                                    tokenPtr,
                                    timeout,
                                    toolCallbackHandler,
                                    continuationPtr,
                                    &errorPtr
                                )
                            }
                        } else {
                            return mcp_router_call_tool_async(
                                handle,
                                serverPtr,
                                toolPtr,
                                argsPtr,
                                nil,
                                timeout,
                                toolCallbackHandler,
                                continuationPtr,
                                &errorPtr
                            )
                        }
                    }
                }
            }

            if !success {
                // 启动失败，需要释放 continuation
                let box = Unmanaged<ContinuationBox>.fromOpaque(continuationPtr).takeRetainedValue()
                let message: String
                if let errorPtr = errorPtr {
                    message = String(cString: errorPtr)
                    mcp_router_free_string(errorPtr)
                } else {
                    message = "Failed to start async call"
                }
                box.continuation.resume(throwing: MCPRouterError.operationFailed(message))
            }
        }
    }

    /// 异步列出服务器工具（直接通过 FFI）
    public func listToolsAsync(
        serverName: String,
        workspaceToken: String? = nil,
        timeout: UInt32 = 0
    ) async throws -> String {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationPtr = Unmanaged.passRetained(
                ContinuationBox(continuation: continuation)
            ).toOpaque()

            var errorPtr: UnsafeMutablePointer<CChar>?

            let success = serverName.withCString { serverPtr in
                if let token = workspaceToken {
                    return token.withCString { tokenPtr in
                        mcp_router_list_tools_async(
                            handle,
                            serverPtr,
                            tokenPtr,
                            timeout,
                            toolCallbackHandler,
                            continuationPtr,
                            &errorPtr
                        )
                    }
                } else {
                    return mcp_router_list_tools_async(
                        handle,
                        serverPtr,
                        nil,
                        timeout,
                        toolCallbackHandler,
                        continuationPtr,
                        &errorPtr
                    )
                }
            }

            if !success {
                let box = Unmanaged<ContinuationBox>.fromOpaque(continuationPtr).takeRetainedValue()
                let message: String
                if let errorPtr = errorPtr {
                    message = String(cString: errorPtr)
                    mcp_router_free_string(errorPtr)
                } else {
                    message = "Failed to start async list"
                }
                box.continuation.resume(throwing: MCPRouterError.operationFailed(message))
            }
        }
    }

    // MARK: - Private Helpers

    private func checkResult(success: Bool, errorPtr: UnsafeMutablePointer<CChar>?) throws {
        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                mcp_router_free_string(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }
}

// MARK: - Async Callback Support

/// 用于包装 continuation 的盒子类
private final class ContinuationBox {
    let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }
}

/// FFI 回调处理函数
private let toolCallbackHandler: McpToolCallback = { context, success, resultJson, errorMessage in
    guard let context = context else { return }

    // 取回 continuation（并释放引用）
    let box = Unmanaged<ContinuationBox>.fromOpaque(context).takeRetainedValue()

    if success {
        let result: String
        if let resultJson = resultJson {
            result = String(cString: resultJson)
        } else {
            result = "{}"
        }
        box.continuation.resume(returning: result)
    } else {
        let message: String
        if let errorMessage = errorMessage {
            message = String(cString: errorMessage)
        } else {
            message = "Unknown error"
        }
        box.continuation.resume(throwing: MCPRouterError.operationFailed(message))
    }
}

// MARK: - Settings

public struct MCPRouterSettings {
    public let serverPort: Int
    public let exposeManagementTools: Bool

    public init(serverPort: Int = 19104, exposeManagementTools: Bool = false) {
        self.serverPort = serverPort
        self.exposeManagementTools = exposeManagementTools
    }
}

// MARK: - Status

public struct MCPRouterStatus {
    public let isRunning: Bool
    public let serverCount: Int
    public let enabledServerCount: Int
}

// MARK: - Errors

public enum MCPRouterError: Error, LocalizedError {
    case invalidHandle
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHandle:
            return "Invalid router handle"
        case .operationFailed(let message):
            return message
        }
    }
}
