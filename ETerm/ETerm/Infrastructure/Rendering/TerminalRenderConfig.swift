//
//  TerminalRenderConfig.swift
//  ETerm
//
//  基础设施层 - 终端渲染配置

import Foundation
import CoreGraphics

/// 终端渲染配置
///
/// 将 Swift 的布局信息转换为 Rust 渲染所需的配置
/// 这是 Swift 和 Rust 之间的桥梁
struct TerminalRenderConfig {
    /// 渲染区域的 X 坐标（物理像素，Rust 坐标系）
    let x: Float

    /// 渲染区域的 Y 坐标（物理像素，Rust 坐标系）
    let y: Float

    /// 渲染区域的宽度（物理像素）
    let width: Float

    /// 渲染区域的高度（物理像素）
    let height: Float

    /// 终端列数
    let cols: UInt16

    /// 终端行数
    let rows: UInt16

    // MARK: - Factory Methods

    /// 从 PanelBounds 创建渲染配置
    ///
    /// - Parameters:
    ///   - bounds: Panel 边界（逻辑坐标，Swift 坐标系）
    ///   - mapper: 坐标映射器
    ///   - cellWidth: 字符宽度（逻辑坐标）
    ///   - cellHeight: 字符高度（逻辑坐标）
    ///   - padding: 内边距（逻辑坐标）
    /// - Returns: 终端渲染配置
    static func from(
        bounds: PanelBounds,
        mapper: CoordinateMapper,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        padding: CGFloat = 10.0
    ) -> TerminalRenderConfig {
        // 1. 计算内容区域（扣除 padding）
        let contentWidth = bounds.width - 2 * padding
        let contentHeight = bounds.height - 2 * padding

        // 2. 计算终端网格尺寸（行列）
        let cols = UInt16(max(2, contentWidth / cellWidth))
        let rows = UInt16(max(1, contentHeight / cellHeight))

        // 3. 计算渲染区域的原点（左下角 + padding）
        let swiftOrigin = CGPoint(
            x: bounds.x + padding,
            y: bounds.y + padding
        )

        // 4. 转换为 Rust 坐标系（Y 轴翻转）
        let rustOrigin = mapper.swiftToRust(point: swiftOrigin)

        // 5. 转换为物理坐标（Pixels）
        let physicalX = mapper.logicalToPhysical(value: rustOrigin.x)
        let physicalY = mapper.logicalToPhysical(value: rustOrigin.y)
        let physicalWidth = mapper.logicalToPhysical(value: contentWidth)
        let physicalHeight = mapper.logicalToPhysical(value: contentHeight)

        return TerminalRenderConfig(
            x: Float(physicalX),
            y: Float(physicalY),
            width: Float(physicalWidth),
            height: Float(physicalHeight),
            cols: cols,
            rows: rows
        )
    }
}

// MARK: - CustomStringConvertible

extension TerminalRenderConfig: CustomStringConvertible {
    var description: String {
        """
        TerminalRenderConfig(
            position: (\(x), \(y)),
            size: \(width)x\(height),
            grid: \(cols)x\(rows)
        )
        """
    }
}
