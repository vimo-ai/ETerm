//
//  HistoryService.swift
//  HistoryKit
//
//  历史快照服务 API

import Foundation
import ETermKit

// MARK: - HistoryService

/// 历史快照服务
@MainActor
public final class HistoryService {

    private weak var host: HostBridge?
    private let store: FileSnapshotStore

    public init(host: HostBridge) {
        self.host = host
        self.store = FileSnapshotStore()
    }

    // MARK: - Public API

    /// 创建快照
    /// - Parameters:
    ///   - cwd: 工作目录路径
    ///   - label: 快照标签
    /// - Returns: 结果字典
    public func snapshot(cwd: String, label: String?) async throws -> [String: Any] {
        // 检查防抖
        let shouldSnapshot = await store.shouldSnapshot(cwd: cwd)
        guard shouldSnapshot else {
            return ["skipped": true, "reason": "debounced"]
        }

        let snapshot = try await store.createSnapshot(
            projectPath: cwd,
            label: label,
            source: "history-kit"
        )

        return [
            "snapshotId": snapshot.id,
            "fileCount": snapshot.fileCount,
            "changedCount": snapshot.changedCount,
            "storedSize": snapshot.storedSize
        ]
    }

    /// 列出快照
    /// - Parameters:
    ///   - cwd: 工作目录路径
    ///   - limit: 返回数量限制
    /// - Returns: 结果字典
    public func list(cwd: String, limit: Int) async -> [String: Any] {
        let snapshots = await store.listSnapshots(projectPath: cwd, limit: limit)

        return [
            "snapshots": snapshots.map { $0.toDictionary() }
        ]
    }

    /// 恢复快照
    /// - Parameters:
    ///   - cwd: 工作目录路径
    ///   - snapshotId: 快照 ID
    public func restore(cwd: String, snapshotId: String) async throws {
        try await store.restoreSnapshot(projectPath: cwd, snapshotId: snapshotId)
    }

    /// 获取快照详情
    /// - Parameters:
    ///   - cwd: 工作目录路径
    ///   - snapshotId: 快照 ID
    /// - Returns: 快照清单
    public func getSnapshot(cwd: String, snapshotId: String) async -> SnapshotManifest? {
        return await store.getSnapshot(projectPath: cwd, snapshotId: snapshotId)
    }

    /// 删除快照
    /// - Parameters:
    ///   - cwd: 工作目录路径
    ///   - snapshotId: 快照 ID
    public func deleteSnapshot(cwd: String, snapshotId: String) async throws {
        try await store.deleteSnapshot(projectPath: cwd, snapshotId: snapshotId)
    }
}
