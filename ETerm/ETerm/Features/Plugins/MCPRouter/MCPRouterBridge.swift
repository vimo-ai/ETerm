//
//  MCPRouterBridge.swift
//  ETerm
//
//  MCP Router Rust Core 的 Swift 桥接层
//

import Foundation

// MARK: - Data Models

/// 服务器类型
enum MCPServerType: String, Codable {
    case http = "http"
    case stdio = "stdio"
}

/// 服务器配置
struct MCPServerConfig: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let serverType: MCPServerType
    let enabled: Bool
    let description: String?
    let flattenMode: Bool

    // HTTP 服务器字段
    let url: String?
    let headers: [String: String]?

    // Stdio 服务器字段
    let command: String?
    let args: [String]?
    let env: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case serverType = "type"
        case enabled = "is_enabled"
        case description
        case flattenMode = "flatten_mode"
        case url
        case headers
        case command
        case args
        case env
    }

    init(name: String, serverType: MCPServerType, enabled: Bool = true, description: String? = nil,
         flattenMode: Bool = false, url: String? = nil, headers: [String: String]? = nil,
         command: String? = nil, args: [String]? = nil, env: [String: String]? = nil) {
        self.name = name
        self.serverType = serverType
        self.enabled = enabled
        self.description = description
        self.flattenMode = flattenMode
        self.url = url
        self.headers = headers
        self.command = command
        self.args = args
        self.env = env
    }

    /// 创建 HTTP 服务器配置
    static func http(name: String, url: String, headers: [String: String]? = nil, description: String? = nil) -> MCPServerConfig {
        MCPServerConfig(name: name, serverType: .http, description: description, url: url, headers: headers)
    }

    /// 创建 Stdio 服务器配置
    static func stdio(name: String, command: String, args: [String] = [], env: [String: String] = [:], description: String? = nil) -> MCPServerConfig {
        MCPServerConfig(name: name, serverType: .stdio, description: description, command: command, args: args, env: env)
    }
}

/// Router 状态
struct MCPRouterStatus: Codable {
    let isRunning: Bool
    let serverCount: Int
    let enabledServerCount: Int

    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case serverCount = "server_count"
        case enabledServerCount = "enabled_server_count"
    }
}

// MARK: - Error Types

/// MCP Router 错误类型
enum MCPRouterError: Error, LocalizedError {
    case invalidHandle
    case operationFailed(String)
    case jsonParsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHandle:
            return "Invalid router handle"
        case .operationFailed(let message):
            return message
        case .jsonParsingFailed(let message):
            return "JSON parsing failed: \(message)"
        }
    }
}

/// MCP Router Rust Core 桥接
final class MCPRouterBridge {
    
    private var handle: OpaquePointer?
    
    /// 初始化
    init() {
        handle = mcp_router_create()
    }
    
    deinit {
        if let handle = handle {
            mcp_router_destroy(handle)
        }
    }
    
    /// 初始化日志（应用启动时调用一次）
    static func initLogging() {
        mcp_router_init_logging()
    }
    
    /// 获取库版本
    static var version: String {
        guard let cStr = mcp_router_version() else {
            return "unknown"
        }
        let version = String(cString: cStr)
        mcp_router_free_string(cStr)
        return version
    }
    
    // MARK: - Server Management
    
    /// 添加 HTTP 服务器
    func addHTTPServer(name: String, url: String, description: String = "") throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = name.withCString { namePtr in
            url.withCString { urlPtr in
                description.withCString { descPtr in
                    mcp_router_add_http_server(handle, namePtr, urlPtr, descPtr)
                }
            }
        }
        
        try checkResult(result)
    }
    
    /// 从 JSON 添加服务器
    func addServerFromJSON(_ json: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = json.withCString { jsonPtr in
            mcp_router_add_server_json(handle, jsonPtr)
        }
        
        try checkResult(result)
    }
    
    /// 从 JSON 数组加载服务器
    func loadServersFromJSON(_ json: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = json.withCString { jsonPtr in
            mcp_router_load_servers_json(handle, jsonPtr)
        }
        
        try checkResult(result)
    }
    
    /// 从 JSON 数组加载 Workspaces
    func loadWorkspacesFromJSON(_ json: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = json.withCString { jsonPtr in
            mcp_router_load_workspaces_json(handle, jsonPtr)
        }

        try checkResult(result)
    }

    /// 添加服务器配置
    func addServer(_ config: MCPServerConfig) throws {
        let jsonData = try JSONEncoder().encode(config)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MCPRouterError.jsonParsingFailed("Failed to encode config")
        }
        try addServerFromJSON(jsonString)
    }

    /// 批量加载服务器配置
    func loadServers(_ configs: [MCPServerConfig]) throws {
        let jsonData = try JSONEncoder().encode(configs)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MCPRouterError.jsonParsingFailed("Failed to encode configs")
        }
        try loadServersFromJSON(jsonString)
    }

    // MARK: - Server Query & Management

    /// 列出所有服务器配置
    func listServers() throws -> [MCPServerConfig] {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        guard let cStr = mcp_router_list_servers(handle) else {
            return []
        }
        defer { mcp_router_free_string(cStr) }

        let jsonString = String(cString: cStr)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw MCPRouterError.jsonParsingFailed("Invalid UTF-8 string")
        }

        do {
            return try JSONDecoder().decode([MCPServerConfig].self, from: jsonData)
        } catch {
            throw MCPRouterError.jsonParsingFailed(error.localizedDescription)
        }
    }

    /// 移除服务器
    func removeServer(name: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = name.withCString { namePtr in
            mcp_router_remove_server(handle, namePtr)
        }

        try checkResult(result)
    }

    /// 设置服务器启用/禁用状态
    func setServerEnabled(name: String, enabled: Bool) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = name.withCString { namePtr in
            mcp_router_set_server_enabled(handle, namePtr, enabled)
        }

        try checkResult(result)
    }

    /// 设置服务器平铺模式
    func setServerFlattenMode(name: String, flatten: Bool) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = name.withCString { namePtr in
            mcp_router_set_server_flatten_mode(handle, namePtr, flatten)
        }

        try checkResult(result)
    }

    // MARK: - Light/Full Mode

    /// 设置是否暴露管理工具（Light/Full 模式）
    /// - false = Light 模式（只暴露基本工具：list, describe, call）
    /// - true = Full 模式（包括 add_server, remove_server, update_server）
    func setExposeManagementTools(_ expose: Bool) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = mcp_router_set_expose_management_tools(handle, expose)
        try checkResult(result)
    }

    /// 获取当前是否暴露管理工具
    func getExposeManagementTools() -> Bool {
        guard let handle = handle else {
            return false
        }
        return mcp_router_get_expose_management_tools(handle)
    }

    /// 获取 Router 状态
    func getStatus() throws -> MCPRouterStatus {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        guard let cStr = mcp_router_get_status(handle) else {
            throw MCPRouterError.operationFailed("Failed to get status")
        }
        defer { mcp_router_free_string(cStr) }

        let jsonString = String(cString: cStr)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw MCPRouterError.jsonParsingFailed("Invalid UTF-8 string")
        }

        do {
            return try JSONDecoder().decode(MCPRouterStatus.self, from: jsonData)
        } catch {
            throw MCPRouterError.jsonParsingFailed(error.localizedDescription)
        }
    }

    // MARK: - HTTP Server Control

    /// 启动 HTTP 服务器
    func startServer(port: UInt16) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = mcp_router_start_server(handle, port)
        try checkResult(result)
    }

    /// 停止 HTTP 服务器
    func stopServer() throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }

        let result = mcp_router_stop_server(handle)
        try checkResult(result)
    }

    // MARK: - Private
    
    private func checkResult(_ result: FfiResult) throws {
        defer {
            mcp_router_free_result(result)
        }
        
        if !result.success {
            let message: String
            if let errorPtr = result.error_message {
                message = String(cString: errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }
}
