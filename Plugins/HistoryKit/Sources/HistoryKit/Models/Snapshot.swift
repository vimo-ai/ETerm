//
//  Snapshot.swift
//  HistoryKit
//
//  快照数据模型

import Foundation

// MARK: - Snapshot

/// 快照基本信息
public struct Snapshot: Codable, Identifiable, Sendable {
    /// 快照 ID（时间戳字符串，如 "1703145600000"）
    public let id: String
    /// 创建时间
    public let timestamp: Date
    /// 标签（如 "scheduled", "claude-session-start" 等）
    public let label: String?
    /// 来源（如 "history-kit", "claude-guard" 等）
    public let source: String?
    /// 文件总数
    public let fileCount: Int
    /// 变化文件数
    public let changedCount: Int
    /// 存储大小（压缩后）
    public let storedSize: Int64

    public init(
        id: String,
        timestamp: Date,
        label: String?,
        source: String?,
        fileCount: Int,
        changedCount: Int,
        storedSize: Int64
    ) {
        self.id = id
        self.timestamp = timestamp
        self.label = label
        self.source = source
        self.fileCount = fileCount
        self.changedCount = changedCount
        self.storedSize = storedSize
    }

    /// 从 SnapshotManifest 创建
    public init(from manifest: SnapshotManifest) {
        self.id = manifest.id
        self.timestamp = manifest.timestamp
        self.label = manifest.label
        self.source = manifest.source
        self.fileCount = manifest.stats.totalFiles
        self.changedCount = manifest.stats.changedFiles
        self.storedSize = manifest.stats.storedSize
    }

    /// 转换为字典（用于 Service API 返回）
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "timestamp": timestamp.timeIntervalSince1970,
            "fileCount": fileCount,
            "changedCount": changedCount,
            "storedSize": storedSize
        ]
        if let label = label {
            dict["label"] = label
        }
        if let source = source {
            dict["source"] = source
        }
        return dict
    }
}

// MARK: - SnapshotManifest

/// 快照清单（包含完整文件列表）
public struct SnapshotManifest: Codable, Sendable {
    public let id: String
    public let timestamp: Date
    public let label: String?
    public let source: String?
    public let files: [FileEntry]
    public let stats: SnapshotStats

    public init(
        id: String,
        timestamp: Date,
        label: String?,
        source: String?,
        files: [FileEntry],
        stats: SnapshotStats
    ) {
        self.id = id
        self.timestamp = timestamp
        self.label = label
        self.source = source
        self.files = files
        self.stats = stats
    }
}

// MARK: - SnapshotStats

/// 快照统计信息
public struct SnapshotStats: Codable, Sendable {
    public let totalFiles: Int
    public let changedFiles: Int
    public let storedSize: Int64

    public init(totalFiles: Int, changedFiles: Int, storedSize: Int64) {
        self.totalFiles = totalFiles
        self.changedFiles = changedFiles
        self.storedSize = storedSize
    }
}
