//
//  PanelDivider.swift
//  ETerm
//
//  领域值对象 - Panel 分隔线

import Foundation
import CoreGraphics
import AppKit

/// Panel 分隔线信息
///
/// 表示两个 Panel 之间的分隔线,用于拖动调整 Panel 尺寸
struct PanelDivider {
    /// 分隔线类型
    let direction: SplitDirection

    /// 第一个 Panel ID
    let firstPanelId: UUID

    /// 第二个 Panel ID
    let secondPanelId: UUID

    /// 分隔线位置 (逻辑坐标, Points)
    let position: CGFloat

    /// 分隔线对应的布局节点路径 (用于更新 ratio)
    let layoutPath: [Int]  // 从根节点到此分割节点的路径

    // MARK: - Helper Methods

    /// 检查点是否在分隔线附近
    ///
    /// - Parameters:
    ///   - point: 点击位置 (Swift 坐标系, Points)
    ///   - containerBounds: 容器边界
    ///   - tolerance: 容差 (Points)
    /// - Returns: 是否在分隔线附近
    func contains(point: CGPoint, in containerBounds: CGRect, tolerance: CGFloat = 5.0) -> Bool {
        switch direction {
        case .horizontal:
            // 垂直分隔线 (左右分割)
            // position 是 X 坐标
            return abs(point.x - position) <= tolerance &&
                   point.y >= containerBounds.minY &&
                   point.y <= containerBounds.maxY

        case .vertical:
            // 水平分隔线 (上下分割)
            // position 是 Y 坐标
            return abs(point.y - position) <= tolerance &&
                   point.x >= containerBounds.minX &&
                   point.x <= containerBounds.maxX
        }
    }

    /// 获取对应的鼠标指针
    var cursor: NSCursor {
        switch direction {
        case .horizontal:
            return .resizeLeftRight
        case .vertical:
            return .resizeUpDown
        }
    }
}
