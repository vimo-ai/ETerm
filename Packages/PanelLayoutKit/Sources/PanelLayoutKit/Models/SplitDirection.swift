//
//  SplitDirection.swift
//  PanelLayoutKit
//
//  分割方向
//

import Foundation

/// 分割方向
///
/// 定义 Panel 的分割方向：
/// - horizontal: 水平分割（左右）
/// - vertical: 垂直分割（上下）
public enum SplitDirection: String, Codable, Equatable, Hashable {
    /// 水平分割（左右）
    /// first 在左侧，second 在右侧
    case horizontal

    /// 垂直分割（上下）
    /// first 在下方，second 在上方（macOS 坐标系）
    case vertical
}
