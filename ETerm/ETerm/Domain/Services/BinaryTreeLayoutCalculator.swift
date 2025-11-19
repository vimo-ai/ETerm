//
//  BinaryTreeLayoutCalculator.swift
//  ETerm
//
//  领域服务 - 二叉树布局计算器

import Foundation
import CoreGraphics

/// 二叉树布局计算器
///
/// 使用二叉树算法实现 Panel 的布局计算
final class BinaryTreeLayoutCalculator: LayoutCalculator {

    // MARK: - Public Methods

    func calculateSplitLayout(
        currentLayout: PanelLayout,
        targetPanelId: UUID,
        newPanelId: UUID,  // 🎯 接收新 Panel 的 UUID，而不是自己创建
        direction: SplitDirection
    ) -> PanelLayout {
        // 🎯 根据分割方向决定 Panel 顺序，确保符合用户习惯：
        // - vertical（上下分割）: 原 Panel 在上方，新 Panel 在下方
        // - horizontal（左右分割）: 原 Panel 在左侧，新 Panel 在右侧
        //
        // 注意：在 splitBounds 中：
        // - vertical: first 在下方，second 在上方
        // - horizontal: first 在左侧，second 在右侧
        let (firstPanel, secondPanel): (UUID, UUID) = {
            switch direction {
            case .vertical:
                // 上下分割：新 Panel 在下（first），原 Panel 在上（second）
                return (newPanelId, targetPanelId)
            case .horizontal:
                // 左右分割：原 Panel 在左（first），新 Panel 在右（second）
                return (targetPanelId, newPanelId)
            }
        }()

        // 在布局树中找到目标节点并替换为分割节点
        return replaceNode(
            in: currentLayout,
            targetId: targetPanelId,
            with: .split(
                direction: direction,
                first: .leaf(panelId: firstPanel),
                second: .leaf(panelId: secondPanel),
                ratio: 0.5  // 默认 50/50 分割
            )
        )
    }

    func calculatePanelBounds(
        layout: PanelLayout,
        containerSize: CGSize
    ) -> [UUID: PanelBounds] {
        var result: [UUID: PanelBounds] = [:]

        // 从根节点开始递归计算
        traverseLayout(
            layout: layout,
            bounds: PanelBounds(
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

    /// 在布局树中替换指定节点
    private func replaceNode(
        in layout: PanelLayout,
        targetId: UUID,
        with newNode: PanelLayout
    ) -> PanelLayout {
        switch layout {
        case .leaf(let panelId):
            // 找到目标节点，替换
            return panelId == targetId ? newNode : layout

        case .split(let direction, let first, let second, let ratio):
            // 递归查找并替换
            let newFirst = replaceNode(in: first, targetId: targetId, with: newNode)
            let newSecond = replaceNode(in: second, targetId: targetId, with: newNode)

            // 如果有子节点被替换，返回新的 split 节点
            if newFirst != first || newSecond != second {
                return .split(
                    direction: direction,
                    first: newFirst,
                    second: newSecond,
                    ratio: ratio
                )
            }

            return layout
        }
    }

    /// 递归遍历布局树，计算每个 Panel 的边界
    private func traverseLayout(
        layout: PanelLayout,
        bounds: PanelBounds,
        result: inout [UUID: PanelBounds]
    ) {
        switch layout {
        case .leaf(let panelId):
            // 叶子节点：记录边界
            result[panelId] = bounds

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
        bounds: PanelBounds,
        direction: SplitDirection,
        ratio: CGFloat
    ) -> (PanelBounds, PanelBounds) {
        let clampedRatio = max(0.1, min(0.9, ratio))  // 限制比例在 10% ~ 90%
        let dividerWidth: CGFloat = 3.0  // 分隔线宽度

        switch direction {
        case .horizontal:
            // 水平分割（左右）
            // 🎯 分割线是覆盖层，不占用布局空间
            // 直接按比例分配整个容器宽度
            let firstWidth = bounds.width * clampedRatio
            let secondWidth = bounds.width * (1 - clampedRatio)

            let firstBounds = PanelBounds(
                x: bounds.x,
                y: bounds.y,
                width: firstWidth,
                height: bounds.height
            )

            let secondBounds = PanelBounds(
                x: bounds.x + firstWidth,  // 紧接着 first panel
                y: bounds.y,
                width: secondWidth,
                height: bounds.height
            )

            return (firstBounds, secondBounds)

        case .vertical:
            // 垂直分割（上下）
            // 🎯 分割线是覆盖层，不占用布局空间
            // 直接按比例分配整个容器高度
            let firstHeight = bounds.height * clampedRatio
            let secondHeight = bounds.height * (1 - clampedRatio)

            // 注意：macOS 坐标系 Y 轴向上
            // first 在下方，second 在上方
            let firstBounds = PanelBounds(
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: firstHeight
            )

            let secondBounds = PanelBounds(
                x: bounds.x,
                y: bounds.y + firstHeight,  // 紧接着 first panel
                width: bounds.width,
                height: secondHeight
            )

            return (firstBounds, secondBounds)
        }
    }
}
