//
//  SplitDirection.swift
//  ETerm
//
//  领域值对象 - 分割方向

import Foundation

/// 分割方向
///
/// 表示 Panel 的分割方向，是布局树中的核心概念
enum SplitDirection {
    /// 水平分割（左右布局）
    case horizontal

    /// 垂直分割（上下布局）
    case vertical
}

/// 边缘方向
///
/// 表示拖拽到目标 Panel 的哪个边缘
enum EdgeDirection {
    case top
    case bottom
    case left
    case right

    /// 转换为 SplitDirection
    var splitDirection: SplitDirection {
        switch self {
        case .top, .bottom:
            return .vertical
        case .left, .right:
            return .horizontal
        }
    }

    /// 移动的 Panel 是否应该放在 first 位置
    ///
    /// - top/left: existingPanel 放在 first（上/左）
    /// - bottom/right: existingPanel 放在 second（下/右）
    var existingPanelIsFirst: Bool {
        switch self {
        case .top, .left:
            return true
        case .bottom, .right:
            return false
        }
    }
}
