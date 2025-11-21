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
    
    /// 下一个终端编号（全局唯一）
    private var nextTerminalNumber: Int = 1

    // MARK: - Initialization

    init(initialPanel: EditorPanel) {
        self.windowId = UUID()
        self.rootLayout = .leaf(panelId: initialPanel.panelId)
        self.panelRegistry = [initialPanel.panelId: initialPanel]
        
        // 初始化计数器
        scanAndInitNextTerminalNumber()
    }
    
    /// 生成下一个 Tab 标题
    func generateNextTabTitle() -> String {
        let title = "终端 \(nextTerminalNumber)"
        nextTerminalNumber += 1
        return title
    }
    
    /// 扫描现有 Tab 初始化计数器
    private func scanAndInitNextTerminalNumber() {
        var maxNumber = 0
        for panel in allPanels {
            for tab in panel.tabs {
                if let title = tab.title.components(separatedBy: " ").last,
                   let number = Int(title) {
                    maxNumber = max(maxNumber, number)
                }
            }
        }
        nextTerminalNumber = maxNumber + 1
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

        // 创建新 Panel（包含一个默认 Tab，使用唯一标题）
        let newPanel = EditorPanel(
            initialTab: TerminalTab(tabId: UUID(), title: generateNextTabTitle())
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

    /// 移除指定 Panel
    ///
    /// 当 Panel 中的最后一个 Tab 被移走时调用
    /// - Returns: 是否成功移除
    func removePanel(_ panelId: UUID) -> Bool {
        // 1. 检查 Panel 是否存在
        guard panelRegistry[panelId] != nil else {
            return false
        }

        // 2. 根节点不能移除（至少保留一个 Panel）
        if case .leaf(let id) = rootLayout, id == panelId {
            return false
        }

        // 3. 从布局树中移除
        guard let newLayout = removePanelFromLayout(layout: rootLayout, panelId: panelId) else {
            return false
        }

        // 4. 更新状态
        rootLayout = newLayout
        panelRegistry.removeValue(forKey: panelId)

        return true
    }

    // MARK: - Private Helpers

    /// 从布局树中移除 Panel
    ///
    /// - Returns: 更新后的布局，如果该分支被完全移除则返回 nil
    private func removePanelFromLayout(layout: PanelLayout, panelId: UUID) -> PanelLayout? {
        switch layout {
        case .leaf(let id):
            // 如果是目标 Panel，返回 nil（表示移除）
            return id == panelId ? nil : layout

        case .split(let direction, let first, let second, let ratio):
            // 递归处理子节点
            let newFirst = removePanelFromLayout(layout: first, panelId: panelId)
            let newSecond = removePanelFromLayout(layout: second, panelId: panelId)

            // 根据子节点的移除情况重组布局
            if let f = newFirst, let s = newSecond {
                // 两个子节点都在，保持 Split
                return .split(direction: direction, first: f, second: s, ratio: ratio)
            } else if let f = newFirst {
                // 只剩第一个子节点，提升它（Collapse）
                return f
            } else if let s = newSecond {
                // 只剩第二个子节点，提升它（Collapse）
                return s
            } else {
                // 两个子节点都没了（理论上不应该发生，除非移除了整个分支）
                return nil
            }
        }
    }

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
