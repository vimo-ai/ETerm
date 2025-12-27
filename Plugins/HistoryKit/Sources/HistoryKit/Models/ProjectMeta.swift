//
//  ProjectMeta.swift
//  HistoryKit
//
//  项目元信息

import Foundation
import CryptoKit

// MARK: - ProjectMeta

/// 项目元信息
public struct ProjectMeta: Codable, Sendable {
    /// 项目路径
    public let projectPath: String
    /// 项目 hash（sha256(path).prefix(16)）
    public let projectHash: String
    /// 创建时间
    public let createdAt: Date
    /// 最后快照时间
    public var lastSnapshotAt: Date?
    /// 快照总数
    public var totalSnapshots: Int

    public init(
        projectPath: String,
        projectHash: String,
        createdAt: Date,
        lastSnapshotAt: Date? = nil,
        totalSnapshots: Int = 0
    ) {
        self.projectPath = projectPath
        self.projectHash = projectHash
        self.createdAt = createdAt
        self.lastSnapshotAt = lastSnapshotAt
        self.totalSnapshots = totalSnapshots
    }
}

// MARK: - Project Hash

/// 计算项目 hash
public func projectHash(for path: String) -> String {
    let normalized = (path as NSString).standardizingPath
    let data = normalized.data(using: .utf8) ?? Data()
    let hash = SHA256.hash(data: data)
    // 取前 8 字节（16 个十六进制字符）
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
}
