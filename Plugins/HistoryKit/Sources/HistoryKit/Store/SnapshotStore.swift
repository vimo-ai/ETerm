//
//  SnapshotStore.swift
//  HistoryKit
//
//  快照存储层协议

import Foundation

// MARK: - HistoryError

/// 历史快照错误
public enum HistoryError: Error, LocalizedError {
    case snapshotNotFound
    case manifestNotFound
    case fileNotFound(String)
    case compressionFailed
    case decompressionFailed
    case writeError(String)
    case readError(String)

    public var errorDescription: String? {
        switch self {
        case .snapshotNotFound:
            return "快照不存在"
        case .manifestNotFound:
            return "快照清单不存在"
        case .fileNotFound(let path):
            return "文件不存在: \(path)"
        case .compressionFailed:
            return "压缩失败"
        case .decompressionFailed:
            return "解压失败"
        case .writeError(let msg):
            return "写入错误: \(msg)"
        case .readError(let msg):
            return "读取错误: \(msg)"
        }
    }
}

// MARK: - SnapshotStore Protocol

/// 存储层协议
public protocol SnapshotStore: Sendable {

    /// 创建快照
    /// - Parameters:
    ///   - projectPath: 项目路径
    ///   - label: 快照标签（如 "scheduled", "claude-session-start"）
    ///   - source: 快照来源（如 "history-kit", "claude-guard"）
    /// - Returns: 创建的快照
    func createSnapshot(
        projectPath: String,
        label: String?,
        source: String?
    ) async throws -> Snapshot

    /// 列出快照
    /// - Parameters:
    ///   - projectPath: 项目路径
    ///   - limit: 返回数量限制
    /// - Returns: 快照列表（按时间倒序）
    func listSnapshots(
        projectPath: String,
        limit: Int
    ) async -> [Snapshot]

    /// 获取快照详情（包含文件列表）
    /// - Parameters:
    ///   - projectPath: 项目路径
    ///   - snapshotId: 快照 ID
    /// - Returns: 快照清单
    func getSnapshot(
        projectPath: String,
        snapshotId: String
    ) async -> SnapshotManifest?

    /// 恢复快照
    /// - Parameters:
    ///   - projectPath: 项目路径
    ///   - snapshotId: 快照 ID
    func restoreSnapshot(
        projectPath: String,
        snapshotId: String
    ) async throws

    /// 删除快照
    /// - Parameters:
    ///   - projectPath: 项目路径
    ///   - snapshotId: 快照 ID
    func deleteSnapshot(
        projectPath: String,
        snapshotId: String
    ) async throws

    /// 清理旧快照
    /// - Parameters:
    ///   - projectPath: 项目路径
    ///   - keepCount: 保留数量
    func cleanup(
        projectPath: String,
        keepCount: Int
    ) async throws
}
