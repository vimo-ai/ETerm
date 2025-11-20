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
