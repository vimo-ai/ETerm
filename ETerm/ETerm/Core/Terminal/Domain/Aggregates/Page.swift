//
//  Page.swift
//  ETerm
//
//  领域聚合根 - 页面
//
//  类似 tmux 的 window 概念，每个 Page 独立维护：
//  - 布局树（rootLayout）
//  - Panel 注册表（panelRegistry）
//
//  设计说明：
//  - Page 是 Window 下一级的容器
//  - Tab 编号由 TerminalWindow 统一管理（跨 Page 全局唯一）
//  - Page 可以被重命名

import Foundation
import CoreGraphics
import SwiftUI

/// 页面聚合根
///
/// 管理单个页面的布局和 Panel
/// 每个 Page 维护自己独立的布局树和 Panel 集合
final class Page {
    let pageId: UUID
    private(set) var title: String
    private(set) var rootLayout: PanelLayout
    private var panelRegistry: [UUID: EditorPanel]

    /// 页面内容类型（终端或插件）
    private(set) var content: PageContent

    // MARK: - Initialization

    /// 创建 Page（使用已有的 Panel）
    ///
    /// - Parameters:
    ///   - title: 页面标题
    ///   - initialPanel: 初始 Panel
    init(title: String, initialPanel: EditorPanel) {
        self.pageId = UUID()
        self.title = title
        self.rootLayout = .leaf(panelId: initialPanel.panelId)
        self.panelRegistry = [initialPanel.panelId: initialPanel]
        self.content = .terminal
    }

    /// 创建插件 Page
    ///
    /// - Parameters:
    ///   - title: 页面标题
    ///   - pluginId: 插件 ID
    ///   - viewProvider: 视图提供者
    private init(title: String, pluginId: String, viewProvider: @escaping () -> AnyView) {
        self.pageId = UUID()
        self.title = title
        // 插件 Page 不需要 Panel，使用空布局
        let dummyId = UUID()
        self.rootLayout = .leaf(panelId: dummyId)
        self.panelRegistry = [:]
        self.content = .plugin(id: pluginId, viewProvider: viewProvider)
    }

    /// 创建插件 Page 的工厂方法
    static func createPluginPage(title: String, pluginId: String, viewProvider: @escaping () -> AnyView) -> Page {
        return Page(title: title, pluginId: pluginId, viewProvider: viewProvider)
    }

    /// 创建空 Page（用于恢复 Session）
    ///
    /// - Parameter title: 页面标题
    private init(title: String) {
        self.pageId = UUID()
        self.title = title
        // 临时使用空布局，会在恢复过程中填充
        let dummyId = UUID()
        self.rootLayout = .leaf(panelId: dummyId)
        self.panelRegistry = [:]
        self.content = .terminal
    }

    /// 创建用于恢复的空 Page
    static func createEmptyForRestore(title: String) -> Page {
        return Page(title: title)
    }

    // MARK: - Content Type Queries

    /// 是否为插件页面
    var isPluginPage: Bool {
        if case .plugin = content {
            return true
        }
        return false
    }

    // MARK: - Title Management

    /// 重命名页面
    func rename(to newTitle: String) {
        self.title = newTitle
    }

    // MARK: - Panel Management

    /// 分割指定的 Panel
    ///
    /// - Parameters:
    ///   - panelId: 要分割的 Panel ID
    ///   - newPanel: 新创建的 Panel（由外部创建以便分配全局 Tab 编号）
    ///   - direction: 分割方向
    ///   - layoutCalculator: 布局计算器
    /// - Returns: 是否成功
    func splitPanel(
        panelId: UUID,
        newPanel: EditorPanel,
        direction: SplitDirection,
        layoutCalculator: LayoutCalculator
    ) -> Bool {
        print("🔶 [Page] splitPanel 被调用:")
        print("  - 目标 panelId: \(panelId.uuidString.prefix(4))")
        print("  - 新 panelId: \(newPanel.panelId.uuidString.prefix(4))")
        print("  - 当前 panelRegistry: \(panelRegistry.keys.map { $0.uuidString.prefix(4) })")

        // 检查 Panel 是否存在
        guard panelRegistry[panelId] != nil else {
            print("🔶 [Page] splitPanel 失败: Panel 不存在")
            return false
        }

        // 计算新布局
        rootLayout = layoutCalculator.calculateSplitLayout(
            currentLayout: rootLayout,
            targetPanelId: panelId,
            newPanelId: newPanel.panelId,
            direction: direction
        )

        // 注册新 Panel
        panelRegistry[newPanel.panelId] = newPanel
        print("🔶 [Page] splitPanel 完成, 新 panelRegistry: \(panelRegistry.keys.map { $0.uuidString.prefix(4) })")

        return true
    }

    /// 分割 Panel（使用 EdgeDirection 决定新 Panel 位置）
    ///
    /// 与接受 SplitDirection 的版本不同，此方法使用 EdgeDirection 精确控制新 Panel 的位置。
    /// 适用于拖拽场景，可以区分上/下/左/右边缘。
    ///
    /// - Parameters:
    ///   - panelId: 要分割的 Panel ID
    ///   - newPanel: 新创建的 Panel
    ///   - edge: 边缘方向（决定新 Panel 在目标 Panel 的哪个边缘）
    ///   - layoutCalculator: 布局计算器
    /// - Returns: 是否成功
    func splitPanel(
        panelId: UUID,
        newPanel: EditorPanel,
        edge: EdgeDirection,
        layoutCalculator: LayoutCalculator
    ) -> Bool {
        print("🔶 [Page] splitPanel (edge) 被调用:")
        print("  - 目标 panelId: \(panelId.uuidString.prefix(4))")
        print("  - 新 panelId: \(newPanel.panelId.uuidString.prefix(4))")
        print("  - 边缘: \(edge)")

        // 检查 Panel 是否存在
        guard panelRegistry[panelId] != nil else {
            print("🔶 [Page] splitPanel (edge) 失败: Panel 不存在")
            return false
        }

        // 计算新布局（使用 EdgeDirection 版本）
        rootLayout = layoutCalculator.calculateSplitLayout(
            currentLayout: rootLayout,
            targetPanelId: panelId,
            newPanelId: newPanel.panelId,
            edge: edge
        )

        // 注册新 Panel
        panelRegistry[newPanel.panelId] = newPanel
        print("🔶 [Page] splitPanel (edge) 完成, 新 panelRegistry: \(panelRegistry.keys.map { $0.uuidString.prefix(4) })")

        return true
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

    /// 获取所有 Panel ID（按布局树顺序）
    var allPanelIds: [UUID] {
        return rootLayout.allPanelIds()
    }

    /// 检查布局是否包含指定 Panel
    func containsPanel(_ panelId: UUID) -> Bool {
        return rootLayout.contains(panelId)
    }

    /// 添加已有的 Panel（用于恢复 Session）
    ///
    /// - Parameter panel: 已创建的 Panel
    func addExistingPanel(_ panel: EditorPanel) {
        panelRegistry[panel.panelId] = panel
    }

    /// 设置根布局（用于恢复 Session）
    ///
    /// - Parameter layout: 完整的布局树
    func setRootLayout(_ layout: PanelLayout) {
        rootLayout = layout
    }

    /// 设置分割布局（用于恢复 Session）
    ///
    /// - Parameters:
    ///   - firstLayout: 第一个子布局
    ///   - secondLayout: 第二个子布局
    ///   - direction: 分割方向
    ///   - ratio: 分割比例
    func setSplitLayout(firstLayout: PanelLayout, secondLayout: PanelLayout, direction: SplitDirection, ratio: CGFloat) {
        rootLayout = .split(direction: direction, first: firstLayout, second: secondLayout, ratio: ratio)
    }

    /// 移除指定 Panel
    ///
    /// 当 Panel 中的最后一个 Tab 被移走时调用
    /// - Returns: 是否成功移除
    func removePanel(_ panelId: UUID) -> Bool {
        print("🔶 [Page] removePanel 被调用:")
        print("  - 要移除的 panelId: \(panelId.uuidString.prefix(4))")
        print("  - 当前 panelRegistry: \(panelRegistry.keys.map { $0.uuidString.prefix(4) })")

        // 1. 检查 Panel 是否存在
        guard panelRegistry[panelId] != nil else {
            print("🔶 [Page] removePanel 失败: Panel 不存在")
            return false
        }

        // 2. 根节点不能移除（至少保留一个 Panel）
        if case .leaf(let id) = rootLayout, id == panelId {
            print("🔶 [Page] removePanel 失败: 不能移除根节点")
            return false
        }

        // 3. 从布局树中移除
        guard let newLayout = removePanelFromLayout(layout: rootLayout, panelId: panelId) else {
            print("🔶 [Page] removePanel 失败: 无法从布局树移除")
            return false
        }

        // 4. 更新状态
        rootLayout = newLayout
        panelRegistry.removeValue(forKey: panelId)
        print("🔶 [Page] removePanel 完成, 新 panelRegistry: \(panelRegistry.keys.map { $0.uuidString.prefix(4) })")

        return true
    }

    /// 在布局树中移动 Panel（复用 Panel，不创建新的）
    ///
    /// 用于边缘分栏场景：当源 Panel 只有 1 个 Tab 时，不创建新 Panel，
    /// 而是将源 Panel 从原位置移动到目标位置。
    ///
    /// - Parameters:
    ///   - panelId: 要移动的 Panel ID
    ///   - targetPanelId: 目标 Panel ID（在此 Panel 旁边插入）
    ///   - direction: 分割方向
    ///   - layoutCalculator: 布局计算器
    /// - Returns: 是否成功
    func movePanelInLayout(
        panelId: UUID,
        targetPanelId: UUID,
        edge: EdgeDirection,
        layoutCalculator: LayoutCalculator
    ) -> Bool {
        print("🔶 [Page] movePanelInLayout 被调用:")
        print("  - 要移动的 panelId: \(panelId.uuidString.prefix(4))")
        print("  - 目标 targetPanelId: \(targetPanelId.uuidString.prefix(4))")
        print("  - 边缘: \(edge)")

        // 1. 验证两个 Panel 都存在
        guard panelRegistry[panelId] != nil else {
            print("🔶 [Page] movePanelInLayout 失败: 源 Panel 不存在")
            return false
        }
        guard panelRegistry[targetPanelId] != nil else {
            print("🔶 [Page] movePanelInLayout 失败: 目标 Panel 不存在")
            return false
        }

        // 2. 不能移动到自己
        guard panelId != targetPanelId else {
            print("🔶 [Page] movePanelInLayout 失败: 不能移动到自己")
            return false
        }

        // 3. 从布局树中移除 panelId（保留 Panel 对象在 registry 中）
        guard let layoutWithoutPanel = removePanelFromLayout(layout: rootLayout, panelId: panelId) else {
            print("🔶 [Page] movePanelInLayout 失败: 无法从布局树移除源 Panel")
            return false
        }

        // 4. 在目标位置分割并插入已有的 Panel
        let newLayout = layoutCalculator.calculateSplitLayoutWithExistingPanel(
            currentLayout: layoutWithoutPanel,
            targetPanelId: targetPanelId,
            existingPanelId: panelId,
            edge: edge
        )

        // 5. 更新布局树
        rootLayout = newLayout
        print("🔶 [Page] movePanelInLayout 完成")
        print("  - 新布局: \(rootLayout.allPanelIds().map { $0.uuidString.prefix(4) })")

        return true
    }

    // MARK: - Layout Management

    /// 更新分隔线比例
    ///
    /// - Parameters:
    ///   - path: 布局路径
    ///   - newRatio: 新的比例
    func updateDividerRatio(path: [Int], newRatio: CGFloat) {
        rootLayout = updateRatioInLayout(layout: rootLayout, path: path, newRatio: newRatio)
    }

    // MARK: - Rendering

    /// 获取所有需要渲染的 Tab
    ///
    /// - Parameters:
    ///   - containerBounds: 容器的尺寸
    ///   - headerHeight: Tab Bar 的高度
    /// - Returns: 数组 [(terminalId, contentBounds)]
    func getActiveTabsForRendering(
        containerBounds: CGRect,
        headerHeight: CGFloat
    ) -> [(UInt32, CGRect)] {
        // 先更新所有 Panel 的 bounds
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
    private func updatePanelBounds(containerBounds: CGRect) {
        calculatePanelBounds(layout: rootLayout, availableBounds: containerBounds)
    }

    /// 递归计算 Panel 的 bounds
    private func calculatePanelBounds(layout: PanelLayout, availableBounds: CGRect) {
        switch layout {
        case .leaf(let panelId):
            if let panel = panelRegistry[panelId] {
                panel.updateBounds(availableBounds)
            }

        case .split(let direction, let first, let second, let ratio):
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

    // MARK: - Private Helpers

    /// 从布局树中移除 Panel
    private func removePanelFromLayout(layout: PanelLayout, panelId: UUID) -> PanelLayout? {
        switch layout {
        case .leaf(let id):
            return id == panelId ? nil : layout

        case .split(let direction, let first, let second, let ratio):
            let newFirst = removePanelFromLayout(layout: first, panelId: panelId)
            let newSecond = removePanelFromLayout(layout: second, panelId: panelId)

            if let f = newFirst, let s = newSecond {
                return .split(direction: direction, first: f, second: s, ratio: ratio)
            } else if let f = newFirst {
                return f
            } else if let s = newSecond {
                return s
            } else {
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
                return layout
            }
        }

        guard let nextIndex = path.first else {
            return layout
        }

        let remainingPath = Array(path.dropFirst())

        switch layout {
        case .split(let direction, let first, let second, let ratio):
            if nextIndex == 0 {
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
            return layout
        }
    }
}

// MARK: - Equatable

extension Page: Equatable {
    static func == (lhs: Page, rhs: Page) -> Bool {
        lhs.pageId == rhs.pageId
    }
}

// MARK: - Hashable

extension Page: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(pageId)
    }
}

// MARK: - Identifiable (SwiftUI 支持)

extension Page: Identifiable {
    var id: UUID { pageId }
}
