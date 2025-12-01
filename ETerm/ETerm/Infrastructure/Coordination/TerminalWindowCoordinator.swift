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

    /// 设置指定 Page 的提醒状态
    func setPageNeedsAttention(_ pageId: UUID, attention: Bool)
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
    /// 需要关闭当前窗口（只剩最后一个 Tab/Panel/Page）
    case shouldCloseWindow
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

    // MARK: - Inline AI Composer State

    /// 是否显示 AI 辅助输入框
    @Published var showInlineComposer: Bool = false

    /// AI 辅助输入框的位置（屏幕坐标）
    @Published var composerPosition: CGPoint = .zero

    /// AI 辅助输入框的输入区高度（不含结果区）
    @Published var composerInputHeight: CGFloat = 0

    // MARK: - Terminal Search State

    /// 是否显示终端搜索框
    @Published var showTerminalSearch: Bool = false

    /// 搜索文本
    @Published var searchText: String = ""

    /// 搜索匹配项
    @Published var searchMatches: [SearchMatch] = []

    /// 搜索引擎
    private let searchEngine = TerminalSearch()

    // MARK: - Infrastructure

    /// 全局终端管理器（基础设施）
    private var globalTerminalManager: GlobalTerminalManager?

    /// 终端池（兼容旧代码，用于渲染）
    private var terminalPool: TerminalPoolProtocol

    /// 坐标映射器
    private(set) var coordinateMapper: CoordinateMapper?

    /// 字体度量
    private(set) var fontMetrics: SugarloafFontMetrics?

    /// 渲染视图引用
    weak var renderView: RenderViewProtocol?

    /// 键盘系统
    private(set) var keyboardSystem: KeyboardSystem?

    /// 需要高亮的 Tab 集合（即使 Tab 所在的 Page 不可见，也要记住）
    private var tabsNeedingAttention: Set<UUID> = []

    // MARK: - Constants

    private let headerHeight: CGFloat = 30.0

    // MARK: - CWD Inheritance

    /// 初始工作目录（继承自父窗口，可选）
    private var initialCwd: String?

    // MARK: - Render Debounce

    /// 防抖延迟任务
    private var pendingRenderWorkItem: DispatchWorkItem?

    /// 防抖时间窗口（16ms，约一帧）
    private let renderDebounceInterval: TimeInterval = 0.016

    // MARK: - Initialization

    init(initialWindow: TerminalWindow, terminalPool: TerminalPoolProtocol? = nil) {
        // 获取继承的 CWD（如果有）
        self.initialCwd = WindowCwdManager.shared.takePendingCwd()
        print("🎯 [Coordinator] Initialized with CWD: \(self.initialCwd ?? "nil")")

        self.terminalWindow = initialWindow
        self.terminalPool = terminalPool ?? MockTerminalPool()

        // 不在这里创建终端，等 setTerminalPool 时再创建
        // （因为初始化时可能还在用 MockTerminalPool）

        // 设置初始激活的 Panel 为第一个 Panel
        activePanelId = initialWindow.allPanels.first?.panelId

        // 监听 Claude 响应完成通知
        setupClaudeNotifications()
    }

    /// 设置 Claude 通知监听
    private func setupClaudeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClaudeResponseComplete(_:)),
            name: .claudeResponseComplete,
            object: nil
        )
    }

    @objc private func handleClaudeResponseComplete(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        // 找到包含该终端的 Page 和 Tab
        for page in terminalWindow.pages {
            for panel in page.allPanels {
                if let tab = panel.tabs.first(where: { $0.rustTerminalId == UInt32(terminalId) }) {
                    // 检查 Tab 是否激活且 Page 也激活
                    let isTabActive = (panel.activeTabId == tab.tabId)
                    let isPageActive = (page.pageId == terminalWindow.activePageId)

                    // 如果 Tab 激活且 Page 也激活，不需要提醒
                    if isTabActive && isPageActive {
                        return
                    }

                    // 否则，记录这个 Tab 需要高亮
                    tabsNeedingAttention.insert(tab.tabId)

                    // 如果 Page 不是当前激活的，则高亮它
                    if !isPageActive {
                        DispatchQueue.main.async { [weak self] in
                            self?.renderView?.setPageNeedsAttention(page.pageId, attention: true)
                        }
                    }

                    return
                }
            }
        }
    }
    
    // ... (中间代码保持不变) ...

    /// 创建新的 Tab 并分配终端
    func createNewTab(in panelId: UUID) -> TerminalTab? {
        // 使用较大的默认尺寸 (120x40) 以减少初始 Reflow 的影响
        let terminalId = createTerminalInternal(cols: 120, rows: 40, shell: "/bin/zsh")
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



    /// 显式清理所有终端（在窗口关闭时调用）
    ///
    /// 这个方法应该在 windowWillClose 中调用，而不是依赖 deinit。
    /// 因为在 deinit 中访问对象可能导致野指针问题。
    func cleanup() {
        // 移除通知监听
        NotificationCenter.default.removeObserver(self)

        // 取消所有待处理的渲染任务
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil

        // 清除渲染视图引用
        renderView = nil

        // 收集所有终端 ID
        var terminalIds: [Int] = []
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalIds.append(Int(terminalId))
                    tab.setRustTerminalId(nil)  // 清除引用，防止重复关闭
                }
            }
        }

        // 关闭终端
        for terminalId in terminalIds {
            if let manager = globalTerminalManager {
                _ = manager.closeTerminal(terminalId)
            } else {
                _ = terminalPool.closeTerminal(terminalId)
            }
        }

        // 清理全局终端管理器中的路由
        globalTerminalManager?.cleanupRoutes(for: self)

        // 清除全局终端管理器的引用
        globalTerminalManager = nil
    }

    deinit {
        // 注意：不在 deinit 中访问 terminalWindow.allPanels
        // 清理工作应该在 cleanup() 中完成
        // 这里只做最小清理，防止任何野指针访问
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil
    }

    // MARK: - Render Scheduling

    /// 调度渲染（带防抖）
    ///
    /// 在短时间窗口内的多次调用会被合并为一次实际渲染，
    /// 用于 UI 变更（Tab 切换、Page 切换等）触发的渲染请求。
    ///
    /// - Note: 不影响即时响应（如键盘输入、滚动），这些场景应直接调用 `renderView?.requestRender()`
    func scheduleRender() {
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

    // MARK: - Event Handlers (from GlobalTerminalManager)

    /// 处理终端关闭事件
    func handleTerminalClosed(terminalId: Int) {
        // 找到对应的 Tab 并关闭
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == UInt32(terminalId) }) {
                handleTabClose(panelId: panel.panelId, tabId: tab.tabId)
                return
            }
        }
    }

    /// 处理 Bell 事件
    func handleBell(terminalId: Int) {
        // 播放系统提示音
        NSSound.beep()
    }

    /// 处理标题变更事件
    func handleTitleChange(terminalId: Int, title: String) {
        // 找到对应的 Tab 并更新标题
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == UInt32(terminalId) }) {
                tab.setTitle(title)
                objectWillChange.send()
                updateTrigger = UUID()
                return
            }
        }
    }

    // MARK: - Terminal Pool Management

    /// 获取终端池（用于字体大小调整等操作）
    func getTerminalPool() -> TerminalPoolProtocol? {
        return terminalPool
    }

    /// 获取终端的当前工作目录（CWD）
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: CWD 路径，失败返回 nil
    func getCwd(terminalId: Int) -> String? {
        // 优先使用 GlobalTerminalManager
        if let manager = globalTerminalManager {
            return manager.getCwd(terminalId: terminalId)
        }

        // 否则尝试使用本地 RioTerminalPoolWrapper
        if let wrapper = terminalPool as? RioTerminalPoolWrapper {
            return wrapper.getCwd(terminalId: terminalId)
        }

        return nil
    }

    /// 调整字体大小
    ///
    /// - Parameter operation: 字体大小操作（增大、减小、重置）
    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {
        renderView?.changeFontSize(operation: operation)
    }

    /// 设置终端池（由 PanelRenderView 初始化后调用）
    func setTerminalPool(_ pool: TerminalPoolProtocol) {
        // print("🔵 [Coordinator] setTerminalPool called")
        // 关闭旧终端池的所有终端，并清空 rustTerminalId
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    closeTerminalInternal(Int(terminalId))
                    tab.setRustTerminalId(nil)  // 清空 ID，准备重新分配
                }
            }
        }

        // 切换到新终端池
        self.terminalPool = pool
        // print("🔵 [Coordinator] terminalPool switched")

        // 重新创建所有终端
        createTerminalsForAllTabs()

        // 初始化键盘系统
        self.keyboardSystem = KeyboardSystem(coordinator: self)
        // print("🟢 [Coordinator] setTerminalPool completed, keyboardSystem initialized")
    }

    /// 设置全局终端管理器（新的架构）
    ///
    /// 使用全局终端管理器代替本地终端池，支持跨窗口终端迁移
    func setGlobalTerminalManager(_ manager: GlobalTerminalManager) {
        self.globalTerminalManager = manager

        // 清空旧终端的 rustTerminalId
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                tab.setRustTerminalId(nil)
            }
        }

        // 为所有 Tab 创建终端（使用全局管理器）
        createTerminalsWithGlobalManager()

        // 初始化键盘系统
        self.keyboardSystem = KeyboardSystem(coordinator: self)
    }

    /// 使用全局终端管理器为所有 Tab 创建终端
    private func createTerminalsWithGlobalManager() {
        guard globalTerminalManager != nil else { return }

        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if tab.rustTerminalId == nil {
                    // 使用 createTerminalInternal 以支持 CWD 继承
                    let terminalId = createTerminalInternal(cols: 80, rows: 24, shell: "/bin/zsh")
                    if terminalId >= 0 {
                        tab.setRustTerminalId(UInt32(terminalId))
                    }
                }
            }
        }
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

    /// 关闭终端（统一入口）
    ///
    /// 优先使用全局终端管理器，否则使用本地终端池
    @discardableResult
    private func closeTerminalInternal(_ terminalId: Int) -> Bool {
        if let manager = globalTerminalManager {
            return manager.closeTerminal(terminalId)
        } else {
            return terminalPool.closeTerminal(terminalId)
        }
    }

    /// 创建终端（统一入口）
    ///
    /// 优先使用全局终端管理器，否则使用本地终端池
    /// 如果有 initialCwd，则使用指定的工作目录创建第一个终端
    private func createTerminalInternal(cols: UInt16, rows: UInt16, shell: String, cwd: String? = nil) -> Int {
        // 优先使用传入的 CWD
        var effectiveCwd = cwd

        // 如果没有传入 CWD，检查是否有 initialCwd（用于新窗口继承）
        if effectiveCwd == nil {
            effectiveCwd = initialCwd
        }

        // 如果有 CWD，使用 createTerminalWithCwd
        if let cwdPath = effectiveCwd {
            print("🚀 [Coordinator] Creating terminal with CWD: \(cwdPath)")

            var terminalId: Int = -1

            // 优先使用全局终端管理器
            if let manager = globalTerminalManager {
                terminalId = manager.createTerminalWithCwd(cols: cols, rows: rows, shell: shell, cwd: cwdPath, for: self)
            } else if let wrapper = terminalPool as? RioTerminalPoolWrapper {
                terminalId = wrapper.createTerminalWithCwd(cols: cols, rows: rows, shell: shell, cwd: cwdPath)
            }

            if terminalId >= 0 {
                print("✅ [Coordinator] Terminal created with ID \(terminalId)")

                // 如果使用的是 initialCwd，清除它（只有第一个终端使用）
                if cwd == nil && initialCwd != nil {
                    print("🧹 [Coordinator] Clearing initialCwd after first terminal creation")
                    initialCwd = nil
                }

                return terminalId
            }
            // 如果带 CWD 创建失败，继续走默认逻辑
            print("⚠️ [Coordinator] Failed to create terminal with CWD, falling back to default")
        }

        print("📌 [Coordinator] Creating terminal with default CWD")
        // 默认行为：不指定 CWD
        if let manager = globalTerminalManager {
            return manager.createTerminal(cols: cols, rows: rows, shell: shell, for: self)
        } else {
            return terminalPool.createTerminal(cols: cols, rows: rows, shell: shell)
        }
    }

    /// 写入输入（统一入口）
    @discardableResult
    private func writeInputInternal(terminalId: Int, data: String) -> Bool {
        if let manager = globalTerminalManager {
            return manager.writeInput(terminalId: terminalId, data: data)
        } else {
            return terminalPool.writeInput(terminalId: terminalId, data: data)
        }
    }

    /// 滚动（统一入口）
    @discardableResult
    private func scrollInternal(terminalId: Int, deltaLines: Int32) -> Bool {
        if let manager = globalTerminalManager {
            return manager.scroll(terminalId: terminalId, deltaLines: deltaLines)
        } else {
            return terminalPool.scroll(terminalId: terminalId, deltaLines: deltaLines)
        }
    }

    /// 设置选区（统一入口）
    @discardableResult
    private func setSelectionInternal(terminalId: Int, startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16) -> Bool {
        if let manager = globalTerminalManager {
            return manager.setSelection(terminalId: terminalId, startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol)
        } else {
            return terminalPool.setSelection(terminalId: terminalId, startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol)
        }
    }

    /// 清除选区（统一入口）
    @discardableResult
    private func clearSelectionInternal(terminalId: Int) -> Bool {
        if let manager = globalTerminalManager {
            return manager.clearSelection(terminalId: terminalId)
        } else {
            return terminalPool.clearSelection(terminalId: terminalId)
        }
    }

    /// 获取文本范围（统一入口）
    private func getTextRangeInternal(terminalId: Int, startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16) -> String? {
        if let manager = globalTerminalManager {
            return manager.getTextRange(terminalId: terminalId, startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol)
        } else {
            return terminalPool.getTextRange(terminalId: terminalId, startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol)
        }
    }

    /// 获取光标位置（统一入口）
    private func getCursorPositionInternal(terminalId: Int) -> CursorPosition? {
        if let manager = globalTerminalManager {
            if let cursor = manager.getCursor(terminalId: terminalId) {
                return CursorPosition(col: cursor.col, row: cursor.row)
            }
            return nil
        } else {
            return terminalPool.getCursorPosition(terminalId: terminalId)
        }
    }

    /// 为所有 Tab 创建终端
    private func createTerminalsForAllTabs() {
        // print("🔵 [Coordinator] createTerminalsForAllTabs called, panels: \(terminalWindow.allPanels.count)")
        for panel in terminalWindow.allPanels {
            // print("🔵 [Coordinator] Panel \(panel.panelId), tabs: \(panel.tabs.count)")
            for tab in panel.tabs {
                // 如果 Tab 还没有终端，创建一个
                if tab.rustTerminalId == nil {
                    // print("🔵 [Coordinator] Creating terminal for tab \(tab.tabId)...")
                    let terminalId = createTerminalInternal(cols: 80, rows: 24, shell: "/bin/zsh")
                    // print("🔵 [Coordinator] createTerminalInternal returned: \(terminalId)")
                    if terminalId >= 0 {
                        tab.setRustTerminalId(UInt32(terminalId))
                        // print("🟢 [Coordinator] Terminal created with ID: \(terminalId)")
                    } else {
                        // print("🔴 [Coordinator] Failed to create terminal!")
                    }
                } else {
                    // print("🔵 [Coordinator] Tab \(tab.tabId) already has terminal \(tab.rustTerminalId!)")
                }
            }
        }
        // print("🟢 [Coordinator] createTerminalsForAllTabs completed")
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

        // 如果这是窗口中最后一个 Panel 的最后一个 Tab，则不允许关闭（保持至少一个终端）
        if panel.tabCount == 1 && terminalWindow.panelCount <= 1 {
            return
        }

        // 复用统一的 Tab 移除逻辑，确保在最后一个 Tab 关闭时可以移除 Panel
        _ = removeTab(tabId, from: panelId, closeTerminal: true)
    }

    /// 用户重命名 Tab
    func handleTabRename(panelId: UUID, tabId: UUID, newTitle: String) {
        guard let panel = terminalWindow.getPanel(panelId),
              let tab = panel.tabs.first(where: { $0.tabId == tabId }) else {
            return
        }

        tab.setTitle(newTitle)
        objectWillChange.send()
        updateTrigger = UUID()
    }

    /// 用户重新排序 Tabs
    func handleTabReorder(panelId: UUID, tabIds: [UUID]) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        if panel.reorderTabs(tabIds) {
            objectWillChange.send()
            updateTrigger = UUID()
        }
    }

    /// 智能关闭（Cmd+W）
    ///
    /// 关闭逻辑：
    /// 1. 如果当前 Panel 有多个 Tab → 关闭当前 Tab
    /// 2. 如果当前 Page 有多个 Panel → 关闭当前 Panel
    /// 3. 如果当前 Window 有多个 Page → 关闭当前 Page
    /// 4. 如果只剩最后一个 Page 的最后一个 Panel 的最后一个 Tab → 返回 .shouldCloseWindow
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
                    closeTerminalInternal(Int(terminalId))
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

        // 4. 只剩最后一个了，需要关闭当前窗口
        return .shouldCloseWindow
    }

    /// 关闭 Panel
    func handleClosePanel(panelId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        // 关闭 Panel 中的所有终端
        for tab in panel.tabs {
            if let terminalId = tab.rustTerminalId {
                closeTerminalInternal(Int(terminalId))
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
        // 获取当前激活终端的 CWD（用于继承）
        var inheritedCwd: String? = nil
        if let panel = terminalWindow.getPanel(panelId),
           let activeTab = panel.activeTab,
           let terminalId = activeTab.rustTerminalId {
            inheritedCwd = getCwd(terminalId: Int(terminalId))
            print("🔍 [SplitPanel] Got CWD from terminal \(terminalId): \(inheritedCwd ?? "nil")")
        }

        // 使用 BinaryTreeLayoutCalculator 计算新布局
        let layoutCalculator = BinaryTreeLayoutCalculator()

        if let newPanelId = terminalWindow.splitPanel(
            panelId: panelId,
            direction: direction,
            layoutCalculator: layoutCalculator
        ) {
            // 为新 Panel 的默认 Tab 创建终端（继承 CWD）
            if let newPanel = terminalWindow.getPanel(newPanelId) {
                for tab in newPanel.tabs {
                    if tab.rustTerminalId == nil {
                        print("📝 [SplitPanel] Creating terminal with inherited CWD: \(inheritedCwd ?? "nil")")
                        let terminalId = createTerminalInternal(cols: 80, rows: 24, shell: "/bin/zsh", cwd: inheritedCwd)
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

    /// 根据滚轮事件位置获取应滚动的终端 ID（鼠标所在 Panel 的激活 Tab）
    /// - Parameters:
    ///   - point: 鼠标位置（容器坐标，PageBar 下方区域）
    ///   - containerBounds: 容器区域（PageBar 下方区域）
    /// - Returns: 目标终端 ID，如果找不到则返回当前激活终端
    func getTerminalIdAtPoint(_ point: CGPoint, containerBounds: CGRect) -> UInt32? {
        if let panelId = findPanel(at: point, containerBounds: containerBounds),
           let panel = terminalWindow.getPanel(panelId),
           let activeTab = panel.activeTab,
           let terminalId = activeTab.rustTerminalId {
            return terminalId
        }

        return getActiveTerminalId()
    }

    /// 写入输入到指定终端
    func writeInput(terminalId: UInt32, data: String) {
        writeInputInternal(terminalId: Int(terminalId), data: data)
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
        _ = scrollInternal(terminalId: Int(terminalId), deltaLines: deltaLines)
        renderView?.requestRender()
    }

    // MARK: - 文本选中 API (Text Selection)

    /// 设置指定终端的选中范围（用于高亮渲染）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - selection: 选中范围（使用真实行号）
    /// - Returns: 是否成功
    func setSelection(terminalId: UInt32, selection: TextSelection) -> Bool {
        let (startRow, startCol, endRow, endCol) = selection.normalized()

        // 使用真实行号设置选区
        let success = globalTerminalManager?.setSelectionAbsolute(
            terminalId: Int(terminalId),
            startAbsoluteRow: startRow,
            startCol: Int(startCol),
            endAbsoluteRow: endRow,
            endCol: Int(endCol)
        ) ?? false

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
        let success = clearSelectionInternal(terminalId: Int(terminalId))

        if success {
            renderView?.requestRender()
        }

        return success
    }

    /// 获取指定终端的选中文本
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - selection: 选中范围（使用真实行号）
    /// - Returns: 选中的文本，失败返回 nil
    func getSelectedText(terminalId: UInt32, selection: TextSelection) -> String? {
        // 使用绝对坐标系统直接获取
        // 前提：selection 已经通过 setSelection 同步到 Rust 层
        return globalTerminalManager?.getSelectedTextAbsolute(terminalId: Int(terminalId))
    }

    /// 获取指定终端的当前输入行号
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 输入行号，如果不在输入模式返回 nil
    func getInputRow(terminalId: UInt32) -> UInt16? {
        // getInputRow 目前只有旧的终端池支持，GlobalTerminalManager 不需要
        return terminalPool.getInputRow(terminalId: Int(terminalId))
    }

    /// 获取指定终端的光标位置
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 光标位置，失败返回 nil
    func getCursorPosition(terminalId: UInt32) -> CursorPosition? {
        return getCursorPositionInternal(terminalId: Int(terminalId))
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
                    let terminalId = createTerminalInternal(cols: 80, rows: 24, shell: "/bin/zsh")
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

    /// 检查指定 Tab 是否需要高亮
    func isTabNeedingAttention(_ tabId: UUID) -> Bool {
        return tabsNeedingAttention.contains(tabId)
    }

    /// 清除 Tab 的高亮状态（当用户点击 Tab 时调用）
    func clearTabAttention(_ tabId: UUID) {
        tabsNeedingAttention.remove(tabId)
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
                        closeTerminalInternal(Int(terminalId))
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

    /// 重新排序 Pages
    ///
    /// - Parameter pageIds: 新的 Page ID 顺序
    /// - Returns: 是否成功
    @discardableResult
    func reorderPages(_ pageIds: [UUID]) -> Bool {
        guard terminalWindow.reorderPages(pageIds) else {
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

    // MARK: - 跨窗口操作支持

    /// 移除 Page（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - pageId: 要移除的 Page ID
    ///   - closeTerminals: 是否关闭终端（跨窗口移动时为 false）
    /// - Returns: 被移除的 Page，失败返回 nil
    func removePage(_ pageId: UUID, closeTerminals: Bool) -> Page? {
        // 获取要移除的 Page
        guard let page = terminalWindow.pages.first(where: { $0.pageId == pageId }) else {
            return nil
        }

        // 如果需要关闭终端
        if closeTerminals {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        closeTerminalInternal(Int(terminalId))
                    }
                }
            }
        }

        // 从 TerminalWindow 移除 Page
        guard terminalWindow.closePage(pageId) else {
            return nil
        }

        // 更新激活的 Panel
        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return page
    }

    /// 添加已有的 Page（用于跨窗口移动）
    ///
    /// - Parameter page: 要添加的 Page
    func addPage(_ page: Page) {
        terminalWindow.addExistingPage(page)

        // 切换到新添加的 Page
        _ = terminalWindow.switchToPage(page.pageId)

        // 更新激活的 Panel
        activePanelId = page.allPanels.first?.panelId

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    /// 移除 Tab（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - tabId: 要移除的 Tab ID
    ///   - panelId: 源 Panel ID
    ///   - closeTerminal: 是否关闭终端（跨窗口移动时为 false）
    /// - Returns: 是否成功
    @discardableResult
    func removeTab(_ tabId: UUID, from panelId: UUID, closeTerminal: Bool) -> Bool {
        guard let panel = terminalWindow.getPanel(panelId),
              let tab = panel.tabs.first(where: { $0.tabId == tabId }) else {
            return false
        }

        // 如果需要关闭终端
        if closeTerminal {
            if let terminalId = tab.rustTerminalId {
                closeTerminalInternal(Int(terminalId))
            }
        }

        // 如果是最后一个 Tab，移除整个 Panel
        if panel.tabCount == 1 {
            _ = terminalWindow.removePanel(panelId)

            // 更新激活的 Panel
            if activePanelId == panelId {
                activePanelId = terminalWindow.allPanels.first?.panelId
            }
        } else {
            // 从 Panel 移除 Tab
            _ = panel.closeTab(tabId)
        }

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return true
    }

    /// 添加已有的 Tab 到指定 Panel（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - tab: 要添加的 Tab
    ///   - panelId: 目标 Panel ID
    func addTab(_ tab: TerminalTab, to panelId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        panel.addTab(tab)
        _ = panel.setActiveTab(tab.tabId)

        // 设置为激活的 Panel
        setActivePanel(panelId)

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    // MARK: - Terminal Search

    /// 执行搜索
    ///
    /// 在当前激活的终端中搜索文本
    func performSearch() {
        guard !searchText.isEmpty,
              let terminalId = getActiveTerminalId() else {
            searchMatches = []
            return
        }

        // 异步搜索
        Task {
            let matches = await searchEngine.searchAsync(
                pattern: searchText,
                in: Int(terminalId),
                caseSensitive: false,
                maxRows: 1000  // 限制搜索最近 1000 行
            )

            await MainActor.run {
                self.searchMatches = matches
                // 触发渲染以显示高亮
                self.scheduleRender()
            }
        }
    }

    /// 清除搜索
    func clearSearch() {
        searchText = ""
        searchMatches = []
        showTerminalSearch = false
        scheduleRender()
    }

    /// 切换搜索框显示状态
    func toggleTerminalSearch() {
        showTerminalSearch.toggle()
        if !showTerminalSearch {
            clearSearch()
        }
    }
}
