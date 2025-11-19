//
//  DropZoneCalculator.swift
//  PanelLayoutKit
//
//  Drop Zone 计算算法
//
//  参考 Golden Layout 的 stack.ts:564-678 实现
//

import Foundation
import CoreGraphics

/// Drop Zone 计算器
///
/// 负责计算 Panel 的拖拽目标区域（Drop Zone）。
/// 参考 Golden Layout 的实现。
public struct DropZoneCalculator {
    /// 区域配置
    private let config: DropZoneAreaConfig

    /// 创建 Drop Zone 计算器
    ///
    /// - Parameter config: 区域配置（默认使用标准配置）
    public init(config: DropZoneAreaConfig = .default) {
        self.config = config
    }

    /// 计算 Drop Zone
    ///
    /// - Parameters:
    ///   - panel: Panel 节点
    ///   - panelBounds: Panel 的边界（使用 macOS 坐标系）
    ///   - headerBounds: Header 的边界（Tab 区域）
    ///   - mousePosition: 鼠标位置
    /// - Returns: 计算出的 Drop Zone，如果鼠标不在任何区域则返回 nil
    public func calculateDropZone(
        panel: PanelNode,
        panelBounds: CGRect,
        headerBounds: CGRect,
        mousePosition: CGPoint
    ) -> DropZone? {
        // 1. 检查是否在 Header 区域
        if headerBounds.contains(mousePosition) {
            return calculateHeaderDropZone(
                panel: panel,
                headerBounds: headerBounds,
                mousePosition: mousePosition
            )
        }

        // 2. 如果 Panel 为空，整个 Body 都是 Drop Zone
        if panel.isEmpty {
            return DropZone(
                type: .body,
                highlightArea: panelBounds
            )
        }

        // 3. 计算 Body 区域的 Drop Zone（left/top/right/bottom）
        return calculateBodyDropZone(
            panelBounds: panelBounds,
            mousePosition: mousePosition
        )
    }

    /// 计算 Drop Zone（完整版，支持 Tab 边界）
    ///
    /// - Parameters:
    ///   - panel: Panel 节点
    ///   - panelBounds: Panel 的边界（使用 macOS 坐标系）
    ///   - headerBounds: Header 的边界（Tab 区域）
    ///   - tabBounds: Tab ID 到边界的映射（用于精确计算插入索引）
    ///   - mousePosition: 鼠标位置
    /// - Returns: 计算出的 Drop Zone，如果鼠标不在任何区域则返回 nil
    public func calculateDropZoneWithTabBounds(
        panel: PanelNode,
        panelBounds: CGRect,
        headerBounds: CGRect,
        tabBounds: [UUID: CGRect],
        mousePosition: CGPoint
    ) -> DropZone? {
        // 1. 检查是否在 Header 区域
        if headerBounds.contains(mousePosition) {
            let tabOrder = panel.tabs.map { $0.id }
            return calculateHeaderDropZoneWithTabBounds(
                panel: panel,
                headerBounds: headerBounds,
                tabBounds: tabBounds,
                tabOrder: tabOrder,
                mousePosition: mousePosition
            )
        }

        // 2. 如果 Panel 为空，整个 Body 都是 Drop Zone
        if panel.isEmpty {
            return DropZone(
                type: .body,
                highlightArea: panelBounds
            )
        }

        // 3. 计算 Body 区域的 Drop Zone（left/top/right/bottom）
        return calculateBodyDropZone(
            panelBounds: panelBounds,
            mousePosition: mousePosition
        )
    }

    // MARK: - Private Methods

    /// 计算 Header Drop Zone
    ///
    /// 在 Header 区域拖拽时，计算插入位置。
    private func calculateHeaderDropZone(
        panel: PanelNode,
        headerBounds: CGRect,
        mousePosition: CGPoint
    ) -> DropZone? {
        // 如果 Panel 为空，插入索引为 0
        if panel.isEmpty {
            return DropZone(
                type: .header,
                highlightArea: headerBounds,
                insertIndex: 0
            )
        }

        // TODO: 这里需要根据 Tab 的位置计算插入索引
        // 目前简化处理：总是插入到末尾
        // 完整实现需要：
        // 1. 获取每个 Tab 的边界
        // 2. 根据鼠标位置判断插入位置（左半部分还是右半部分）
        // 3. 返回正确的 insertIndex

        let insertIndex = panel.tabs.count

        return DropZone(
            type: .header,
            highlightArea: headerBounds,
            insertIndex: insertIndex
        )
    }

    /// 计算 Header Drop Zone（完整版，接收 Tab 边界）
    ///
    /// - Parameters:
    ///   - panel: Panel 节点
    ///   - headerBounds: Header 边界
    ///   - tabBounds: Tab ID 到边界的映射
    ///   - tabOrder: Tab 的顺序（按显示顺序）
    ///   - mousePosition: 鼠标位置
    /// - Returns: Drop Zone
    private func calculateHeaderDropZoneWithTabBounds(
        panel: PanelNode,
        headerBounds: CGRect,
        tabBounds: [UUID: CGRect],
        tabOrder: [UUID],
        mousePosition: CGPoint
    ) -> DropZone? {
        // 如果 Panel 为空，插入索引为 0
        if panel.isEmpty {
            return DropZone(
                type: .header,
                highlightArea: headerBounds,
                insertIndex: 0
            )
        }

        let mouseX = mousePosition.x

        // 遍历 Tab，找到插入位置
        for (index, tabId) in tabOrder.enumerated() {
            guard let tabBound = tabBounds[tabId] else { continue }

            let tabMidX = tabBound.midX

            // 如果鼠标在 Tab 的左半部分，插入到这个 Tab 之前
            if mouseX < tabMidX {
                return DropZone(
                    type: .header,
                    highlightArea: headerBounds,
                    insertIndex: index
                )
            }
        }

        // 如果都不满足，插入到末尾
        return DropZone(
            type: .header,
            highlightArea: headerBounds,
            insertIndex: tabOrder.count
        )
    }

    /// 计算 Body Drop Zone
    ///
    /// 在 Body 区域拖拽时，计算是哪个边缘区域（left/top/right/bottom）。
    /// 参考 Golden Layout 的算法。
    private func calculateBodyDropZone(
        panelBounds: CGRect,
        mousePosition: CGPoint
    ) -> DropZone? {
        let width = panelBounds.width
        let height = panelBounds.height
        let x = mousePosition.x - panelBounds.origin.x
        let y = mousePosition.y - panelBounds.origin.y

        // 检查鼠标是否在 Panel 边界内
        guard x >= 0 && x <= width && y >= 0 && y <= height else {
            return nil
        }

        // Golden Layout 的算法：
        // Left: x 在 0-25%
        // Right: x 在 75%-100%
        // Top: x 在 25%-75% 且 y 在 50%-100%
        // Bottom: x 在 25%-75% 且 y 在 0-50%

        let hoverRatio = config.hoverRatio
        let highlightRatio = config.highlightRatio

        // 检查左侧区域
        if x < width * hoverRatio {
            return DropZone(
                type: .left,
                highlightArea: CGRect(
                    x: panelBounds.origin.x,
                    y: panelBounds.origin.y,
                    width: width * highlightRatio,
                    height: height
                )
            )
        }

        // 检查右侧区域
        if x > width * (1 - hoverRatio) {
            return DropZone(
                type: .right,
                highlightArea: CGRect(
                    x: panelBounds.origin.x + width * (1 - highlightRatio),
                    y: panelBounds.origin.y,
                    width: width * highlightRatio,
                    height: height
                )
            )
        }

        // 检查顶部区域（macOS 坐标系：Y 向上）
        if y > height * highlightRatio {
            return DropZone(
                type: .top,
                highlightArea: CGRect(
                    x: panelBounds.origin.x,
                    y: panelBounds.origin.y + height * highlightRatio,
                    width: width,
                    height: height * highlightRatio
                )
            )
        }

        // 检查底部区域
        if y < height * highlightRatio {
            return DropZone(
                type: .bottom,
                highlightArea: CGRect(
                    x: panelBounds.origin.x,
                    y: panelBounds.origin.y,
                    width: width,
                    height: height * highlightRatio
                )
            )
        }

        // 不在任何 Drop Zone 中
        return nil
    }
}
