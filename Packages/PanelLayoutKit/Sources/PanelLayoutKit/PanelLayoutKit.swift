//
//  PanelLayoutKit.swift
//  PanelLayoutKit
//
//  Panel 布局核心算法库
//
//  PanelLayoutKit 是一个独立的 Swift Package，提供类似 VS Code/Golden Layout
//  的多 Panel + Tab 布局系统的拖拽重排功能。
//
//  主要功能：
//  - Drop Zone 计算算法
//  - 布局树重构算法
//  - 边界计算
//  - 拖拽状态管理
//

import Foundation
import CoreGraphics

// MARK: - Public API

/// PanelLayoutKit 主入口
///
/// 提供便捷的 API 用于处理 Panel 布局和拖拽。
public struct PanelLayoutKit {
    /// Drop Zone 计算器
    public let dropZoneCalculator: DropZoneCalculator

    /// 布局重构器
    public let layoutRestructurer: LayoutRestructurer

    /// 边界计算器
    public let boundsCalculator: BoundsCalculator

    /// 创建 PanelLayoutKit 实例
    ///
    /// - Parameters:
    ///   - dropZoneConfig: Drop Zone 配置（默认使用标准配置）
    ///   - dividerWidth: 分隔线宽度（默认 3.0）
    public init(
        dropZoneConfig: DropZoneAreaConfig = .default,
        dividerWidth: CGFloat = 3.0
    ) {
        self.dropZoneCalculator = DropZoneCalculator(config: dropZoneConfig)
        self.layoutRestructurer = LayoutRestructurer()
        self.boundsCalculator = BoundsCalculator(dividerWidth: dividerWidth)
    }

    /// 计算 Panel 边界
    ///
    /// - Parameters:
    ///   - layout: 布局树
    ///   - containerSize: 容器尺寸
    /// - Returns: Panel ID 到边界的映射
    public func calculateBounds(
        layout: LayoutTree,
        containerSize: CGSize
    ) -> [UUID: CGRect] {
        return boundsCalculator.calculatePanelBounds(
            layout: layout,
            containerSize: containerSize
        )
    }

    /// 计算 Drop Zone
    ///
    /// - Parameters:
    ///   - panel: Panel 节点
    ///   - panelBounds: Panel 边界
    ///   - headerBounds: Header 边界
    ///   - mousePosition: 鼠标位置
    /// - Returns: Drop Zone（如果不在任何区域则返回 nil）
    public func calculateDropZone(
        panel: PanelNode,
        panelBounds: CGRect,
        headerBounds: CGRect,
        mousePosition: CGPoint
    ) -> DropZone? {
        return dropZoneCalculator.calculateDropZone(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            mousePosition: mousePosition
        )
    }

    /// 处理拖拽结束
    ///
    /// - Parameters:
    ///   - layout: 当前布局树
    ///   - tab: 被拖拽的 Tab
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 新的布局树
    public func handleDrop(
        layout: LayoutTree,
        tab: TabNode,
        dropZone: DropZone,
        targetPanelId: UUID
    ) -> LayoutTree {
        return layoutRestructurer.handleDrop(
            layout: layout,
            tab: tab,
            dropZone: dropZone,
            targetPanelId: targetPanelId
        )
    }

    /// 创建拖拽会话
    ///
    /// - Parameter headerHeight: Header 高度（默认 30.0）
    /// - Returns: 新的拖拽会话
    public func createDragSession(headerHeight: CGFloat = 30.0) -> DragSession {
        return DragSession(
            dropZoneCalculator: dropZoneCalculator,
            boundsCalculator: boundsCalculator,
            headerHeight: headerHeight
        )
    }
}
