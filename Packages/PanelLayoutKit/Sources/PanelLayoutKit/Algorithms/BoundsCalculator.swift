//
//  BoundsCalculator.swift
//  PanelLayoutKit
//
//  边界计算算法
//

import Foundation
import CoreGraphics

/// 边界计算器
///
/// 负责计算布局树中每个 Panel 的边界。
public struct BoundsCalculator {
    /// 分隔线宽度
    private let dividerWidth: CGFloat

    /// 最小比例（防止 Panel 过小）
    private let minRatio: CGFloat = 0.1

    /// 最大比例（防止 Panel 过大）
    private let maxRatio: CGFloat = 0.9

    /// 创建边界计算器
    ///
    /// - Parameter dividerWidth: 分隔线宽度（默认 3.0）
    public init(dividerWidth: CGFloat = 3.0) {
        self.dividerWidth = dividerWidth
    }

    /// 计算 Panel 边界
    ///
    /// - Parameters:
    ///   - layout: 布局树
    ///   - containerSize: 容器尺寸
    /// - Returns: Panel ID 到边界的映射
    public func calculatePanelBounds(
        layout: LayoutTree,
        containerSize: CGSize
    ) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]

        // 从根节点开始递归计算
        traverseLayout(
            layout: layout,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: containerSize.width,
                height: containerSize.height
            ),
            result: &result
        )

        return result
    }

    // MARK: - Private Methods

    /// 递归遍历布局树，计算每个 Panel 的边界
    private func traverseLayout(
        layout: LayoutTree,
        bounds: CGRect,
        result: inout [UUID: CGRect]
    ) {
        switch layout {
        case .panel(let panelNode):
            // 叶子节点：记录边界
            result[panelNode.id] = bounds

        case .split(let direction, let first, let second, let ratio):
            // 分割节点：计算子节点的边界
            let (firstBounds, secondBounds) = splitBounds(
                bounds: bounds,
                direction: direction,
                ratio: ratio
            )

            // 递归处理子节点
            traverseLayout(layout: first, bounds: firstBounds, result: &result)
            traverseLayout(layout: second, bounds: secondBounds, result: &result)
        }
    }

    /// 根据分割方向和比例，将边界分割为两部分
    private func splitBounds(
        bounds: CGRect,
        direction: SplitDirection,
        ratio: CGFloat
    ) -> (CGRect, CGRect) {
        let clampedRatio = max(minRatio, min(maxRatio, ratio))

        switch direction {
        case .horizontal:
            // 水平分割（左右）
            let firstWidth = bounds.width * clampedRatio
            let secondWidth = bounds.width * (1 - clampedRatio)

            let firstBounds = CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: firstWidth,
                height: bounds.height
            )

            let secondBounds = CGRect(
                x: bounds.origin.x + firstWidth,
                y: bounds.origin.y,
                width: secondWidth,
                height: bounds.height
            )

            return (firstBounds, secondBounds)

        case .vertical:
            // 垂直分割（上下）
            let firstHeight = bounds.height * clampedRatio
            let secondHeight = bounds.height * (1 - clampedRatio)

            // macOS 坐标系：Y 轴向上
            // first 在下方，second 在上方
            let firstBounds = CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: firstHeight
            )

            let secondBounds = CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y + firstHeight,
                width: bounds.width,
                height: secondHeight
            )

            return (firstBounds, secondBounds)
        }
    }
}
