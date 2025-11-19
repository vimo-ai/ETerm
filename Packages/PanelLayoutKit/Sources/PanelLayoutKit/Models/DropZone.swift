//
//  DropZone.swift
//  PanelLayoutKit
//
//  Drop Zone 定义
//

import Foundation
import CoreGraphics

/// Drop Zone 类型
///
/// 定义拖拽目标区域的类型。
/// 参考 Golden Layout 的 Stack.Segment。
public enum DropZoneType: String, Codable, Equatable, Hashable {
    /// Header 区域（Tab 区）
    /// 拖到此区域会将 Tab 添加到 Panel 中
    case header

    /// Body 区域（空 Panel）
    /// 只有当 Panel 为空时才会有此区域
    case body

    /// 左侧区域
    /// 拖到此区域会在左侧创建新 Panel
    case left

    /// 右侧区域
    /// 拖到此区域会在右侧创建新 Panel
    case right

    /// 顶部区域
    /// 拖到此区域会在顶部创建新 Panel
    case top

    /// 底部区域
    /// 拖到此区域会在底部创建新 Panel
    case bottom
}

/// Drop Zone
///
/// 表示一个拖拽目标区域，包含类型和高亮区域。
public struct DropZone: Equatable {
    /// Drop Zone 类型
    public let type: DropZoneType

    /// 高亮区域（用于 UI 反馈）
    public let highlightArea: CGRect

    /// 对于 Header Drop Zone，记录插入位置索引
    public let insertIndex: Int?

    /// 创建一个新的 Drop Zone
    ///
    /// - Parameters:
    ///   - type: Drop Zone 类型
    ///   - highlightArea: 高亮区域
    ///   - insertIndex: 插入位置索引（仅 Header 类型需要）
    public init(type: DropZoneType, highlightArea: CGRect, insertIndex: Int? = nil) {
        self.type = type
        self.highlightArea = highlightArea
        self.insertIndex = insertIndex
    }
}

/// Drop Zone 区域定义
///
/// 定义 hover 区域和 highlight 区域的比例。
public struct DropZoneAreaConfig: Sendable {
    /// Hover 区域比例（用于检测鼠标是否在该区域）
    public let hoverRatio: CGFloat

    /// Highlight 区域比例（用于 UI 反馈）
    public let highlightRatio: CGFloat

    /// 默认配置
    public static let `default` = DropZoneAreaConfig(
        hoverRatio: 0.25,    // hover 占 25%
        highlightRatio: 0.5  // highlight 占 50%
    )

    public init(hoverRatio: CGFloat, highlightRatio: CGFloat) {
        self.hoverRatio = hoverRatio
        self.highlightRatio = highlightRatio
    }
}
