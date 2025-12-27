//
//  FileEntry.swift
//  HistoryKit
//
//  文件条目数据模型

import Foundation

// MARK: - FileEntry

/// 文件条目（存储在快照 manifest 中）
public struct FileEntry: Codable, Sendable {
    /// 相对路径（如 "src/main.swift"）
    public let path: String
    /// 文件大小
    public let size: Int64
    /// 修改时间（Unix 时间戳）
    public let mtime: TimeInterval
    /// 文件权限
    public let mode: UInt16
    /// 是否在本快照中存储（true=本快照存储，false=引用其他快照）
    public let stored: Bool
    /// 引用的快照 ID（stored=false 时有效）
    public let reference: String?

    public init(
        path: String,
        size: Int64,
        mtime: TimeInterval,
        mode: UInt16,
        stored: Bool,
        reference: String?
    ) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.stored = stored
        self.reference = reference
    }
}

// MARK: - ScannedFile

/// 扫描到的文件（目录扫描结果）
public struct ScannedFile: Sendable {
    /// 相对路径
    public let path: String
    /// 绝对路径 URL
    public let absolutePath: URL
    /// 文件大小
    public let size: Int64
    /// 修改时间（Unix 时间戳）
    public let mtime: TimeInterval
    /// 文件权限
    public let mode: UInt16

    public init(
        path: String,
        absolutePath: URL,
        size: Int64,
        mtime: TimeInterval,
        mode: UInt16
    ) {
        self.path = path
        self.absolutePath = absolutePath
        self.size = size
        self.mtime = mtime
        self.mode = mode
    }
}
