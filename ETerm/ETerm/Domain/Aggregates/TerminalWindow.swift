//
//  TerminalWindow.swift
//  ETerm
//
//  领域聚合根 - 终端窗口

import Foundation
import CoreGraphics

/// 终端窗口
///
/// 管理整个窗口的布局和所有 Panel
/// 这是布局管理的核心聚合根，负责：
/// - 维护布局树
/// - 管理 Panel 注册表
/// - 协调分割操作
final class TerminalWindow {
    let windowId: UUID
    private(set) var rootLayout: PanelLayout
    private var panelRegistry: [UUID: EditorPanel]

    // MARK: - Initialization

    init(initialPanel: EditorPanel) {
        self.windowId = UUID()
        self.rootLayout = .leaf(panelId: initialPanel.panelId)
        self.panelRegistry = [initialPanel.panelId: initialPanel]
    }

    // MARK: - Panel Management

    /// 分割指定的 Panel
    ///
    /// - Parameters:
    ///   - panelId: 要分割的 Panel ID
    ///   - direction: 分割方向
    ///   - layoutCalculator: 布局计算器
    /// - Returns: 新创建的 Panel ID，如果失败返回 nil
    func splitPanel(
        panelId: UUID,
        direction: SplitDirection,
        layoutCalculator: LayoutCalculator
    ) -> UUID? {
        // 检查 Panel 是否存在
        guard panelRegistry[panelId] != nil else {
            return nil
        }

        // 创建新 Panel（包含一个默认 Tab）
        let newPanel = EditorPanel(
            initialTab: TerminalTab(tabId: UUID(), title: "Terminal")
        )

        // 🎯 计算新布局，传入新 Panel 的 ID
        rootLayout = layoutCalculator.calculateSplitLayout(
            currentLayout: rootLayout,
            targetPanelId: panelId,
            newPanelId: newPanel.panelId,  // 使用实际的 Panel ID
            direction: direction
        )

        // 注册新 Panel
        panelRegistry[newPanel.panelId] = newPanel

        return newPanel.panelId
    }

    /// 获取指定 Panel
    func getPanel(_ panelId: UUID) -> EditorPanel? {
        return panelRegistry[panelId]
    }

    /// 获取所有 Panel
    var allPanels: [EditorPanel] {
        return Array(panelRegistry.values)
    }

    /// Panel 数量
    var panelCount: Int {
        return panelRegistry.count
    }

    /// 获取所有 Panel ID
    var allPanelIds: [UUID] {
        return rootLayout.allPanelIds()
    }

    // MARK: - Rendering

    /// 获取所有需要渲染的 Tab
    ///
    /// 这是渲染流程的入口，遍历所有 Panel，收集激活的 Tab 及其位置信息
    ///
    /// - Parameters:
    ///   - containerBounds: 容器的尺寸
    ///   - headerHeight: Tab Bar 的高度
    /// - Returns: 数组 [(terminalId, contentBounds)]
    func getActiveTabsForRendering(
        containerBounds: CGRect,
        headerHeight: CGFloat
    ) -> [(UInt32, CGRect)] {
        // 先更新所有 Panel 的 bounds（基于当前的 rootLayout）
        updatePanelBounds(containerBounds: containerBounds)

        // 收集所有激活的 Tab
        var result: [(UInt32, CGRect)] = []

        for panel in allPanels {
            if let (terminalId, contentBounds) = panel.getActiveTabForRendering(headerHeight: headerHeight) {
                result.append((terminalId, contentBounds))
            }
        }

        return result
    }

    /// 更新所有 Panel 的位置和尺寸
    ///
    /// 根据布局树计算每个 Panel 的 bounds，并更新到 Panel 对象
    private func updatePanelBounds(containerBounds: CGRect) {
        // 递归遍历布局树，计算每个 Panel 的 bounds
        calculatePanelBounds(layout: rootLayout, availableBounds: containerBounds)
    }

    /// 递归计算 Panel 的 bounds
    private func calculatePanelBounds(layout: PanelLayout, availableBounds: CGRect) {
        switch layout {
        case .leaf(let panelId):
            // 叶子节点：更新 Panel 的 bounds
            if let panel = panelRegistry[panelId] {
                panel.updateBounds(availableBounds)
            }

        case .split(let direction, let first, let second, let ratio):
            // 分割节点：分配空间给两个子节点
            let dividerThickness: CGFloat = 1.0

            switch direction {
            case .horizontal:
                // 水平分割（左右）
                let firstWidth = availableBounds.width * ratio - dividerThickness / 2
                let secondWidth = availableBounds.width * (1 - ratio) - dividerThickness / 2

                let firstBounds = CGRect(
                    x: availableBounds.minX,
                    y: availableBounds.minY,
                    width: firstWidth,
                    height: availableBounds.height
                )

                let secondBounds = CGRect(
                    x: availableBounds.minX + firstWidth + dividerThickness,
                    y: availableBounds.minY,
                    width: secondWidth,
                    height: availableBounds.height
                )

                calculatePanelBounds(layout: first, availableBounds: firstBounds)
                calculatePanelBounds(layout: second, availableBounds: secondBounds)

            case .vertical:
                // 垂直分割（上下）
                let firstHeight = availableBounds.height * ratio - dividerThickness / 2
                let secondHeight = availableBounds.height * (1 - ratio) - dividerThickness / 2

                let firstBounds = CGRect(
                    x: availableBounds.minX,
                    y: availableBounds.minY + secondHeight + dividerThickness,
                    width: availableBounds.width,
                    height: firstHeight
                )

                let secondBounds = CGRect(
                    x: availableBounds.minX,
                    y: availableBounds.minY,
                    width: availableBounds.width,
                    height: secondHeight
                )

                calculatePanelBounds(layout: first, availableBounds: firstBounds)
                calculatePanelBounds(layout: second, availableBounds: secondBounds)
            }
        }
    }

    // MARK: - Layout Query

    /// 检查布局是否包含指定 Panel
    func containsPanel(_ panelId: UUID) -> Bool {
        return rootLayout.contains(panelId)
    }

    /// 更新分隔线比例
    ///
    /// - Parameters:
    ///   - path: 布局路径
    ///   - newRatio: 新的比例
    func updateDividerRatio(path: [Int], newRatio: CGFloat) {
        rootLayout = updateRatioInLayout(layout: rootLayout, path: path, newRatio: newRatio)
    }

    // MARK: - Private Helpers

    /// 递归更新布局树中的比例
    private func updateRatioInLayout(
        layout: PanelLayout,
        path: [Int],
        newRatio: CGFloat
    ) -> PanelLayout {
        // 如果路径为空,说明到达目标节点
        if path.isEmpty {
            switch layout {
            case .split(let direction, let first, let second, _):
                return .split(
                    direction: direction,
                    first: first,
                    second: second,
                    ratio: newRatio
                )
            case .leaf:
                return layout  // 叶子节点不能更新比例
            }
        }

        // 继续递归
        guard let nextIndex = path.first else {
            return layout
        }

        let remainingPath = Array(path.dropFirst())

        switch layout {
        case .split(let direction, let first, let second, let ratio):
            if nextIndex == 0 {
                // 更新 first 分支
                let newFirst = updateRatioInLayout(
                    layout: first,
                    path: remainingPath,
                    newRatio: newRatio
                )
                return .split(
                    direction: direction,
                    first: newFirst,
                    second: second,
                    ratio: ratio
                )
            } else {
                // 更新 second 分支
                let newSecond = updateRatioInLayout(
                    layout: second,
                    path: remainingPath,
                    newRatio: newRatio
                )
                return .split(
                    direction: direction,
                    first: first,
                    second: newSecond,
                    ratio: ratio
                )
            }

        case .leaf:
            return layout  // 叶子节点,返回原样
        }
    }
}

// MARK: - Equatable

extension TerminalWindow: Equatable {
    static func == (lhs: TerminalWindow, rhs: TerminalWindow) -> Bool {
        lhs.windowId == rhs.windowId
    }
}

// MARK: - Hashable

extension TerminalWindow: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }
}
