//
//  ToolRegistry.swift
//  ETerm
//
//  MCP Tool 注册表 - 管理插件提供的 Tools
//
//  ⚠️ 当前状态：预留接口，未集成到 MCPServerCoordinator
//
//  设计目的：
//  - 允许 SDK 插件动态注册自己的 MCP Tools
//  - 插件启动时调用 register()，卸载时调用 unregister()
//  - MCPServerCoordinator 从这里获取所有可用 tools
//
//  TODO: 集成步骤
//  1. MCPServerCoordinator.handleMethod() 的 "tools/list" 分支
//     改为从 ToolRegistry.shared.allTools() 获取
//  2. MCPServerCoordinator.callTool() 改为查询 ToolRegistry
//     并调用对应 provider 的 execute 方法
//  3. 插件需实现 MCPToolProvider 协议
//

import Foundation

/// MCP Tool 注册表
///
/// 管理来自插件的 MCP Tools，支持动态注册和注销。
///
/// 当前状态：预留接口，未集成到 MCPServerCoordinator
final class ToolRegistry {
    /// 单例
    static let shared = ToolRegistry()

    /// 已注册的提供者
    private var providers: [String: MCPToolProvider] = [:]

    /// Tool 变更通知名称
    static let toolsDidChangeNotification = Notification.Name("MCPToolsDidChange")

    private init() {}

    // MARK: - Registration

    /// 注册 Tool 提供者
    ///
    /// - Parameter provider: 实现 MCPToolProvider 协议的插件
    /// - Throws: 如果 providerId 已存在
    func register(_ provider: MCPToolProvider) throws {
        guard providers[provider.providerId] == nil else {
            throw RegistryError.providerAlreadyExists(provider.providerId)
        }

        providers[provider.providerId] = provider

        // 发送通知
        NotificationCenter.default.post(
            name: Self.toolsDidChangeNotification,
            object: self
        )
    }

    /// 注销 Tool 提供者
    ///
    /// - Parameter providerId: 提供者 ID
    func unregister(providerId: String) {
        providers.removeValue(forKey: providerId)

        // 发送通知
        NotificationCenter.default.post(
            name: Self.toolsDidChangeNotification,
            object: self
        )
    }

    // MARK: - Query

    /// 获取所有 Tool 定义（带命名空间前缀）
    func allTools() -> [(qualifiedName: String, definition: MCPToolDefinition)] {
        providers.flatMap { providerId, provider in
            provider.tools.map { tool in
                (qualifiedName: "\(providerId).\(tool.name)", definition: tool)
            }
        }
    }

    /// 查找指定 Tool
    ///
    /// - Parameter qualifiedName: 完整名称（如 "translation.translate"）
    func findTool(_ qualifiedName: String) -> MCPToolDefinition? {
        let parts = qualifiedName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let provider = providers[String(parts[0])] else {
            return nil
        }

        let toolName = String(parts[1])
        return provider.tools.first { $0.name == toolName }
    }

    /// 获取所有已注册的提供者 ID
    var registeredProviderIds: [String] {
        Array(providers.keys)
    }
}

// MARK: - Errors

extension ToolRegistry {
    enum RegistryError: Error, LocalizedError {
        case providerAlreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .providerAlreadyExists(let id):
                return "Tool provider '\(id)' already registered"
            }
        }
    }
}
