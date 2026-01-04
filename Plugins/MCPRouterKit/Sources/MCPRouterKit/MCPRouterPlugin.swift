//
//  MCPRouterPlugin.swift
//  MCPRouterKit
//
//  MCP Router 插件 - 管理 MCP 服务器 (SDK main 模式)

import Foundation
import SwiftUI
import ETermKit

// MARK: - Notification Names

extension Notification.Name {
    /// 工作区列表更新（内部通知）
    static let mcpRouterWorkspacesUpdated = Notification.Name("MCPRouterWorkspacesUpdated")
    /// 请求当前工作区数据
    static let mcpRouterRequestWorkspaces = Notification.Name("MCPRouterRequestWorkspaces")
}

// MARK: - Workspace Cache

/// 缓存最后收到的工作区数据（解决时序问题）
@MainActor
final class WorkspaceCache {
    static let shared = WorkspaceCache()
    private(set) var workspaces: [[String: Any]] = []

    private init() {}

    func update(_ workspaces: [[String: Any]]) {
        self.workspaces = workspaces
    }
}

// MARK: - Plugin Entry

@objc(MCPRouterPlugin)
@MainActor
public final class MCPRouterPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.mcp-router"

    private var host: HostBridge?

    public override init() {
        super.init()
        // 初始化日志
        MCPRouterBridge.initLogging()
    }

    public func activate(host: HostBridge) {
        self.host = host

        // 主动加载工作区数据（解决事件时序问题）
        loadWorkspacesFromService(host: host)

        // 自动启动 MCP Router 服务
        do {
            try MCPRouterBridge.shared.startServer(port: 19104)
        } catch {
            logError("[MCPRouterKit] Failed to start server: \(error)")
        }
    }

    /// 从 WorkspaceKit 服务加载工作区
    private func loadWorkspacesFromService(host: HostBridge) {
        // 调用 WorkspaceKit 的 getWorkspaces 服务
        guard let result = host.callService(
            pluginId: "com.eterm.workspace",
            name: "getWorkspaces",
            params: [:]
        ) else {
            logError("[MCPRouterKit] Failed to call getWorkspaces service")
            return
        }

        guard let workspaces = result["workspaces"] as? [[String: Any]] else {
            if let error = result["error"] as? String {
                logError("[MCPRouterKit] getWorkspaces error: \(error)")
            }
            return
        }

        if !workspaces.isEmpty {
            WorkspaceCache.shared.update(workspaces)
            // 转发给 ViewModel
            NotificationCenter.default.post(
                name: .mcpRouterWorkspacesUpdated,
                object: nil,
                userInfo: ["workspaces": workspaces]
            )
            logInfo("[MCPRouterKit] Loaded \(workspaces.count) workspaces from service")
        }
    }

    public func deactivate() {
        // 停止服务
        do {
            try MCPRouterBridge.shared.stopServer()
        } catch {
            logError("[MCPRouterKit] Failed to stop server: \(error)")
        }
    }

    public func sidebarView(for tabId: String) -> AnyView? {
        if tabId == "mcp-router-settings" {
            return AnyView(MCPRouterSettingsView())
        }
        return nil
    }

    /// 处理来自其他插件的事件
    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        if eventName == "plugin.com.eterm.workspace.didUpdate" {
            // 收到工作区更新事件，缓存并转发给 ViewModel
            if let workspaces = payload["workspaces"] as? [[String: Any]] {
                WorkspaceCache.shared.update(workspaces)
                NotificationCenter.default.post(
                    name: .mcpRouterWorkspacesUpdated,
                    object: nil,
                    userInfo: ["workspaces": workspaces]
                )
            }
        }
    }
}
