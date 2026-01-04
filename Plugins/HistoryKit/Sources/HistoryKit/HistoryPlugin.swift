//
//  HistoryPlugin.swift
//  HistoryKit
//
//  历史快照插件入口

import Foundation
import SwiftUI
import ETermKit

// MARK: - HistoryPlugin

@objc(HistoryPlugin)
@MainActor
public final class HistoryPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.history"

    private var host: HostBridge?
    private var service: HistoryService?
    private var scheduledTimer: Timer?

    /// 共享状态
    private var state: HistoryState { HistoryState.shared }

    /// 定时快照间隔（5 分钟）
    private let scheduledInterval: TimeInterval = 5 * 60

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host
        self.service = HistoryService(host: host)

        // 设置共享状态的 host 引用
        state.host = host

        // 注册服务
        registerServices()

        // 启动定时快照
        startScheduledSnapshots()

        // 主动加载工作区数据（解决事件时序问题）
        loadWorkspacesFromService()
    }

    /// 从 WorkspaceKit 服务加载工作区
    private func loadWorkspacesFromService() {
        guard let host = host else { return }

        // 调用 WorkspaceKit 的 getWorkspaces 服务
        guard let result = host.callService(
            pluginId: "com.eterm.workspace",
            name: "getWorkspaces",
            params: [:]
        ) else {
            return
        }

        guard let workspaces = result["workspaces"] as? [[String: Any]] else {
            return
        }

        if !workspaces.isEmpty {
            let paths = workspaces.compactMap { $0["path"] as? String }
            state.updateWorkspaces(paths)
        }
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "plugin.com.eterm.workspace.didUpdate":
            handleWorkspaceUpdate(payload)
        default:
            break
        }
    }

    public func deactivate() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
    }

    public func sidebarView(for tabId: String) -> AnyView? {
        if tabId == "history-panel", let service = service {
            return AnyView(HistoryPanelView(service: service, state: state))
        }
        return nil
    }

    // MARK: - Service Registration

    private func registerServices() {
        guard let host = host else { return }

        // snapshot 服务
        // 注意：registerService 是同步的，这里只做请求验证
        // 实际的 async 操作通过 Task 在后台执行，立即返回确认
        host.registerService(name: "snapshot") { [weak self] params in
            guard self != nil else { return ["error": "plugin not available"] }

            let cwd = params["cwd"] as? String ?? ""
            let label = params["label"] as? String

            guard !cwd.isEmpty else {
                return ["error": "cwd is required"]
            }

            // 启动异步任务处理快照
            Task { @MainActor [weak self] in
                guard let self = self, let service = self.service else { return }
                do {
                    _ = try await service.snapshot(cwd: cwd, label: label)
                } catch {
                    logError("[HistoryKit] 快照创建失败: \(error)")
                }
            }

            // 立即返回已接受
            return ["accepted": true, "cwd": cwd, "label": label as Any]
        }

        // list 服务 - 同步返回缓存或空列表，实际数据通过事件推送
        host.registerService(name: "list") { [weak self] params in
            guard self != nil else { return ["error": "plugin not available"] }

            let cwd = params["cwd"] as? String ?? ""
            let limit = params["limit"] as? Int ?? 20

            guard !cwd.isEmpty else {
                return ["error": "cwd is required"]
            }

            // 启动异步任务获取列表
            Task { @MainActor [weak self] in
                guard let self = self, let service = self.service else { return }
                let result = await service.list(cwd: cwd, limit: limit)
                // 可以通过事件发送结果
                self.host?.emit(
                    eventName: "plugin.com.eterm.history.listResult",
                    payload: result
                )
            }

            // 立即返回已接受
            return ["accepted": true, "cwd": cwd, "limit": limit]
        }

        // restore 服务
        host.registerService(name: "restore") { [weak self] params in
            guard self != nil else { return ["error": "plugin not available"] }

            guard let cwd = params["cwd"] as? String,
                  let snapshotId = params["snapshotId"] as? String else {
                return ["error": "missing parameters (cwd, snapshotId)"]
            }

            // 启动异步任务恢复快照
            Task { @MainActor [weak self] in
                guard let self = self, let service = self.service else { return }
                do {
                    try await service.restore(cwd: cwd, snapshotId: snapshotId)
                    self.host?.emit(
                        eventName: "plugin.com.eterm.history.restoreComplete",
                        payload: ["success": true, "snapshotId": snapshotId]
                    )
                } catch {
                    self.host?.emit(
                        eventName: "plugin.com.eterm.history.restoreComplete",
                        payload: ["success": false, "error": error.localizedDescription]
                    )
                }
            }

            // 立即返回已接受
            return ["accepted": true, "snapshotId": snapshotId]
        }
    }

    // MARK: - Scheduled Snapshots

    private func startScheduledSnapshots() {
        scheduledTimer = Timer.scheduledTimer(
            withTimeInterval: scheduledInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runScheduledSnapshots()
            }
        }
    }

    private func runScheduledSnapshots() async {
        guard let service = service, let host = host else { return }

        // 获取所有终端的 cwd
        let terminals = host.getAllTerminals()
        let activeCwds = Set(terminals.map { $0.cwd })

        // 过滤出有活跃终端的工作区
        let activeWorkspaces = state.workspaces.filter { workspace in
            activeCwds.contains { cwd in
                cwd == workspace || cwd.hasPrefix(workspace + "/")
            }
        }

        // 只对活跃工作区创建快照
        for workspace in activeWorkspaces {
            do {
                _ = try await service.snapshot(cwd: workspace, label: "scheduled")
            } catch {
                logError("[HistoryKit] 定时快照失败 (\(workspace)): \(error)")
            }
        }
    }

    // MARK: - Event Handlers

    private func handleWorkspaceUpdate(_ payload: [String: Any]) {
        guard let workspacesData = payload["workspaces"] as? [[String: Any]] else {
            return
        }

        let paths = workspacesData.compactMap { $0["path"] as? String }
        state.updateWorkspaces(paths)
    }
}
