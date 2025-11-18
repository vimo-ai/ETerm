//
//  CoordinateMapper.swift
//  ETerm
//
//  基础设施层 - 坐标映射器

import Foundation
import CoreGraphics

/// 坐标映射器
///
/// 统一处理所有坐标转换，是解决坐标系混乱的关键组件
///
/// 坐标系说明：
/// 1. **Swift/macOS (NSView)**: 左下角为原点 (0,0)，Y 轴向上
/// 2. **Rust 渲染**: 左上角为原点 (0,0)，Y 轴向下
/// 3. **逻辑坐标**: Points (与屏幕分辨率无关)
/// 4. **物理坐标**: Pixels (实际渲染坐标，考虑 DPI/scale)
final class CoordinateMapper {
    private let scale: CGFloat
    private let containerBounds: CGRect

    // MARK: - Initialization

    init(scale: CGFloat, containerBounds: CGRect) {
        self.scale = scale
        self.containerBounds = containerBounds
    }

    // MARK: - 坐标系转换: Swift ↔ Rust

    /// Swift 坐标 → Rust 坐标（Y 轴翻转）
    ///
    /// Swift: 左下角原点，Y 向上
    /// Rust: 左上角原点，Y 向下
    func swiftToRust(point: CGPoint) -> CGPoint {
        return CGPoint(
            x: point.x,
            y: containerBounds.height - point.y
        )
    }

    /// Rust 坐标 → Swift 坐标（Y 轴翻转）
    func rustToSwift(point: CGPoint) -> CGPoint {
        return CGPoint(
            x: point.x,
            y: containerBounds.height - point.y
        )
    }

    /// Swift 矩形 → Rust 矩形
    func swiftToRust(rect: CGRect) -> CGRect {
        let rustOrigin = swiftToRust(
            point: CGPoint(x: rect.origin.x, y: rect.origin.y + rect.height)
        )
        return CGRect(
            x: rustOrigin.x,
            y: rustOrigin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// Rust 矩形 → Swift 矩形
    func rustToSwift(rect: CGRect) -> CGRect {
        let swiftOrigin = rustToSwift(
            point: CGPoint(x: rect.origin.x, y: rect.origin.y + rect.height)
        )
        return CGRect(
            x: swiftOrigin.x,
            y: swiftOrigin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - 逻辑坐标 ↔ 物理坐标

    /// 逻辑坐标 (Points) → 物理坐标 (Pixels)
    func logicalToPhysical(value: CGFloat) -> CGFloat {
        return value * scale
    }

    /// 物理坐标 (Pixels) → 逻辑坐标 (Points)
    func physicalToLogical(value: CGFloat) -> CGFloat {
        return value / scale
    }

    /// 逻辑点 → 物理点
    func logicalToPhysical(point: CGPoint) -> CGPoint {
        return CGPoint(
            x: point.x * scale,
            y: point.y * scale
        )
    }

    /// 物理点 → 逻辑点
    func physicalToLogical(point: CGPoint) -> CGPoint {
        return CGPoint(
            x: point.x / scale,
            y: point.y / scale
        )
    }

    // MARK: - 像素 → 终端网格

    /// 像素坐标 → 终端网格坐标
    ///
    /// - Parameters:
    ///   - point: 全局像素坐标（Swift 坐标系）
    ///   - paneOrigin: Pane 左下角坐标（Swift 坐标系）
    ///   - paneHeight: Pane 高度
    ///   - cellSize: 字符单元格尺寸
    ///   - padding: 内边距
    /// - Returns: (col, row) 网格坐标
    func pixelToGrid(
        point: CGPoint,
        paneOrigin: CGPoint,
        paneHeight: CGFloat,
        cellSize: CGSize,
        padding: CGFloat = 10.0
    ) -> (col: UInt16, row: UInt16) {
        // 1. 转换为 Pane 内的相对坐标
        let relativeX = point.x - paneOrigin.x
        let relativeY = point.y - paneOrigin.y

        // 2. 扣除 padding
        let adjustedX = max(0, relativeX - padding)
        let adjustedY = max(0, relativeY - padding)

        // 3. Y 轴翻转：Swift 向上 → 终端向下
        let contentHeight = paneHeight - 2 * padding
        let yFromTop = contentHeight - adjustedY

        // 4. 计算网格坐标
        let col = UInt16(adjustedX / cellSize.width)
        let row = UInt16(max(0, yFromTop / cellSize.height))

        return (col, row)
    }
}
