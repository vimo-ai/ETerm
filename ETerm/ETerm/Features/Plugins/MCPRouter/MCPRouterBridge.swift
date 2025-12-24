//
//  MCPRouterBridge.swift
//  ETerm
//
//  MCP Router Rust Core 的 Swift 桥接层
//  使用 dlopen 动态加载 dylib，避免与其他 Rust staticlib 的符号冲突
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
    case libraryNotLoaded
    case symbolNotFound(String)
    case operationFailed(String)
    case jsonParsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHandle:
            return "Invalid router handle"
        case .libraryNotLoaded:
            return "MCP Router library not loaded"
        case .symbolNotFound(let symbol):
            return "Symbol not found: \(symbol)"
        case .operationFailed(let message):
            return message
        case .jsonParsingFailed(let message):
            return "JSON parsing failed: \(message)"
        }
    }
}

// MARK: - Dynamic Library Loader

/// MCP Router 动态库加载器
final class MCPRouterLibrary {
    static let shared = MCPRouterLibrary()

    private var libraryHandle: UnsafeMutableRawPointer?
    private(set) var isLoaded = false

    // 函数指针类型定义（所有类型都是 C 兼容的）
    private typealias CreateFunc = @convention(c) () -> OpaquePointer?
    private typealias DestroyFunc = @convention(c) (OpaquePointer?) -> Void
    private typealias FreeStringFunc = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias InitLoggingFunc = @convention(c) () -> Void
    private typealias VersionFunc = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias ListServersFunc = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias GetExposeManagementToolsFunc = @convention(c) (OpaquePointer?) -> Bool
    private typealias GetStatusFunc = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?

    // 带 out_error 参数的函数类型
    private typealias AddHttpServerFunc = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool
    private typealias JsonOpFunc = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool
    private typealias NameOpFunc = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool
    private typealias NameBoolOpFunc = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Bool, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool
    private typealias BoolOpFunc = @convention(c) (OpaquePointer?, Bool, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool
    private typealias StartServerFunc = @convention(c) (OpaquePointer?, UInt16, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool
    private typealias StopServerFunc = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool

    // 函数指针存储
    private var _create: CreateFunc?
    private var _destroy: DestroyFunc?
    private var _freeString: FreeStringFunc?
    private var _initLogging: InitLoggingFunc?
    private var _version: VersionFunc?
    private var _listServers: ListServersFunc?
    private var _getExposeManagementTools: GetExposeManagementToolsFunc?
    private var _getStatus: GetStatusFunc?

    private var _addHttpServer: AddHttpServerFunc?
    private var _addServerJson: JsonOpFunc?
    private var _loadServersJson: JsonOpFunc?
    private var _loadWorkspacesJson: JsonOpFunc?
    private var _removeServer: NameOpFunc?
    private var _setServerEnabled: NameBoolOpFunc?
    private var _setServerFlattenMode: NameBoolOpFunc?
    private var _setExposeManagementTools: BoolOpFunc?
    private var _startServer: StartServerFunc?
    private var _stopServer: StopServerFunc?

    private init() {}

    /// 加载动态库
    func load() throws {
        guard !isLoaded else { return }

        // 从 App bundle 的 Frameworks 目录加载
        guard let path = Bundle.main.path(forResource: "libmcp_router_core", ofType: "dylib") else {
            throw MCPRouterError.libraryNotLoaded
        }

        libraryHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL)

        guard let handle = libraryHandle else {
            let error = String(cString: dlerror())
            print("[MCPRouter] Failed to load library: \(error)")
            throw MCPRouterError.libraryNotLoaded
        }

        print("[MCPRouter] Library loaded from: \(path)")
        try loadSymbols(from: handle)
        isLoaded = true
    }

    private func loadSymbols(from handle: UnsafeMutableRawPointer) throws {
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            guard let s = dlsym(handle, name) else {
                throw MCPRouterError.symbolNotFound(name)
            }
            return unsafeBitCast(s, to: type)
        }

        _create = try sym("mcp_router_create", as: CreateFunc.self)
        _destroy = try sym("mcp_router_destroy", as: DestroyFunc.self)
        _freeString = try sym("mcp_router_free_string", as: FreeStringFunc.self)
        _initLogging = try sym("mcp_router_init_logging", as: InitLoggingFunc.self)
        _version = try sym("mcp_router_version", as: VersionFunc.self)
        _listServers = try sym("mcp_router_list_servers", as: ListServersFunc.self)
        _getExposeManagementTools = try sym("mcp_router_get_expose_management_tools", as: GetExposeManagementToolsFunc.self)
        _getStatus = try sym("mcp_router_get_status", as: GetStatusFunc.self)

        _addHttpServer = try sym("mcp_router_add_http_server", as: AddHttpServerFunc.self)
        _addServerJson = try sym("mcp_router_add_server_json", as: JsonOpFunc.self)
        _loadServersJson = try sym("mcp_router_load_servers_json", as: JsonOpFunc.self)
        _loadWorkspacesJson = try sym("mcp_router_load_workspaces_json", as: JsonOpFunc.self)
        _removeServer = try sym("mcp_router_remove_server", as: NameOpFunc.self)
        _setServerEnabled = try sym("mcp_router_set_server_enabled", as: NameBoolOpFunc.self)
        _setServerFlattenMode = try sym("mcp_router_set_server_flatten_mode", as: NameBoolOpFunc.self)
        _setExposeManagementTools = try sym("mcp_router_set_expose_management_tools", as: BoolOpFunc.self)
        _startServer = try sym("mcp_router_start_server", as: StartServerFunc.self)
        _stopServer = try sym("mcp_router_stop_server", as: StopServerFunc.self)
    }

    deinit {
        if let handle = libraryHandle {
            dlclose(handle)
        }
    }

    // MARK: - Public API

    func create() -> OpaquePointer? { _create?() }
    func destroy(_ handle: OpaquePointer?) { _destroy?(handle) }
    func freeString(_ str: UnsafeMutablePointer<CChar>?) { _freeString?(str) }
    func initLogging() { _initLogging?() }
    func version() -> UnsafeMutablePointer<CChar>? { _version?() }
    func listServers(_ handle: OpaquePointer?) -> UnsafeMutablePointer<CChar>? { _listServers?(handle) }
    func getExposeManagementTools(_ handle: OpaquePointer?) -> Bool { _getExposeManagementTools?(handle) ?? false }
    func getStatus(_ handle: OpaquePointer?) -> UnsafeMutablePointer<CChar>? { _getStatus?(handle) }

    func addHttpServer(_ handle: OpaquePointer?, name: UnsafePointer<CChar>, url: UnsafePointer<CChar>, desc: UnsafePointer<CChar>) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _addHttpServer?(handle, name, url, desc, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func addServerJson(_ handle: OpaquePointer?, json: UnsafePointer<CChar>) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _addServerJson?(handle, json, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func loadServersJson(_ handle: OpaquePointer?, json: UnsafePointer<CChar>) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _loadServersJson?(handle, json, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func loadWorkspacesJson(_ handle: OpaquePointer?, json: UnsafePointer<CChar>) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _loadWorkspacesJson?(handle, json, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func removeServer(_ handle: OpaquePointer?, name: UnsafePointer<CChar>) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _removeServer?(handle, name, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func setServerEnabled(_ handle: OpaquePointer?, name: UnsafePointer<CChar>, enabled: Bool) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _setServerEnabled?(handle, name, enabled, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func setServerFlattenMode(_ handle: OpaquePointer?, name: UnsafePointer<CChar>, flatten: Bool) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _setServerFlattenMode?(handle, name, flatten, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func setExposeManagementTools(_ handle: OpaquePointer?, expose: Bool) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _setExposeManagementTools?(handle, expose, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func startServer(_ handle: OpaquePointer?, port: UInt16) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _startServer?(handle, port, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    func stopServer(_ handle: OpaquePointer?) throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = _stopServer?(handle, &errorPtr) ?? false
        try checkResult(success, errorPtr)
    }

    private func checkResult(_ success: Bool, _ errorPtr: UnsafeMutablePointer<CChar>?) throws {
        if !success {
            let message: String
            if let errorPtr = errorPtr {
                message = String(cString: errorPtr)
                freeString(errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }
}

// MARK: - MCP Router Bridge

/// MCP Router Rust Core 桥接
final class MCPRouterBridge {

    private var handle: OpaquePointer?
    private let lib: MCPRouterLibrary

    /// 初始化
    init() throws {
        lib = MCPRouterLibrary.shared
        try lib.load()
        handle = lib.create()
    }

    deinit {
        if let handle = handle {
            lib.destroy(handle)
        }
    }

    /// 初始化日志（应用启动时调用一次）
    static func initLogging() {
        do {
            try MCPRouterLibrary.shared.load()
            MCPRouterLibrary.shared.initLogging()
        } catch {
            print("[MCPRouter] Failed to init logging: \(error)")
        }
    }

    /// 获取库版本
    static var version: String {
        do {
            try MCPRouterLibrary.shared.load()
            guard let cStr = MCPRouterLibrary.shared.version() else {
                return "unknown"
            }
            let version = String(cString: cStr)
            MCPRouterLibrary.shared.freeString(cStr)
            return version
        } catch {
            return "unknown"
        }
    }

    // MARK: - Server Management

    /// 添加 HTTP 服务器
    func addHTTPServer(name: String, url: String, description: String = "") throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try name.withCString { namePtr in
            try url.withCString { urlPtr in
                try description.withCString { descPtr in
                    try lib.addHttpServer(handle, name: namePtr, url: urlPtr, desc: descPtr)
                }
            }
        }
    }

    /// 从 JSON 添加服务器
    func addServerFromJSON(_ json: String) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try json.withCString { jsonPtr in
            try lib.addServerJson(handle, json: jsonPtr)
        }
    }

    /// 从 JSON 数组加载服务器
    func loadServersFromJSON(_ json: String) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try json.withCString { jsonPtr in
            try lib.loadServersJson(handle, json: jsonPtr)
        }
    }

    /// 从 JSON 数组加载 Workspaces
    func loadWorkspacesFromJSON(_ json: String) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try json.withCString { jsonPtr in
            try lib.loadWorkspacesJson(handle, json: jsonPtr)
        }
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
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        guard let cStr = lib.listServers(handle) else { return [] }
        defer { lib.freeString(cStr) }

        let jsonString = String(cString: cStr)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw MCPRouterError.jsonParsingFailed("Invalid UTF-8 string")
        }

        return try JSONDecoder().decode([MCPServerConfig].self, from: jsonData)
    }

    /// 移除服务器
    func removeServer(name: String) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try name.withCString { namePtr in
            try lib.removeServer(handle, name: namePtr)
        }
    }

    /// 设置服务器启用/禁用状态
    func setServerEnabled(name: String, enabled: Bool) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try name.withCString { namePtr in
            try lib.setServerEnabled(handle, name: namePtr, enabled: enabled)
        }
    }

    /// 设置服务器平铺模式
    func setServerFlattenMode(name: String, flatten: Bool) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        try name.withCString { namePtr in
            try lib.setServerFlattenMode(handle, name: namePtr, flatten: flatten)
        }
    }

    // MARK: - Light/Full Mode

    /// 设置是否暴露管理工具（Light/Full 模式）
    func setExposeManagementTools(_ expose: Bool) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }
        try lib.setExposeManagementTools(handle, expose: expose)
    }

    /// 获取当前是否暴露管理工具
    func getExposeManagementTools() -> Bool {
        guard let handle = handle else { return false }
        return lib.getExposeManagementTools(handle)
    }

    /// 获取 Router 状态
    func getStatus() throws -> MCPRouterStatus {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }

        guard let cStr = lib.getStatus(handle) else {
            throw MCPRouterError.operationFailed("Failed to get status")
        }
        defer { lib.freeString(cStr) }

        let jsonString = String(cString: cStr)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw MCPRouterError.jsonParsingFailed("Invalid UTF-8 string")
        }

        return try JSONDecoder().decode(MCPRouterStatus.self, from: jsonData)
    }

    // MARK: - HTTP Server Control

    /// 启动 HTTP 服务器
    func startServer(port: UInt16) throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }
        try lib.startServer(handle, port: port)
    }

    /// 停止 HTTP 服务器
    func stopServer() throws {
        guard let handle = handle else { throw MCPRouterError.invalidHandle }
        try lib.stopServer(handle)
    }
}
