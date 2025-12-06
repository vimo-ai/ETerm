//
//  TabNode.swift
//  PanelLayoutKit
//
//  Tab 节点（终端会话）
//

import Foundation

/// Tab 的搜索信息
public struct TabSearchInfo: Codable, Equatable, Hashable {
    public var pattern: String
    public var totalCount: Int
    public var currentIndex: Int

    public init(pattern: String, totalCount: Int, currentIndex: Int) {
        self.pattern = pattern
        self.totalCount = totalCount
        self.currentIndex = currentIndex
    }
}

/// Tab 节点
///
/// 表示一个 Tab（终端会话）。
/// 在 Golden Layout 中对应 ComponentItem。
public struct TabNode: Codable, Equatable, Hashable, Identifiable {
    /// Tab 唯一标识符
    public let id: UUID

    /// Tab 标题
    public var title: String

    /// Rust 终端 ID（绑定到 TerminalPool 中的终端实例）
    /// 用于 Swift 告诉 Rust 渲染哪个终端
    public var rustTerminalId: Int

    /// 搜索信息（Tab 级别）
    public var searchInfo: TabSearchInfo?

    /// 创建一个新的 Tab 节点
    ///
    /// - Parameters:
    ///   - id: Tab 唯一标识符
    ///   - title: Tab 标题
    ///   - rustTerminalId: Rust 终端 ID（默认 -1 表示未绑定）
    ///   - searchInfo: 搜索信息
    public init(
        id: UUID = UUID(),
        title: String = "",
        rustTerminalId: Int = -1,
        searchInfo: TabSearchInfo? = nil
    ) {
        self.id = id
        self.title = title
        self.rustTerminalId = rustTerminalId
        self.searchInfo = searchInfo
    }
}
