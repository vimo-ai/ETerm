//
//  TerminalWindowCoordinator.swift
//  ETerm
//
//  基础设施层 - 终端窗口协调器（DDD 架构）
//
//  职责：
//  - 连接 Domain AR 和基础设施层
//  - 管理终端生命周期
//  - 协调渲染流程
//
//  架构原则：
//  - Domain AR 是唯一的状态来源
//  - UI 层不持有状态，只负责显示和捕获输入
//  - 数据流单向：AR → UI → 用户事件 → AR
//

import Foundation
import AppKit
import CoreGraphics
import Combine
import PanelLayoutKit

/// 渲染视图协议 - 统一不同的 RenderView 实现
protocol RenderViewProtocol: AnyObject {
    func requestRender()
}

/// 终端窗口协调器（DDD 架构）
class TerminalWindowCoordinator: ObservableObject {
    // MARK: - Domain Aggregates

    /// 终端窗口聚合根（唯一的状态来源）
    @Published private(set) var terminalWindow: TerminalWindow

    /// 更新触发器 - 用于触发 SwiftUI 的 updateNSView
    @Published var updateTrigger = UUID()

    /// 当前激活的 Panel ID（用于键盘输入）
    private(set) var activePanelId: UUID?

    // MARK: - Infrastructure

    /// 终端池（基础设施）
    private var terminalPool: TerminalPoolProtocol

    /// 坐标映射器
    private(set) var coordinateMapper: CoordinateMapper?

    /// 字体度量
    private(set) var fontMetrics: SugarloafFontMetrics?

    /// 渲染视图引用
    weak var renderView: RenderViewProtocol?

    // MARK: - Constants

    private let headerHeight: CGFloat = 30.0

    // MARK: - Initialization

    init(initialWindow: TerminalWindow, terminalPool: TerminalPoolProtocol? = nil) {
        self.terminalWindow = initialWindow
        self.terminalPool = terminalPool ?? MockTerminalPool()

        // 2. 为初始的所有 Tab 创建终端
        createTerminalsForAllTabs()

        // 3. 设置初始激活的 Panel 为第一个 Panel
        activePanelId = initialWindow.allPanels.first?.panelId
    }
    
    // ... (中间代码保持不变) ...

    /// 创建新的 Tab 并分配终端
    func createNewTab(in panelId: UUID) -> TerminalTab? {
        let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
        guard terminalId >= 0 else {
            return nil
        }

        guard let panel = terminalWindow.getPanel(panelId) else {
            return nil
        }

        // 使用 Domain 生成的唯一标题
        let newTab = TerminalTab(
            tabId: UUID(),
            title: terminalWindow.generateNextTabTitle(),
            rustTerminalId: UInt32(terminalId)
        )

        panel.addTab(newTab)

        return newTab
    }
    
    // ... (中间代码保持不变) ...



    deinit {
        // 关闭所有终端
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                }
            }
        }
    }

    // MARK: - Terminal Pool Management

    /// 设置终端池（由 PanelRenderView 初始化后调用）
    func setTerminalPool(_ pool: TerminalPoolProtocol) {
        // 关闭旧终端池的所有终端，并清空 rustTerminalId
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                    tab.setRustTerminalId(nil)  // 清空 ID，准备重新分配
                }
            }
        }

        // 切换到新终端池
        self.terminalPool = pool

        // 重新创建所有终端
        createTerminalsForAllTabs()
    }

    /// 设置坐标映射器（初始化时使用）
    func setCoordinateMapper(_ mapper: CoordinateMapper) {
        self.coordinateMapper = mapper
    }

    /// 更新坐标映射器（容器尺寸变化时使用）
    func updateCoordinateMapper(scale: CGFloat, containerBounds: CGRect) {
        self.coordinateMapper = CoordinateMapper(scale: scale, containerBounds: containerBounds)
    }

    /// 更新字体度量
    func updateFontMetrics(_ metrics: SugarloafFontMetrics) {
        self.fontMetrics = metrics
    }

    // MARK: - Terminal Lifecycle

    /// 为所有 Tab 创建终端
    private func createTerminalsForAllTabs() {
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                // 如果 Tab 还没有终端，创建一个
                if tab.rustTerminalId == nil {
                    let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                    if terminalId >= 0 {
                        tab.setRustTerminalId(UInt32(terminalId))
                    }
                }
            }
        }
    }



    // MARK: - User Interactions (从 UI 层调用)

    /// 用户点击 Tab
    func handleTabClick(panelId: UUID, tabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        // 检查是否已经是激活的 Tab
        if panel.activeTabId == tabId {
            return
        }

        // 调用 AR 的方法切换 Tab
        if panel.setActiveTab(tabId) {
            // 触发渲染更新
            objectWillChange.send()
            updateTrigger = UUID()
            renderView?.requestRender()
        }
    }

    /// 设置激活的 Panel（用于键盘输入）
    func setActivePanel(_ panelId: UUID) {
        guard terminalWindow.getPanel(panelId) != nil else {
            return
        }

        if activePanelId != panelId {
            activePanelId = panelId
        }
    }

    /// 用户关闭 Tab
    func handleTabClose(panelId: UUID, tabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        // 获取 Tab 的终端 ID，关闭终端
        if let tab = panel.tabs.first(where: { $0.tabId == tabId }),
           let terminalId = tab.rustTerminalId {
            terminalPool.closeTerminal(Int(terminalId))
        }

        // 调用 AR 的方法关闭 Tab
        if panel.closeTab(tabId) {
            objectWillChange.send()
            updateTrigger = UUID()
            renderView?.requestRender()
        }
    }

    /// 用户添加 Tab
    func handleAddTab(panelId: UUID) {
        guard let newTab = createNewTab(in: panelId) else {
            return
        }

        // 切换到新 Tab
        if let panel = terminalWindow.getPanel(panelId) {
            _ = panel.setActiveTab(newTab.tabId)
        }

        // 设置为激活的 Panel
        setActivePanel(panelId)

        objectWillChange.send()
        updateTrigger = UUID()
        renderView?.requestRender()
    }

    /// 用户分割 Panel
    func handleSplitPanel(panelId: UUID, direction: SplitDirection) {
        // 使用 BinaryTreeLayoutCalculator 计算新布局
        let layoutCalculator = BinaryTreeLayoutCalculator()

        if let newPanelId = terminalWindow.splitPanel(
            panelId: panelId,
            direction: direction,
            layoutCalculator: layoutCalculator
        ) {
            // 为新 Panel 的默认 Tab 创建终端
            if let newPanel = terminalWindow.getPanel(newPanelId) {
                for tab in newPanel.tabs {
                    if tab.rustTerminalId == nil {
                        let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                        if terminalId >= 0 {
                            tab.setRustTerminalId(UInt32(terminalId))
                        }
                    }
                }
            }

            // 设置新 Panel 为激活状态
            setActivePanel(newPanelId)

            objectWillChange.send()
            updateTrigger = UUID()
            renderView?.requestRender()
        }
    }

    // MARK: - Drag & Drop

    /// 处理 Tab 拖拽 Drop
    ///
    /// - Parameters:
    ///   - tabId: 被拖拽的 Tab ID
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 是否成功处理
    func handleDrop(tabId: UUID, dropZone: DropZone, targetPanelId: UUID) -> Bool {
        // 1. 找到源 Panel 和 Tab
        guard let sourcePanel = terminalWindow.allPanels.first(where: { panel in
            panel.tabs.contains(where: { $0.tabId == tabId })
        }),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return false
        }

        // 2. 找到目标 Panel
        guard let targetPanel = terminalWindow.getPanel(targetPanelId) else {
            return false
        }

        // 3. 根据 DropZone 类型处理
        switch dropZone.type {
        case .header:
            // Tab 合并：移动到目标 Panel
            if sourcePanel.panelId == targetPanel.panelId {
                // 同一个 Panel 内部移动（重新排序）暂未实现
                return false
            } else {
                // 跨 Panel 移动
                moveTabAcrossPanels(tab: tab, from: sourcePanel, to: targetPanel)
            }

        case .body:
            // 合并到中心（同 .header）
            if sourcePanel.panelId != targetPanel.panelId {
                moveTabAcrossPanels(tab: tab, from: sourcePanel, to: targetPanel)
            }

        case .left, .right, .top, .bottom:
            // 拖拽到边缘 → 分割 Panel

            // 1. 确定分割方向
            let splitDirection: SplitDirection = {
                switch dropZone.type {
                case .left, .right:
                    return .horizontal  // 左右分割
                case .top, .bottom:
                    return .vertical    // 上下分割
                default:
                    fatalError("不应该到达这里")
                }
            }()

            // 2. 分割目标 Panel
            let layoutCalculator = BinaryTreeLayoutCalculator()
            guard let newPanelId = terminalWindow.splitPanel(
                panelId: targetPanelId,
                direction: splitDirection,
                layoutCalculator: layoutCalculator
            ) else {
                return false
            }

            // 3. 获取新 Panel
            guard let newPanel = terminalWindow.getPanel(newPanelId) else {
                return false
            }

            // 4. 将拖拽的 Tab 移动到新 Panel
            // 4.1 添加到新 Panel
            newPanel.addTab(tab)
            _ = newPanel.setActiveTab(tabId)

            // 4.2 删除新 Panel 的默认 Tab
            if let defaultTab = newPanel.tabs.first(where: { $0.tabId != tabId }) {
                if let terminalId = defaultTab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                }
                _ = newPanel.closeTab(defaultTab.tabId)
            }

            // 4.3 从源 Panel 移除拖拽的 Tab（处理最后一个 Tab 的情况）
            removeTabFromSource(tab: tab, sourcePanel: sourcePanel)
        }

        // 4. 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        renderView?.requestRender()

        return true
    }

    // MARK: - Private Helpers for Drag & Drop

    /// 跨 Panel 移动 Tab
    private func moveTabAcrossPanels(tab: TerminalTab, from sourcePanel: EditorPanel, to targetPanel: EditorPanel) {
        // 1. 添加到目标 Panel
        targetPanel.addTab(tab)
        _ = targetPanel.setActiveTab(tab.tabId)

        // 2. 从源 Panel 移除
        removeTabFromSource(tab: tab, sourcePanel: sourcePanel)
    }

    /// 从源 Panel 移除 Tab（如果只剩一个 Tab，则移除整个 Panel）
    private func removeTabFromSource(tab: TerminalTab, sourcePanel: EditorPanel) {
        if sourcePanel.tabCount > 1 {
            // 还有其他 Tab，直接关闭
            _ = sourcePanel.closeTab(tab.tabId)
        } else {
            // 最后一个 Tab，移除整个 Panel
            _ = terminalWindow.removePanel(sourcePanel.panelId)
        }
    }

    // MARK: - Input Handling

    /// 获取当前激活的终端 ID
    func getActiveTerminalId() -> UInt32? {
        // 使用激活的 Panel
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab else {
            // 如果没有激活的 Panel，fallback 到第一个
            return terminalWindow.allPanels.first?.activeTab?.rustTerminalId
        }

        return activeTab.rustTerminalId
    }

    /// 写入输入到指定终端
    func writeInput(terminalId: UInt32, data: String) {
        terminalPool.writeInput(terminalId: Int(terminalId), data: data)
    }

    // MARK: - Mouse Event Helpers

    /// 根据鼠标位置找到对应的 Panel
    func findPanel(at point: CGPoint, containerBounds: CGRect) -> UUID? {
        // 先更新 Panel bounds
        let _ = terminalWindow.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )

        // 遍历所有 Panel，找到包含该点的 Panel
        for panel in terminalWindow.allPanels {
            if panel.bounds.contains(point) {
                return panel.panelId
            }
        }

        return nil
    }

    /// 处理滚动
    func handleScroll(terminalId: UInt32, deltaLines: Int32) {
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        _ = terminalPoolWrapper.scroll(terminalId: Int(terminalId), deltaLines: deltaLines)
        renderView?.requestRender()
    }

    // MARK: - 文本选中 API (Text Selection)

    /// 设置指定终端的选中范围（用于高亮渲染）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - selection: 选中范围
    /// - Returns: 是否成功
    func setSelection(terminalId: UInt32, selection: TextSelection) -> Bool {
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            return false
        }

        let (start, end) = selection.normalized()

        let success = terminalPoolWrapper.setSelection(
            terminalId: Int(terminalId),
            startRow: start.row,
            startCol: start.col,
            endRow: end.row,
            endCol: end.col
        )

        if success {
            // 触发渲染更新
            renderView?.requestRender()
        }

        return success
    }

    /// 清除指定终端的选中高亮
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    func clearSelection(terminalId: UInt32) -> Bool {
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            return false
        }

        let success = terminalPoolWrapper.clearSelection(terminalId: Int(terminalId))

        if success {
            renderView?.requestRender()
        }

        return success
    }

    /// 获取指定终端的选中文本
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - selection: 选中范围
    /// - Returns: 选中的文本，失败返回 nil
    func getSelectedText(terminalId: UInt32, selection: TextSelection) -> String? {
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            return nil
        }

        let (start, end) = selection.normalized()

        return terminalPoolWrapper.getTextRange(
            terminalId: Int(terminalId),
            startRow: start.row,
            startCol: start.col,
            endRow: end.row,
            endCol: end.col
        )
    }

    /// 获取指定终端的当前输入行号
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 输入行号，如果不在输入模式返回 nil
    func getInputRow(terminalId: UInt32) -> UInt16? {
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            return nil
        }

        return terminalPoolWrapper.getInputRow(terminalId: Int(terminalId))
    }

    // MARK: - Rendering (核心方法)

    /// 渲染所有 Panel
    ///
    /// 单向数据流：从 AR 拉取数据，调用 Rust 渲染
    func renderAllPanels(containerBounds: CGRect) {
        guard let mapper = coordinateMapper,
              let metrics = fontMetrics else {
            return
        }

        // 更新 coordinateMapper 的 containerBounds
        // 确保坐标转换使用最新的容器尺寸（窗口 resize 后）
        updateCoordinateMapper(scale: mapper.scale, containerBounds: containerBounds)

        // 从 AR 获取所有需要渲染的 Tab
        let tabsToRender = terminalWindow.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )

        // 渲染每个 Tab
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            // MockTerminalPool，跳过渲染
            return
        }

        for (terminalId, contentBounds) in tabsToRender {
            // 1. 坐标转换：Swift 坐标 → Rust 逻辑坐标
            // 注意：这里只传递逻辑坐标 (Points)，Sugarloaf 内部会自动乘上 scale。
            // 如果这里传物理像素，会导致双重缩放 (Double Scaling) 问题。
            let logicalRect = mapper.swiftToRust(rect: contentBounds)

            // 2. 网格计算
            // 注意：Sugarloaf 返回的 fontMetrics 是物理像素 (Physical Pixels)
            // cell_width: 字符宽度 (物理)
            // cell_height: 字符高度 (物理)
            // line_height: 行高 (物理，通常 > cell_height)

            let cellWidth = CGFloat(metrics.cell_width)
            let lineHeight = CGFloat(metrics.line_height > 0 ? metrics.line_height : metrics.cell_height)

            // 计算列数：使用物理宽度 / 物理字符宽度
            // 因为 cellWidth 是物理像素，所以必须用 physicalRect.width (或者 logicalRect.width * scale)
            // 这里我们用 logicalRect * scale 来确保一致性
            let physicalWidth = logicalRect.width * mapper.scale
            let cols = UInt16(physicalWidth / cellWidth)

            // 计算行数：使用物理高度 / 物理行高
            let physicalHeight = logicalRect.height * mapper.scale
            let rows = UInt16(physicalHeight / lineHeight)

            let success = terminalPoolWrapper.render(
                terminalId: Int(terminalId),
                x: Float(logicalRect.origin.x),
                y: Float(logicalRect.origin.y),
                width: Float(logicalRect.width),
                height: Float(logicalRect.height),
                cols: cols,
                rows: rows
            )

            if !success {
                // 渲染失败，静默处理
            }
        }

        // 统一提交所有 objects
        terminalPoolWrapper.flush()
    }
}
