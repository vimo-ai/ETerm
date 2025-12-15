//
//  LayoutCalculator.swift
//  ETerm
//
//  领域服务 - 布局计算器协议

import Foundation
import CoreGraphics

/// 布局计算器协议
///
/// 定义了布局系统的核心算法接口
protocol LayoutCalculator {
    /// 计算分割后的新布局
    ///
    /// - Parameters:
    ///   - currentLayout: 当前的布局树
    ///   - targetPanelId: 要分割的 Panel ID
    ///   - newPanelId: 新创建的 Panel ID
    ///   - direction: 分割方向
    /// - Returns: 新的布局树
    func calculateSplitLayout(
        currentLayout: PanelLayout,
        targetPanelId: UUID,
        newPanelId: UUID,
        direction: SplitDirection
    ) -> PanelLayout

    /// 计算分割后的新布局（使用 EdgeDirection 精确控制位置）
    ///
    /// - Parameters:
    ///   - currentLayout: 当前的布局树
    ///   - targetPanelId: 要分割的 Panel ID
    ///   - newPanelId: 新创建的 Panel ID
    ///   - edge: 边缘方向（决定新 Panel 在目标 Panel 的哪个边缘）
    /// - Returns: 新的布局树
    func calculateSplitLayout(
        currentLayout: PanelLayout,
        targetPanelId: UUID,
        newPanelId: UUID,
        edge: EdgeDirection
    ) -> PanelLayout

    /// 使用已有 Panel 计算分割后的新布局（用于 Panel 移动）
    ///
    /// - Parameters:
    ///   - currentLayout: 当前的布局树（已移除要移动的 Panel）
    ///   - targetPanelId: 要分割的 Panel ID
    ///   - existingPanelId: 已有的 Panel ID（要插入的）
    ///   - edge: 边缘方向（决定 Panel 的位置：top/left 为 first，bottom/right 为 second）
    /// - Returns: 新的布局树
    func calculateSplitLayoutWithExistingPanel(
        currentLayout: PanelLayout,
        targetPanelId: UUID,
        existingPanelId: UUID,
        edge: EdgeDirection
    ) -> PanelLayout

    /// 计算所有 Panel 的边界
    ///
    /// - Parameters:
    ///   - layout: 布局树
    ///   - containerSize: 容器尺寸（逻辑坐标，Points）
    /// - Returns: Panel ID 到边界的映射
    func calculatePanelBounds(
        layout: PanelLayout,
        containerSize: CGSize
    ) -> [UUID: PanelBounds]
}
