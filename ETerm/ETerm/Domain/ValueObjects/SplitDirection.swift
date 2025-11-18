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
