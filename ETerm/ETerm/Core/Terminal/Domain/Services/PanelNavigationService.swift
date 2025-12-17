//
//  PanelNavigationService.swift
//  ETerm
//
//  领域服务 - Panel 导航
//
//  提供基于方向的 Panel 焦点导航功能
//
//  算法说明：
//  - 水平导航（左/右）：看当前 Panel 的顶部 Y 坐标落在哪个候选 Panel 的 Y 范围内
//  - 垂直导航（上/下）：看当前 Panel 的左边缘 X 坐标落在哪个候选 Panel 的 X 范围内
//  - 边界情况使用 fallback 选择最接近的候选

import Foundation
import CoreGraphics

/// Panel 导航服务
///
/// 根据当前 Panel 和方向，计算最近的目标 Panel
final class PanelNavigationService {

    /// 查找指定方向最近的 Panel
    ///
    /// - Parameters:
    ///   - currentPanelId: 当前 Panel ID
    ///   - direction: 导航方向
    ///   - page: 所在的 Page
    ///   - containerBounds: 容器尺寸（用于计算 Panel 位置）
    /// - Returns: 目标 Panel ID，无目标返回 nil
    static func findNearestPanel(
        from currentPanelId: UUID,
        direction: NavigationDirection,
        in page: Page,
        containerBounds: CGRect
    ) -> UUID? {
        // 1. 获取当前 Panel
        guard let currentPanel = page.getPanel(currentPanelId) else {
            return nil
        }

        // 2. 更新所有 Panel 的 bounds（确保坐标最新）
        updatePanelBounds(page: page, containerBounds: containerBounds)

        let currentBounds = currentPanel.bounds

        // 3. 筛选目标方向的候选 Panel
        let candidates = page.allPanels.filter { panel in
            guard panel.panelId != currentPanelId else { return false }
            return isInDirection(panel.bounds, from: currentBounds, direction: direction)
        }

        // 4. 如果没有候选，返回 nil
        guard !candidates.isEmpty else {
            return nil
        }

        // 5. 使用边缘匹配算法找目标
        return findTargetByEdgeMatching(
            from: currentBounds,
            candidates: candidates,
            direction: direction
        )
    }

    // MARK: - Private Helpers

    /// 判断候选 Panel 是否在目标方向
    private static func isInDirection(
        _ candidateBounds: CGRect,
        from currentBounds: CGRect,
        direction: NavigationDirection
    ) -> Bool {
        // macOS 坐标系：左下角是原点，Y 轴向上
        switch direction {
        case .up:
            return candidateBounds.midY > currentBounds.midY
        case .down:
            return candidateBounds.midY < currentBounds.midY
        case .left:
            return candidateBounds.midX < currentBounds.midX
        case .right:
            return candidateBounds.midX > currentBounds.midX
        }
    }

    /// 使用边缘匹配算法找到目标 Panel
    ///
    /// - 水平导航：看当前 Panel 的顶部 Y 落在哪个候选的 Y 范围内，多个匹配时选 X 距离最近的
    /// - 垂直导航：看当前 Panel 的左边缘 X 落在哪个候选的 X 范围内，多个匹配时选 Y 距离最近的
    private static func findTargetByEdgeMatching(
        from currentBounds: CGRect,
        candidates: [EditorPanel],
        direction: NavigationDirection
    ) -> UUID? {
        switch direction {
        case .left, .right:
            // 水平导航：使用顶部 Y 坐标匹配
            let topY = currentBounds.maxY
            return findByYMatching(topY: topY, candidates: candidates, direction: direction)

        case .up, .down:
            // 垂直导航：使用左边缘 X 坐标匹配
            let leftX = currentBounds.minX
            return findByXMatching(leftX: leftX, candidates: candidates, direction: direction)
        }
    }

    /// 水平导航：找 Y 范围包含当前顶部的 Panel
    private static func findByYMatching(
        topY: CGFloat,
        candidates: [EditorPanel],
        direction: NavigationDirection
    ) -> UUID? {
        // 筛选 Y 范围包含 topY 的候选
        let matched = candidates.filter { panel in
            panel.bounds.minY <= topY && topY <= panel.bounds.maxY
        }

        if matched.isEmpty {
            // fallback：没有精确匹配，选择 Y 范围最接近 topY 的
            return fallbackByYDistance(topY: topY, candidates: candidates, direction: direction)
        }

        if matched.count == 1 {
            return matched.first?.panelId
        }

        // 多个匹配时，选 X 距离最近的（往左选最右边的，往右选最左边的）
        let sorted: [EditorPanel]
        switch direction {
        case .left:
            // 往左：选 X 最大的（最靠右，离当前最近）
            sorted = matched.sorted { $0.bounds.maxX > $1.bounds.maxX }
        case .right:
            // 往右：选 X 最小的（最靠左，离当前最近）
            sorted = matched.sorted { $0.bounds.minX < $1.bounds.minX }
        default:
            sorted = matched
        }
        return sorted.first?.panelId
    }

    /// 垂直导航：找 X 范围包含当前左边缘的 Panel
    private static func findByXMatching(
        leftX: CGFloat,
        candidates: [EditorPanel],
        direction: NavigationDirection
    ) -> UUID? {
        // 筛选 X 范围包含 leftX 的候选
        let matched = candidates.filter { panel in
            panel.bounds.minX <= leftX && leftX <= panel.bounds.maxX
        }

        if matched.isEmpty {
            // fallback：没有精确匹配，选择 X 范围最接近 leftX 的
            return fallbackByXDistance(leftX: leftX, candidates: candidates, direction: direction)
        }

        if matched.count == 1 {
            return matched.first?.panelId
        }

        // 多个匹配时，选 Y 距离最近的（往上选最下面的，往下选最上面的）
        let sorted: [EditorPanel]
        switch direction {
        case .up:
            // 往上：选 Y 最小的（最靠下，离当前最近）
            sorted = matched.sorted { $0.bounds.minY < $1.bounds.minY }
        case .down:
            // 往下：选 Y 最大的（最靠上，离当前最近）
            sorted = matched.sorted { $0.bounds.maxY > $1.bounds.maxY }
        default:
            sorted = matched
        }
        return sorted.first?.panelId
    }

    /// fallback：按 Y 距离选择最近的，然后按 X 距离选最近的
    private static func fallbackByYDistance(
        topY: CGFloat,
        candidates: [EditorPanel],
        direction: NavigationDirection
    ) -> UUID? {
        let sorted = candidates.sorted { panel1, panel2 in
            let dist1 = min(abs(panel1.bounds.minY - topY), abs(panel1.bounds.maxY - topY))
            let dist2 = min(abs(panel2.bounds.minY - topY), abs(panel2.bounds.maxY - topY))
            if dist1 == dist2 {
                // Y 距离相同时，选 X 距离最近的
                switch direction {
                case .left:
                    return panel1.bounds.maxX > panel2.bounds.maxX
                case .right:
                    return panel1.bounds.minX < panel2.bounds.minX
                default:
                    return panel1.bounds.maxY > panel2.bounds.maxY
                }
            }
            return dist1 < dist2
        }
        return sorted.first?.panelId
    }

    /// fallback：按 X 距离选择最近的，然后按 Y 距离选最近的
    private static func fallbackByXDistance(
        leftX: CGFloat,
        candidates: [EditorPanel],
        direction: NavigationDirection
    ) -> UUID? {
        let sorted = candidates.sorted { panel1, panel2 in
            let dist1 = min(abs(panel1.bounds.minX - leftX), abs(panel1.bounds.maxX - leftX))
            let dist2 = min(abs(panel2.bounds.minX - leftX), abs(panel2.bounds.maxX - leftX))
            if dist1 == dist2 {
                // X 距离相同时，选 Y 距离最近的
                switch direction {
                case .up:
                    return panel1.bounds.minY < panel2.bounds.minY
                case .down:
                    return panel1.bounds.maxY > panel2.bounds.maxY
                default:
                    return panel1.bounds.minX < panel2.bounds.minX
                }
            }
            return dist1 < dist2
        }
        return sorted.first?.panelId
    }

    /// 更新 Page 中所有 Panel 的 bounds
    private static func updatePanelBounds(page: Page, containerBounds: CGRect) {
        _ = page.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: 30.0
        )
    }
}
