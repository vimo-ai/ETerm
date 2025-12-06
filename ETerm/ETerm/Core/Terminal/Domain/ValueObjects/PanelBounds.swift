//
//  PanelBounds.swift
//  ETerm
//
//  领域值对象 - Panel 边界

import Foundation
import CoreGraphics

/// Panel 的边界信息
///
/// 表示一个 Panel 在容器中的位置和尺寸（逻辑坐标，单位：Points）
///
/// 坐标系说明：
/// - macOS/SwiftUI: 左下角为原点 (0,0)，Y 轴向上
/// - x, y: Panel 左下角的坐标
/// - width, height: Panel 的尺寸
struct PanelBounds: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    /// 转换为 CGRect
    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// 中心点坐标
    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }

    /// 检查是否包含指定点
    func contains(_ point: CGPoint) -> Bool {
        return point.x >= x && point.x <= x + width &&
               point.y >= y && point.y <= y + height
    }

    /// 创建一个内缩的边界（用于应用 padding）
    func inset(by padding: CGFloat) -> PanelBounds {
        PanelBounds(
            x: x + padding,
            y: y + padding,
            width: max(0, width - 2 * padding),
            height: max(0, height - 2 * padding)
        )
    }
}
