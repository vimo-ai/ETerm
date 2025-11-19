//
//  TabNode.swift
//  PanelLayoutKit
//
//  Tab 节点（终端会话）
//

import Foundation

/// Tab 节点
///
/// 表示一个 Tab（终端会话）。
/// 在 Golden Layout 中对应 ComponentItem。
public struct TabNode: Codable, Equatable, Hashable, Identifiable {
    /// Tab 唯一标识符
    public let id: UUID

    /// Tab 标题
    public var title: String

    /// 创建一个新的 Tab 节点
    ///
    /// - Parameters:
    ///   - id: Tab 唯一标识符
    ///   - title: Tab 标题
    public init(id: UUID = UUID(), title: String = "") {
        self.id = id
        self.title = title
    }
}
