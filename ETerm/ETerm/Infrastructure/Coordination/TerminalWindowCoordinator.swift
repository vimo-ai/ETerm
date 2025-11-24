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

    /// 调整字体大小
    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation)
}

/// 智能关闭结果
///
/// 用于 Cmd+W 智能关闭逻辑的返回值
enum SmartCloseResult {
    /// 关闭了一个 Tab
    case closedTab
    /// 关闭了一个 Panel
    case closedPanel
    /// 关闭了一个 Page
    case closedPage
    /// 需要退出应用（只剩最后一个）
    case shouldQuitApp
    /// 无可关闭的内容
    case nothingToClose
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

    /// 键盘系统
    private(set) var keyboardSystem: KeyboardSystem?

    // MARK: - Constants

    private let headerHeight: CGFloat = 30.0

    // MARK: - Render Debounce

    /// 防抖延迟任务
    private var pendingRenderWorkItem: DispatchWorkItem?

    /// 防抖时间窗口（16ms，约一帧）
    private let renderDebounceInterval: TimeInterval = 0.016

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
        // 使用较大的默认尺寸 (120x40) 以减少初始 Reflow 的影响
        let terminalId = terminalPool.createTerminal(cols: 120, rows: 40, shell: "/bin/zsh")
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

    // MARK: - Render Scheduling

    /// 调度渲染（带防抖）
    ///
    /// 在短时间窗口内的多次调用会被合并为一次实际渲染，
    /// 用于 UI 变更（Tab 切换、Page 切换等）触发的渲染请求。
    ///
    /// - Note: 不影响即时响应（如键盘输入、滚动），这些场景应直接调用 `renderView?.requestRender()`
    private func scheduleRender() {
        // 取消之前的延迟任务
        pendingRenderWorkItem?.cancel()
//        print("[Render] 🔄 Scheduled render (debounced)")

        // 创建新的延迟任务
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
//            print("[Render] ✅ Executing debounced render")
            self.renderView?.requestRender()
        }
        pendingRenderWorkItem = workItem

        // 延迟执行
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceInterval, execute: workItem)
    }

    // MARK: - Terminal Pool Management

    /// 获取终端池（用于字体大小调整等操作）
    func getTerminalPool() -> TerminalPoolProtocol? {
        return terminalPool
    }

    /// 调整字体大小
    ///
    /// - Parameter operation: 字体大小操作（增大、减小、重置）
    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {
        renderView?.changeFontSize(operation: operation)
    }

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

        // 初始化键盘系统
        self.keyboardSystem = KeyboardSystem(coordinator: self)
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
            scheduleRender()
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
            scheduleRender()
        }
    }

    /// 智能关闭（Cmd+W）
    ///
    /// 关闭逻辑：
    /// 1. 如果当前 Panel 有多个 Tab → 关闭当前 Tab
    /// 2. 如果当前 Page 有多个 Panel → 关闭当前 Panel
    /// 3. 如果当前 Window 有多个 Page → 关闭当前 Page
    /// 4. 如果只剩最后一个 Page 的最后一个 Panel 的最后一个 Tab → 返回 .shouldQuitApp
    ///
    /// - Returns: 关闭结果
    func handleSmartClose() -> SmartCloseResult {
        guard let panelId = activePanelId,
              let panel = terminalWindow.getPanel(panelId),
              let activeTabId = panel.activeTabId else {
            return .nothingToClose
        }

        // 1. 如果当前 Panel 有多个 Tab → 关闭当前 Tab
        if panel.tabCount > 1 {
            handleTabClose(panelId: panelId, tabId: activeTabId)
            return .closedTab
        }

        // 2. 如果当前 Page 有多个 Panel → 关闭当前 Panel
        if terminalWindow.panelCount > 1 {
            // 关闭 Panel 中的所有终端
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                }
            }

            // 移除 Panel
            if terminalWindow.removePanel(panelId) {
                // 切换到另一个 Panel
                if let newActivePanelId = terminalWindow.allPanels.first?.panelId {
                    activePanelId = newActivePanelId
                }

                objectWillChange.send()
                updateTrigger = UUID()
                scheduleRender()
                return .closedPanel
            }
            return .nothingToClose
        }

        // 3. 如果当前 Window 有多个 Page → 关闭当前 Page
        if terminalWindow.pageCount > 1 {
            if closeCurrentPage() {
                return .closedPage
            }
            return .nothingToClose
        }

        // 4. 只剩最后一个了，需要确认是否退出应用
        return .shouldQuitApp
    }

    /// 关闭 Panel
    func handleClosePanel(panelId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        // 关闭 Panel 中的所有终端
        for tab in panel.tabs {
            if let terminalId = tab.rustTerminalId {
                terminalPool.closeTerminal(Int(terminalId))
            }
        }

        // 移除 Panel
        if terminalWindow.removePanel(panelId) {
            // 切换到另一个 Panel
            if activePanelId == panelId {
                activePanelId = terminalWindow.allPanels.first?.panelId
            }

            objectWillChange.send()
            updateTrigger = UUID()
            scheduleRender()
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
        scheduleRender()
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
            scheduleRender()
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

            // 2. 先从源 Panel 移除 Tab（如果是最后一个 Tab，会移除整个 Panel）
            let sourcePanelWillBeRemoved = sourcePanel.tabCount == 1
            if !sourcePanelWillBeRemoved {
                // 源 Panel 还有其他 Tab，先移除拖拽的 Tab
                _ = sourcePanel.closeTab(tabId)
            }

            // 3. 使用已有 Tab 分割目标 Panel（不消耗编号）
            let layoutCalculator = BinaryTreeLayoutCalculator()
            guard let _ = terminalWindow.splitPanelWithExistingTab(
                panelId: targetPanelId,
                existingTab: tab,
                direction: splitDirection,
                layoutCalculator: layoutCalculator
            ) else {
                // 分割失败，恢复 Tab 到源 Panel
                if !sourcePanelWillBeRemoved {
                    sourcePanel.addTab(tab)
                }
                return false
            }

            // 4. 如果源 Panel 只剩这一个 Tab，现在移除整个源 Panel
            if sourcePanelWillBeRemoved {
                _ = terminalWindow.removePanel(sourcePanel.panelId)
            }
        }

        // 4. 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

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
        _ = terminalPool.scroll(terminalId: Int(terminalId), deltaLines: deltaLines)
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
        let (start, end) = selection.normalized()

        let success = terminalPool.setSelection(
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
        let success = terminalPool.clearSelection(terminalId: Int(terminalId))

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
        let (start, end) = selection.normalized()

        return terminalPool.getTextRange(
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
        return terminalPool.getInputRow(terminalId: Int(terminalId))
    }

    /// 获取指定终端的光标位置
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 光标位置，失败返回 nil
    func getCursorPosition(terminalId: UInt32) -> CursorPosition? {
        return terminalPool.getCursorPosition(terminalId: Int(terminalId))
    }

    // MARK: - Rendering (核心方法)

    /// 渲染所有 Panel
    ///
    /// 单向数据流：从 AR 拉取数据，调用 Rust 渲染
    func renderAllPanels(containerBounds: CGRect) {
        let totalStart = CFAbsoluteTimeGetCurrent()

        guard let mapper = coordinateMapper,
              let metrics = fontMetrics else {
            return
        }

        // 更新 coordinateMapper 的 containerBounds
        // 确保坐标转换使用最新的容器尺寸（窗口 resize 后）
        updateCoordinateMapper(scale: mapper.scale, containerBounds: containerBounds)

        // 从 AR 获取所有需要渲染的 Tab
        let getTabsStart = CFAbsoluteTimeGetCurrent()
        let tabsToRender = terminalWindow.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )
        let getTabsTime = (CFAbsoluteTimeGetCurrent() - getTabsStart) * 1000
//        print("[Render] ⏱️ Get tabs to render (\(tabsToRender.count) tabs): \(String(format: "%.2f", getTabsTime))ms")

        // 渲染每个 Tab（支持 TerminalPoolWrapper 和 EventDrivenTerminalPoolWrapper）
        // 🎯 PTY 读取现在在 CVDisplayLink 回调中统一处理
        // 不再在这里调用 readAllOutputs()，避免重复读取

        var renderTimes: [(Int, Double)] = []

        for (terminalId, contentBounds) in tabsToRender {
            let terminalStart = CFAbsoluteTimeGetCurrent()

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

            let success = terminalPool.render(
                terminalId: Int(terminalId),
                x: Float(logicalRect.origin.x),
                y: Float(logicalRect.origin.y),
                width: Float(logicalRect.width),
                height: Float(logicalRect.height),
                cols: cols,
                rows: rows
            )

            let terminalTime = (CFAbsoluteTimeGetCurrent() - terminalStart) * 1000
            renderTimes.append((Int(terminalId), terminalTime))

            if !success {
                // 渲染失败，静默处理
            }
        }

        // 打印每个终端的渲染耗时
        for (terminalId, time) in renderTimes {
//            print("[Render] ⏱️ Terminal \(terminalId) render: \(String(format: "%.2f", time))ms")
        }

        // 统一提交所有 objects
        let flushStart = CFAbsoluteTimeGetCurrent()
        terminalPool.flush()
        let flushTime = (CFAbsoluteTimeGetCurrent() - flushStart) * 1000
//        print("[Render] ⏱️ Flush: \(String(format: "%.2f", flushTime))ms")

        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
//        print("[Render] ⏱️ Total renderAllPanels: \(String(format: "%.2f", totalTime))ms")
    }

    // MARK: - Page Management

    /// 获取当前激活的 Page
    var activePage: Page? {
        return terminalWindow.activePage
    }

    /// 获取所有 Page
    var allPages: [Page] {
        return terminalWindow.pages
    }

    /// Page 数量
    var pageCount: Int {
        return terminalWindow.pageCount
    }

    /// 创建新 Page
    ///
    /// - Parameter title: 页面标题（可选）
    /// - Returns: 新创建的 Page ID
    @discardableResult
    func createPage(title: String? = nil) -> UUID? {
        let newPage = terminalWindow.createPage(title: title)

        // 为新 Page 的初始 Tab 创建终端
        for panel in newPage.allPanels {
            for tab in panel.tabs {
                if tab.rustTerminalId == nil {
                    let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                    if terminalId >= 0 {
                        tab.setRustTerminalId(UInt32(terminalId))
                    }
                }
            }
        }

        // 自动切换到新 Page
        _ = terminalWindow.switchToPage(newPage.pageId)

        // 更新激活的 Panel
        activePanelId = newPage.allPanels.first?.panelId

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return newPage.pageId
    }

    /// 切换到指定 Page
    ///
    /// - Parameter pageId: 目标 Page ID
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToPage(_ pageId: UUID) -> Bool {
        // Step 1: Domain 层切换
        guard terminalWindow.switchToPage(pageId) else {
            return false
        }

        // Step 2: 更新激活的 Panel
        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        // Step 3: 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()

        // Step 4: 请求渲染（防抖）
        scheduleRender()

        return true
    }

    /// 关闭当前 Page（供快捷键调用）
    ///
    /// - Returns: 是否成功关闭
    @discardableResult
    func closeCurrentPage() -> Bool {
        guard let activePageId = terminalWindow.activePage?.pageId else {
            return false
        }
        return closePage(activePageId)
    }

    /// 关闭指定 Page
    ///
    /// - Parameter pageId: 要关闭的 Page ID
    /// - Returns: 是否成功关闭
    @discardableResult
    func closePage(_ pageId: UUID) -> Bool {
        // 获取要关闭的 Page，关闭其中所有终端
        if let page = terminalWindow.pages.first(where: { $0.pageId == pageId }) {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        terminalPool.closeTerminal(Int(terminalId))
                    }
                }
            }
        }

        guard terminalWindow.closePage(pageId) else {
            return false
        }

        // 更新激活的 Panel
        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return true
    }

    /// 重命名 Page
    ///
    /// - Parameters:
    ///   - pageId: Page ID
    ///   - newTitle: 新标题
    /// - Returns: 是否成功
    @discardableResult
    func renamePage(_ pageId: UUID, to newTitle: String) -> Bool {
        guard terminalWindow.renamePage(pageId, to: newTitle) else {
            return false
        }

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()

        return true
    }

    /// 切换到下一个 Page
    @discardableResult
    func switchToNextPage() -> Bool {
        guard terminalWindow.switchToNextPage() else {
            return false
        }

        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return true
    }

    /// 切换到上一个 Page
    @discardableResult
    func switchToPreviousPage() -> Bool {
        guard terminalWindow.switchToPreviousPage() else {
            return false
        }

        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return true
    }
}
