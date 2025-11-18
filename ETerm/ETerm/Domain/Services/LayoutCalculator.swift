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
    ///   - direction: 分割方向
    /// - Returns: 新的布局树
    func calculateSplitLayout(
        currentLayout: PanelLayout,
        targetPanelId: UUID,
        direction: SplitDirection
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
