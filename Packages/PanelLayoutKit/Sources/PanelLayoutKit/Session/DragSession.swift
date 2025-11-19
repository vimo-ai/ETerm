//
//  DragSession.swift
//  PanelLayoutKit
//
//  拖拽会话管理
//

import Foundation
import CoreGraphics

/// 拖拽状态
public enum DragState: Equatable {
    /// 未开始
    case idle

    /// 拖拽中
    case dragging(tab: TabNode, sourcePanelId: UUID)

    /// 拖拽结束
    case ended
}

/// 拖拽会话
///
/// 管理拖拽过程中的状态，包括：
/// - 被拖拽的 Tab
/// - 当前的 Drop Zone
/// - 鼠标位置
public class DragSession {
    /// 当前状态
    private(set) var state: DragState = .idle

    /// 当前的 Drop Zone
    private(set) var currentDropZone: (panelId: UUID, zone: DropZone)?

    /// 当前鼠标位置
    private(set) var currentMousePosition: CGPoint = .zero

    /// Drop Zone 计算器
    private let dropZoneCalculator: DropZoneCalculator

    /// 边界计算器
    private let boundsCalculator: BoundsCalculator

    /// Header 高度（用于计算 Header 边界）
    private let headerHeight: CGFloat

    /// 创建拖拽会话
    ///
    /// - Parameters:
    ///   - dropZoneCalculator: Drop Zone 计算器
    ///   - boundsCalculator: 边界计算器
    ///   - headerHeight: Header 高度
    public init(
        dropZoneCalculator: DropZoneCalculator = DropZoneCalculator(),
        boundsCalculator: BoundsCalculator = BoundsCalculator(),
        headerHeight: CGFloat = 30.0
    ) {
        self.dropZoneCalculator = dropZoneCalculator
        self.boundsCalculator = boundsCalculator
        self.headerHeight = headerHeight
    }

    /// 开始拖拽
    ///
    /// - Parameters:
    ///   - tab: 被拖拽的 Tab
    ///   - sourcePanelId: 源 Panel ID
    public func startDrag(tab: TabNode, sourcePanelId: UUID) {
        state = .dragging(tab: tab, sourcePanelId: sourcePanelId)
        currentDropZone = nil
    }

    /// 更新鼠标位置
    ///
    /// - Parameters:
    ///   - position: 新的鼠标位置
    ///   - layout: 当前布局树
    ///   - containerSize: 容器尺寸
    public func updatePosition(
        _ position: CGPoint,
        layout: LayoutTree,
        containerSize: CGSize
    ) {
        currentMousePosition = position

        // 计算所有 Panel 的边界
        let panelBounds = boundsCalculator.calculatePanelBounds(
            layout: layout,
            containerSize: containerSize
        )

        // 查找鼠标所在的 Panel 和 Drop Zone
        currentDropZone = findDropZone(
            mousePosition: position,
            layout: layout,
            panelBounds: panelBounds
        )
    }

    /// 结束拖拽
    ///
    /// - Returns: 拖拽结果（目标 Panel ID 和 Drop Zone）
    public func endDrag() -> (tabId: UUID, panelId: UUID, dropZone: DropZone)? {
        defer {
            state = .ended
            currentDropZone = nil
        }

        guard case .dragging(let tab, _) = state,
              let (panelId, zone) = currentDropZone else {
            return nil
        }

        return (tab.id, panelId, zone)
    }

    /// 取消拖拽
    public func cancelDrag() {
        state = .idle
        currentDropZone = nil
    }

    // MARK: - Private Methods

    /// 查找鼠标所在的 Drop Zone
    private func findDropZone(
        mousePosition: CGPoint,
        layout: LayoutTree,
        panelBounds: [UUID: CGRect]
    ) -> (UUID, DropZone)? {
        // 遍历所有 Panel，查找包含鼠标位置的 Panel
        for panel in layout.allPanels() {
            guard let bounds = panelBounds[panel.id] else {
                continue
            }

            // 检查鼠标是否在 Panel 范围内（包括 Header）
            let panelWithHeaderBounds = expandBoundsForHeader(bounds)
            if !panelWithHeaderBounds.contains(mousePosition) {
                continue
            }

            // 计算 Header 边界
            let headerBounds = calculateHeaderBounds(from: bounds)

            // 计算 Drop Zone
            if let dropZone = dropZoneCalculator.calculateDropZone(
                panel: panel,
                panelBounds: bounds,
                headerBounds: headerBounds,
                mousePosition: mousePosition
            ) {
                return (panel.id, dropZone)
            }
        }

        return nil
    }

    /// 扩展边界以包含 Header
    private func expandBoundsForHeader(_ bounds: CGRect) -> CGRect {
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height + headerHeight
        )
    }

    /// 计算 Header 边界
    private func calculateHeaderBounds(from panelBounds: CGRect) -> CGRect {
        // Header 在 Panel 顶部
        return CGRect(
            x: panelBounds.origin.x,
            y: panelBounds.origin.y + panelBounds.height,
            width: panelBounds.width,
            height: headerHeight
        )
    }
}
