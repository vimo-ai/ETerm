//
//  MCPWorkspace.swift
//  ETerm
//
//  MCP Router Workspace 模型 - 依赖 WorkspacePlugin 的项目列表
//

import Foundation
import Combine
import SwiftData
import CoreData

/// MCP Workspace 配置 - 为 WorkspacePlugin 的项目添加 MCP 相关配置
struct MCPWorkspace: Codable, Identifiable, Hashable {
    var id: String { token }

    let token: String           // 唯一标识，用于 HTTP Header 路由
    var name: String            // Workspace 名称
    var projectPath: String     // 项目路径（来自 WorkspacePlugin）
    var isDefault: Bool         // 是否为默认 Workspace
    var createdAt: Date

    // Server 启用状态覆盖: serverName -> isEnabled
    // 只记录用户修改过的配置，未记录的跟随 Default Workspace
    var serverOverrides: [String: Bool]

    // Server 平铺模式覆盖: serverName -> flattenMode
    var flattenOverrides: [String: Bool]

    init(
        token: String = MCPWorkspace.generateToken(),
        name: String,
        projectPath: String,
        isDefault: Bool = false,
        serverOverrides: [String: Bool] = [:],
        flattenOverrides: [String: Bool] = [:],
        createdAt: Date = Date()
    ) {
        self.token = token
        self.name = name
        self.projectPath = projectPath
        self.isDefault = isDefault
        self.serverOverrides = serverOverrides
        self.flattenOverrides = flattenOverrides
        self.createdAt = createdAt
    }

    /// 生成唯一 Token (UUID 前 8 位)
    static func generateToken() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
    }

    /// 获取 Server 的有效启用状态
    func isServerEnabled(_ serverName: String, serverConfig: MCPServerConfig?, defaultWorkspace: MCPWorkspace?) -> Bool {
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
    func isFlattenEnabled(_ serverName: String, serverConfig: MCPServerConfig?, defaultWorkspace: MCPWorkspace?) -> Bool {
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

// MARK: - Workspace Manager

/// MCP Workspace 管理器 - 监听 WorkspacePlugin 并管理 MCP 配置
@MainActor
final class MCPWorkspaceManager: ObservableObject {
    static let shared = MCPWorkspaceManager()

    @Published private(set) var workspaces: [MCPWorkspace] = []
    @Published private(set) var defaultWorkspace: MCPWorkspace?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadWorkspaces()
        ensureDefaultWorkspace()
        observeWorkspacePlugin()
    }

    // MARK: - WorkspacePlugin Integration

    private func observeWorkspacePlugin() {
        // 监听 SwiftData 模型变化
        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .sink { [weak self] _ in
                self?.syncWithWorkspacePlugin()
            }
            .store(in: &cancellables)

        // 初始同步
        syncWithWorkspacePlugin()
    }

    /// 从 WorkspacePlugin 的 SwiftData 同步项目列表
    @MainActor
    func syncWithWorkspacePlugin() {
        // TODO: Implement when WorkspacePlugin integration is available
        // This requires WorkspaceDataStore which is in ETerm main app
    }

    // MARK: - CRUD

    func addWorkspace(for projectPath: URL) {
        let path = projectPath.path
        guard !workspaces.contains(where: { $0.projectPath == path }) else { return }

        let name = projectPath.lastPathComponent
        let workspace = MCPWorkspace(name: name, projectPath: path)
        workspaces.append(workspace)

        // 写入 .mcp.json
        if let port = MCPRouterPlugin.shared?.currentPort {
            try? MCPProjectConfigManager.mergeRouterConfig(at: projectPath, token: workspace.token, port: Int(port))
        }

        saveWorkspaces()
    }

    func updateWorkspace(_ workspace: MCPWorkspace) {
        if let index = workspaces.firstIndex(where: { $0.token == workspace.token }) {
            workspaces[index] = workspace
            if workspace.isDefault {
                defaultWorkspace = workspace
            }
            saveWorkspaces()
        }
    }

    func removeWorkspace(token: String) {
        guard let workspace = workspaces.first(where: { $0.token == token }),
              !workspace.isDefault else { return }

        // 移除 .mcp.json 中的配置
        if let url = URL(string: "file://\(workspace.projectPath)") {
            try? MCPProjectConfigManager.removeRouterConfig(at: url)
        }

        workspaces.removeAll { $0.token == token }
        saveWorkspaces()
    }

    func getWorkspace(byToken token: String) -> MCPWorkspace? {
        workspaces.first { $0.token == token }
    }

    func getWorkspace(byPath path: String) -> MCPWorkspace? {
        workspaces.first { $0.projectPath == path }
    }

    // MARK: - Server Overrides

    func setServerEnabled(for token: String, serverName: String, enabled: Bool) {
        guard var workspace = getWorkspace(byToken: token) else { return }
        workspace.serverOverrides[serverName] = enabled
        updateWorkspace(workspace)
    }

    func setFlattenMode(for token: String, serverName: String, flatten: Bool) {
        guard var workspace = getWorkspace(byToken: token) else { return }
        workspace.flattenOverrides[serverName] = flatten
        updateWorkspace(workspace)
    }

    func resetOverrides(for token: String) {
        guard var workspace = getWorkspace(byToken: token) else { return }
        workspace.serverOverrides.removeAll()
        workspace.flattenOverrides.removeAll()
        updateWorkspace(workspace)
    }

    // MARK: - Persistence

    private func loadWorkspaces() {
        let configPath = "\(NSHomeDirectory())/.eterm/plugins/McpRouter/workspaces.json"
        guard FileManager.default.fileExists(atPath: configPath) else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            workspaces = try JSONDecoder().decode([MCPWorkspace].self, from: data)
            defaultWorkspace = workspaces.first { $0.isDefault }
        } catch {
            logWarn("[MCPWorkspace] Failed to load workspaces: \(error)")
        }
    }

    private func saveWorkspaces() {
        do {
            let pluginDir = "\(NSHomeDirectory())/.eterm/plugins/McpRouter"
            try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(workspaces)
            let workspacePath = "\(pluginDir)/workspaces.json"
            try data.write(to: URL(fileURLWithPath: workspacePath))
        } catch {
            // Silently ignore save failure
        }
    }

    private func ensureDefaultWorkspace() {
        if defaultWorkspace == nil {
            let defaultWs = MCPWorkspace(
                token: "default",
                name: "Default",
                projectPath: "",  // 默认 workspace 没有项目路径
                isDefault: true
            )
            workspaces.insert(defaultWs, at: 0)
            defaultWorkspace = defaultWs
            saveWorkspaces()
        }
    }
}
