//
//  HistoryState.swift
//  HistoryKit
//
//  共享状态管理

import Foundation
import Combine
import ETermKit

// MARK: - HistoryState

/// 历史快照共享状态
@MainActor
public final class HistoryState: ObservableObject {

    /// 单例
    static let shared = HistoryState()

    /// 工作区列表
    @Published var workspaces: [String] = []

    /// 当前选中的工作区
    @Published var currentWorkspace: String = ""

    /// HostBridge 引用
    weak var host: HostBridge?

    private init() {}

    /// 更新工作区列表
    func updateWorkspaces(_ paths: [String]) {
        print("[HistoryState] updateWorkspaces called with \(paths.count) paths: \(paths)")
        workspaces = paths
        print("[HistoryState] workspaces updated, now has \(workspaces.count) items")

        // 如果当前工作区为空或不在列表中，尝试自动选择
        if currentWorkspace.isEmpty || !paths.contains(currentWorkspace) {
            autoSelectWorkspace()
        }
    }

    /// 自动选择工作区（优先使用当前活跃 Tab 的 CWD）
    func autoSelectWorkspace() {
        // 尝试获取当前活跃 Tab 的 CWD
        if let cwd = host?.getActiveTabCwd(), !cwd.isEmpty {
            // 检查 CWD 是否在工作区列表中，或是其子目录
            if let matchedWorkspace = findMatchingWorkspace(for: cwd) {
                currentWorkspace = matchedWorkspace
                return
            }
        }

        // 回退到第一个工作区
        if let first = workspaces.first {
            currentWorkspace = first
        }
    }

    /// 查找匹配的工作区（CWD 可能是工作区的子目录）
    private func findMatchingWorkspace(for cwd: String) -> String? {
        // 精确匹配
        if workspaces.contains(cwd) {
            return cwd
        }

        // 检查是否是某个工作区的子目录
        for workspace in workspaces {
            if cwd.hasPrefix(workspace + "/") {
                return workspace
            }
        }

        return nil
    }

    /// 手动选择工作区
    func selectWorkspace(_ path: String) {
        currentWorkspace = path
    }
}
