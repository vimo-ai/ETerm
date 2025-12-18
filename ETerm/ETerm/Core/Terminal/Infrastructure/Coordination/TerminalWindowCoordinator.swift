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

// MARK: - Notification Names

extension Notification.Name {
    /// Active 终端变化通知（Tab 切换或 Panel 切换）
    static let activeTerminalDidChange = Notification.Name("activeTerminalDidChange")
    /// 终端关闭通知
    static let terminalDidClose = Notification.Name("terminalDidClose")
}

/// 渲染视图协议 - 统一不同的 RenderView 实现
protocol RenderViewProtocol: AnyObject {
    func requestRender()

    /// 调整字体大小
    func changeFontSize(operation: FontSizeOperation)

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

    /// 当前 Tab 的搜索信息（从 TabNode 获取）
    var currentTabSearchInfo: TabSearchInfo? {
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab else {
            return nil
        }
        return activeTab.searchInfo
    }

    // MARK: - Infrastructure

    /// 终端池（用于渲染）
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

    // MARK: - Terminal Migration

    /// 待附加的分离终端（跨窗口迁移时使用）
    /// 当新窗口创建时，终端先分离存储在这里，等 TerminalPool 就绪后附加
    private var pendingDetachedTerminals: [UUID: DetachedTerminalHandle] = [:]

    // MARK: - Render Debounce

    /// 防抖延迟任务
    private var pendingRenderWorkItem: DispatchWorkItem?

    /// 防抖时间窗口（16ms，约一帧）
    private let renderDebounceInterval: TimeInterval = 0.016

    // MARK: - Initialization

    init(initialWindow: TerminalWindow, terminalPool: TerminalPoolProtocol? = nil) {
        // 获取继承的 CWD（如果有）
        self.initialCwd = WindowCwdManager.shared.takePendingCwd()

        self.terminalWindow = initialWindow
        self.terminalPool = terminalPool ?? MockTerminalPool()

        // 不在这里创建终端，等 setTerminalPool 时再创建
        // （因为初始化时可能还在用 MockTerminalPool）

        // 设置初始激活的 Panel 为第一个 Panel
        activePanelId = initialWindow.allPanels.first?.panelId

        // 监听 Claude 响应完成通知
        setupClaudeNotifications()

        // 监听 Drop 意图执行通知
        setupDropIntentHandler()
    }

    /// 设置 Drop 意图执行监听
    private func setupDropIntentHandler() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExecuteDropIntent(_:)),
            name: .executeDropIntent,
            object: nil
        )
    }

    /// 处理 Drop 意图执行
    @objc private func handleExecuteDropIntent(_ notification: Notification) {
        guard let intent = notification.userInfo?["intent"] as? DropIntent else {
            return
        }

        switch intent {
        case .reorderTabs(let panelId, let tabIds):
            executeTabReorder(panelId: panelId, tabIds: tabIds)

        case .moveTabToPanel(let tabId, let sourcePanelId, let targetPanelId):
            executeMoveTabToPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId)

        case .splitWithNewPanel(let tabId, let sourcePanelId, let targetPanelId, let edge):
            executeSplitWithNewPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId, edge: edge)

        case .movePanelInLayout(let panelId, let targetPanelId, let edge):
            executeMovePanelInLayout(panelId: panelId, targetPanelId: targetPanelId, edge: edge)

        case .moveTabAcrossWindow(let tabId, let sourcePanelId, let sourceWindowNumber, let targetPanelId, let targetWindowNumber):
            // 跨窗口移动由 WindowManager 处理
            WindowManager.shared.moveTab(tabId, from: sourcePanelId, sourceWindowNumber: sourceWindowNumber, to: targetPanelId, targetWindowNumber: targetWindowNumber)
            return
        }

        // 统一的后处理
        syncLayoutToRust()
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
        WindowManager.shared.saveSession()
    }

    // MARK: - Drop Intent Execution

    /// 执行 Tab 重排序
    private func executeTabReorder(panelId: UUID, tabIds: [UUID]) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        if panel.reorderTabs(tabIds) {
            // 通知视图层应用重排序（视图复用，不重建）
            NotificationCenter.default.post(
                name: .applyTabReorder,
                object: nil,
                userInfo: ["panelId": panelId, "tabIds": tabIds]
            )
        }
    }

    /// 执行跨 Panel 移动 Tab（合并）
    private func executeMoveTabToPanel(tabId: UUID, sourcePanelId: UUID, targetPanelId: UUID) {
        guard let sourcePanel = terminalWindow.getPanel(sourcePanelId),
              let targetPanel = terminalWindow.getPanel(targetPanelId),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return
        }

        // 1. 添加到目标 Panel
        targetPanel.addTab(tab)
        _ = targetPanel.setActiveTab(tabId)

        // 2. 从源 Panel 移除
        if sourcePanel.tabCount > 1 {
            _ = sourcePanel.closeTab(tabId)
        } else {
            _ = terminalWindow.removePanel(sourcePanelId)
        }

        // 设置目标 Panel 为激活
        setActivePanel(targetPanelId)
    }

    /// 执行分割（创建新 Panel）
    private func executeSplitWithNewPanel(tabId: UUID, sourcePanelId: UUID, targetPanelId: UUID, edge: EdgeDirection) {
        guard let sourcePanel = terminalWindow.getPanel(sourcePanelId),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return
        }

        // 1. 从源 Panel 移除 Tab
        _ = sourcePanel.closeTab(tabId)

        // 2. 使用已有 Tab 分割目标 Panel
        let layoutCalculator = BinaryTreeLayoutCalculator()
        guard let newPanelId = terminalWindow.splitPanelWithExistingTab(
            panelId: targetPanelId,
            existingTab: tab,
            edge: edge,
            layoutCalculator: layoutCalculator
        ) else {
            // 分割失败，恢复 Tab 到源 Panel
            sourcePanel.addTab(tab)
            return
        }

        // 设置新 Panel 为激活
        setActivePanel(newPanelId)
    }

    /// 执行 Panel 移动（复用 Panel，不创建新的）
    private func executeMovePanelInLayout(panelId: UUID, targetPanelId: UUID, edge: EdgeDirection) {
        let layoutCalculator = BinaryTreeLayoutCalculator()
        if terminalWindow.movePanelInLayout(
            panelId: panelId,
            targetPanelId: targetPanelId,
            edge: edge,
            layoutCalculator: layoutCalculator
        ) {
            // 设置该 Panel 为激活
            setActivePanel(panelId)
        }
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
                if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
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
        // 获取当前 Panel 的激活 Tab 的 CWD（用于继承）
        var inheritedCwd: String? = nil
        if let panel = terminalWindow.getPanel(panelId),
           let activeTab = panel.activeTab,
           let terminalId = activeTab.rustTerminalId {
            inheritedCwd = getCwd(terminalId: Int(terminalId))
        }

        // 先创建 Tab（不分配终端 ID）
        guard let newTab = terminalWindow.createTab(in: panelId, rustTerminalId: 0) else {
            return nil
        }

        // 使用 Tab 的 stableId 创建终端
        let terminalId = createTerminalForTab(newTab, cols: 120, rows: 40, cwd: inheritedCwd)
        guard terminalId >= 0 else {
            // 创建失败，需要移除 Tab
            // TODO: 添加移除 Tab 的逻辑
            return nil
        }

        // 设置终端 ID
        newTab.setRustTerminalId(terminalId)

        // 保存 Session
        WindowManager.shared.saveSession()

        return newTab
    }

    /// 创建新 Tab 并执行初始命令
    ///
    /// - Parameters:
    ///   - panelId: 目标 Panel ID（可选，默认为当前激活的 Panel）
    ///   - cwd: 工作目录
    ///   - command: 要执行的命令（可选）
    ///   - commandDelay: 命令执行延迟（默认 0.3 秒）
    /// - Returns: 创建的 Tab 和终端 ID，失败返回 nil
    func createNewTabWithCommand(
        in panelId: UUID? = nil,
        cwd: String,
        command: String? = nil,
        commandDelay: TimeInterval = 0.3
    ) -> (tab: TerminalTab, terminalId: Int)? {
        let targetPanelId = panelId ?? activePanelId
        guard let targetPanelId = targetPanelId else {
            return nil
        }

        // 先创建 Tab（不分配终端 ID）
        guard let newTab = terminalWindow.createTab(in: targetPanelId, rustTerminalId: 0) else {
            return nil
        }

        // 使用 Tab 的 stableId 创建终端
        let terminalId = createTerminalForTab(newTab, cols: 120, rows: 40, cwd: cwd)
        guard terminalId >= 0 else {
            return nil
        }

        // 设置终端 ID
        newTab.setRustTerminalId(terminalId)

        // 如果有命令，延迟执行
        if let cmd = command, !cmd.isEmpty {
            let tid = terminalId
            DispatchQueue.main.asyncAfter(deadline: .now() + commandDelay) { [weak self] in
                self?.writeInput(terminalId: tid, data: cmd)
            }
        }

        // 保存 Session
        WindowManager.shared.saveSession()

        return (newTab, terminalId)
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
            _ = terminalPool.closeTerminal(terminalId)
        }
    }

    deinit {
        // 注意：不在 deinit 中访问 terminalWindow.allPanels
        // 清理工作应该在 cleanup() 中完成
        // 这里只做最小清理，防止任何野指针访问
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil
    }

    // MARK: - Layout Synchronization (新架构：三层分离)

    /// 同步布局到 Rust 层
    ///
    /// 这是布局变化的统一入口，只在以下情况调用：
    /// - 窗口 resize
    /// - DPI 变化
    /// - 创建/关闭 Tab/Page
    /// - 切换 Page/Tab
    /// - 分栏/合并 Panel
    ///
    /// 调用时机：布局变化时主动触发，而非每帧调用
    ///
    /// 注意：新架构中，布局同步在渲染过程中自动处理（通过 renderTerminal()）
    /// 这里只需要触发渲染更新即可
    func syncLayoutToRust() {
        // 新架构：布局同步已集成到 renderAllPanels() 中
        // 这里只需触发一次渲染更新
        scheduleRender()
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

        // 创建新的延迟任务
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.renderView?.requestRender()
        }
        pendingRenderWorkItem = workItem

        // 延迟执行
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceInterval, execute: workItem)
    }

    // MARK: - Event Handlers

    /// 处理终端关闭事件
    func handleTerminalClosed(terminalId: Int) {
        // 找到对应的 Tab 并关闭
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
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
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
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
    /// 优先使用 OSC 7 缓存的 CWD（更可靠，不受子进程影响），
    /// 如果缓存为空则 fallback 到 proc_pidinfo 系统调用。
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: CWD 路径，失败返回 nil
    func getCwd(terminalId: Int) -> String? {
        // 优先使用 OSC 7 缓存的 CWD（不受子进程如 vim、claude 影响）
        if let cachedCwd = terminalPool.getCachedCwd(terminalId: terminalId) {
            return cachedCwd
        }
        // Fallback 到 proc_pidinfo（shell 未配置 OSC 7 时使用）
        return terminalPool.getCwd(terminalId: terminalId)
    }

    /// 调整字体大小
    ///
    /// - Parameter operation: 字体大小操作（增大、减小、重置）
    func changeFontSize(operation: FontSizeOperation) {
        renderView?.changeFontSize(operation: operation)
    }

    /// 设置终端池（由 PanelRenderView 初始化后调用）
    func setTerminalPool(_ pool: TerminalPoolProtocol) {
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

        // 如果有待附加的分离终端，优先使用它们（跨窗口迁移场景）
        if !pendingDetachedTerminals.isEmpty {
            attachPendingDetachedTerminals()
        } else {
            // 否则创建新终端
            createTerminalsForAllTabs()
        }

        // 初始化键盘系统
        self.keyboardSystem = KeyboardSystem(coordinator: self)
    }

    /// 设置待附加的分离终端（跨窗口迁移时使用）
    ///
    /// 在创建新窗口时调用，这些终端会在 setTerminalPool 时被附加到新池
    func setPendingDetachedTerminals(_ terminals: [UUID: DetachedTerminalHandle]) {
        self.pendingDetachedTerminals = terminals
    }

    /// 附加所有待处理的分离终端
    private func attachPendingDetachedTerminals() {
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                // 查找并附加分离的终端
                if let detached = pendingDetachedTerminals[tab.tabId] {
                    let newTerminalId = terminalPool.attachTerminal(detached)
                    if newTerminalId >= 0 {
                        tab.setRustTerminalId(newTerminalId)
                    }
                } else {
                    // 如果没有找到分离的终端，创建新的
                    let cwd = tab.takePendingCwd()
                    let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwd)
                    if terminalId >= 0 {
                        tab.setRustTerminalId(terminalId)
                    }
                }
            }
        }
        // 清空待附加列表
        pendingDetachedTerminals.removeAll()
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
    @discardableResult
    private func closeTerminalInternal(_ terminalId: Int) -> Bool {
        // 发送通知，让插件清理 Claude session 映射
        NotificationCenter.default.post(
            name: .terminalDidClose,
            object: nil,
            userInfo: ["terminal_id": terminalId]
        )

        return terminalPool.closeTerminal(terminalId)
    }

    /// 创建终端（统一入口）
    ///
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
            let terminalId = terminalPool.createTerminalWithCwd(cols: cols, rows: rows, shell: shell, cwd: cwdPath)

            if terminalId >= 0 {
                // 如果使用的是 initialCwd，清除它（只有第一个终端使用）
                if cwd == nil && initialCwd != nil {
                    initialCwd = nil
                }

                return terminalId
            }
            // 如果带 CWD 创建失败，继续走默认逻辑
        }

        // 默认行为：不指定 CWD
        return terminalPool.createTerminal(cols: cols, rows: rows, shell: shell)
    }

    /// 恢复 Claude 会话
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - sessionId: Claude Session ID
    private func restoreClaudeSession(terminalId: Int, sessionId: String) {
        // 发送 claude --resume 命令
        let command = "claude --resume \(sessionId)\n"
        terminalPool.writeInput(terminalId: terminalId, data: command)
    }

    /// 为 Tab 创建终端（使用 Tab 的 stableId）
    ///
    /// 用于确保重启后 Terminal ID 保持一致
    private func createTerminalForTab(_ tab: TerminalTab, cols: UInt16, rows: UInt16, cwd: String? = nil) -> Int {
        let stableId = tab.tabId.stableId

        // 优先使用传入的 CWD
        var effectiveCwd = cwd

        // 如果没有传入 CWD，检查是否有 initialCwd（用于新窗口继承）
        if effectiveCwd == nil {
            effectiveCwd = initialCwd
        }

        // 使用 stableId 创建终端
        let terminalId = terminalPool.createTerminalWithIdAndCwd(
            stableId,
            cols: cols,
            rows: rows,
            cwd: effectiveCwd
        )

        if terminalId >= 0 {
            // 如果使用的是 initialCwd，清除它（只有第一个终端使用）
            if cwd == nil && initialCwd != nil {
                initialCwd = nil
            }
        }

        return terminalId
    }

    /// 写入输入（统一入口）
    @discardableResult
    private func writeInputInternal(terminalId: Int, data: String) -> Bool {
        return terminalPool.writeInput(terminalId: terminalId, data: data)
    }

    /// 滚动（统一入口）
    @discardableResult
    private func scrollInternal(terminalId: Int, deltaLines: Int32) -> Bool {
        return terminalPool.scroll(terminalId: terminalId, deltaLines: deltaLines)
    }

    /// 清除选区（统一入口）
    @discardableResult
    private func clearSelectionInternal(terminalId: Int) -> Bool {
        return terminalPool.clearSelection(terminalId: terminalId)
    }

    /// 获取光标位置（统一入口）
    private func getCursorPositionInternal(terminalId: Int) -> CursorPosition? {
        return terminalPool.getCursorPosition(terminalId: terminalId)
    }

    /// 为所有 Tab 创建终端（只创建当前激活Page的终端）
    private func createTerminalsForAllTabs() {
        ensureTerminalsForActivePage()
    }

    /// 确保指定Page的所有终端都已创建（延迟创建）
    private func ensureTerminalsForPage(_ page: Page) {
        for (_, panel) in page.allPanels.enumerated() {
            for (_, tab) in panel.tabs.enumerated() {
                // 如果 Tab 还没有终端，创建一个
                if tab.rustTerminalId == nil {
                    // 检查是否有待恢复的 CWD（用于 Session 恢复）
                    let cwdToUse = tab.takePendingCwd()

                    // 使用 Tab 的 stableId 创建终端
                    let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwdToUse)
                    if terminalId >= 0 {
                        tab.setRustTerminalId(terminalId)

                        // 检查是否需要恢复 Claude 会话
                        let tabIdString = tab.tabId.uuidString
                        if let sessionId = ClaudeSessionMapper.shared.getSessionIdForTab(tabIdString) {
                            // 延迟发送恢复命令，等待终端完全启动
                            let capturedTerminalId = terminalId
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                self?.restoreClaudeSession(terminalId: capturedTerminalId, sessionId: sessionId)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 确保当前激活Page的终端都已创建
    private func ensureTerminalsForActivePage() {
        guard let activePage = terminalWindow.activePage else {
            return
        }
        ensureTerminalsForPage(activePage)
    }



    // MARK: - User Interactions (从 UI 层调用)

    /// 用户点击 Tab
    func handleTabClick(panelId: UUID, tabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        // 设置为激活的 Panel（用于键盘输入）
        setActivePanel(panelId)

        // 检查是否已经是激活的 Tab
        if panel.activeTabId == tabId {
            return
        }

        // 获取旧 Tab 的终端 ID（用于设置为 Background）
        let oldTerminalId = panel.activeTab?.rustTerminalId

        // 调用 AR 的方法切换 Tab
        if panel.setActiveTab(tabId) {
            // 核心逻辑：Tab 被激活时自动消费提醒状态
            clearTabAttention(tabId)

            // 更新终端模式：旧 Tab -> Background，新 Tab -> Active
            if let oldId = oldTerminalId {
                terminalPool.setMode(terminalId: Int(oldId), mode: .background)
            }
            if let newTab = panel.activeTab, let newId = newTab.rustTerminalId {
                terminalPool.setMode(terminalId: Int(newId), mode: .active)
            }

            // 同步布局到 Rust（Tab 切换可能改变显示的终端）
            syncLayoutToRust()

            // 触发渲染更新
            objectWillChange.send()
            updateTrigger = UUID()
            scheduleRender()

            // 通知显示 Active 终端发光效果
            NotificationCenter.default.post(name: .activeTerminalDidChange, object: nil)
        }
    }

    /// 设置激活的 Panel（用于键盘输入）
    func setActivePanel(_ panelId: UUID) {
        guard terminalWindow.getPanel(panelId) != nil else {
            return
        }

        if activePanelId != panelId {
            activePanelId = panelId
            // 触发 UI 更新，让 Tab 高亮状态刷新
            objectWillChange.send()
            updateTrigger = UUID()
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

        // 同步布局到 Rust（关闭 Tab）
        syncLayoutToRust()

        // 注意：removeTab 已经包含了 saveSession()，这里不需要重复保存
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

    /// 关闭其他 Tab（保留指定的 Tab）
    func handleTabCloseOthers(panelId: UUID, keepTabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        // 收集要关闭的 Tab ID
        let tabsToClose = panel.tabs.filter { $0.tabId != keepTabId }.map { $0.tabId }

        // 逐个关闭
        for tabId in tabsToClose {
            _ = removeTab(tabId, from: panelId, closeTerminal: true)
        }

        if !tabsToClose.isEmpty {
            syncLayoutToRust()
        }
    }

    /// 关闭左侧 Tab
    func handleTabCloseLeft(panelId: UUID, fromTabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId),
              let fromIndex = panel.tabs.firstIndex(where: { $0.tabId == fromTabId }) else {
            return
        }

        // 收集左侧要关闭的 Tab ID
        let tabsToClose = panel.tabs.prefix(fromIndex).map { $0.tabId }

        // 逐个关闭
        for tabId in tabsToClose {
            _ = removeTab(tabId, from: panelId, closeTerminal: true)
        }

        if !tabsToClose.isEmpty {
            syncLayoutToRust()
        }
    }

    /// 关闭右侧 Tab
    func handleTabCloseRight(panelId: UUID, fromTabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId),
              let fromIndex = panel.tabs.firstIndex(where: { $0.tabId == fromTabId }) else {
            return
        }

        // 收集右侧要关闭的 Tab ID
        let tabsToClose = panel.tabs.suffix(from: fromIndex + 1).map { $0.tabId }

        // 逐个关闭
        for tabId in tabsToClose {
            _ = removeTab(tabId, from: panelId, closeTerminal: true)
        }

        if !tabsToClose.isEmpty {
            syncLayoutToRust()
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

                // 同步布局到 Rust（关闭 Panel）
                syncLayoutToRust()

                objectWillChange.send()
                updateTrigger = UUID()
                scheduleRender()

                // 保存 Session
                WindowManager.shared.saveSession()

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

            // 同步布局到 Rust（关闭 Panel）
            syncLayoutToRust()

            objectWillChange.send()
            updateTrigger = UUID()
            scheduleRender()

            // 保存 Session
            WindowManager.shared.saveSession()
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

        // 同步布局到 Rust（新增 Tab）
        syncLayoutToRust()

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
                        // 使用 Tab 的 stableId 创建终端
                        let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: inheritedCwd)
                        if terminalId >= 0 {
                            tab.setRustTerminalId(terminalId)
                        }
                    }
                }
            }

            // 设置新 Panel 为激活状态
            setActivePanel(newPanelId)

            // 同步布局到 Rust（分栏改变了布局）
            syncLayoutToRust()

            objectWillChange.send()
            updateTrigger = UUID()
            scheduleRender()

            // 保存 Session
            WindowManager.shared.saveSession()
        }
    }

    // MARK: - Drag & Drop

    /// 处理 Tab 拖拽 Drop（两阶段模式）
    ///
    /// Phase 1: 只捕获意图，不执行任何模型变更
    /// Phase 2: 在 drag session 结束后执行实际变更
    ///
    /// - Parameters:
    ///   - tabId: 被拖拽的 Tab ID
    ///   - sourcePanelId: 源 Panel ID（从拖拽数据中获取，不再搜索）
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 是否成功接受 drop
    func handleDrop(tabId: UUID, sourcePanelId: UUID, dropZone: DropZone, targetPanelId: UUID) -> Bool {
        // 验证（不修改模型）
        guard let sourcePanel = terminalWindow.getPanel(sourcePanelId),
              sourcePanel.tabs.contains(where: { $0.tabId == tabId }) else {
            return false
        }

        guard terminalWindow.getPanel(targetPanelId) != nil else {
            return false
        }

        // 同一个 Panel 内部移动交给 PanelHeaderHostingView 处理
        if sourcePanelId == targetPanelId && (dropZone.type == .header || dropZone.type == .body) {
            return false
        }

        // 根据场景创建不同的意图
        let intent: DropIntent
        switch dropZone.type {
        case .header, .body:
            // Tab 合并到目标 Panel
            intent = .moveTabToPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId)

        case .left, .right, .top, .bottom:
            // 边缘分栏 - 将 dropZone.type 转换为 EdgeDirection
            let edge: EdgeDirection = {
                switch dropZone.type {
                case .top: return .top
                case .bottom: return .bottom
                case .left: return .left
                case .right: return .right
                default: return .bottom // fallback，不应该发生
                }
            }()

            if sourcePanel.tabCount == 1 {
                // 源 Panel 只有 1 个 Tab → 复用 Panel（关键优化！）
                intent = .movePanelInLayout(panelId: sourcePanelId, targetPanelId: targetPanelId, edge: edge)
            } else {
                // 源 Panel 有多个 Tab → 创建新 Panel
                intent = .splitWithNewPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId, edge: edge)
            }
        }

        // 提交意图到队列，等待 drag session 结束后执行
        DropIntentQueue.shared.submit(intent)
        return true
    }

    // MARK: - Input Handling

    /// 获取当前激活的终端 ID
    func getActiveTerminalId() -> Int? {
        // 使用激活的 Panel
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab else {
            // 如果没有激活的 Panel，fallback 到第一个
            return terminalWindow.allPanels.first?.activeTab?.rustTerminalId
        }

        return activeTab.rustTerminalId
    }

    /// 获取当前激活的 Tab 的工作目录
    func getActiveTabCwd() -> String? {
        guard let terminalId = getActiveTerminalId() else {
            return nil
        }

        // 使用终端池获取 CWD
        return getCwd(terminalId: Int(terminalId)) ?? NSHomeDirectory()
    }

    /// 检查当前激活的终端是否有正在运行的子进程
    ///
    /// 返回 true 如果前台进程不是 shell 本身（如正在运行 vim, cargo, python 等）
    func hasActiveTerminalRunningProcess() -> Bool {
        guard let terminalId = getActiveTerminalId() else {
            return false
        }
        return terminalPool.hasRunningProcess(terminalId: Int(terminalId))
    }

    /// 检查当前激活的终端是否启用了 Bracketed Paste Mode
    ///
    /// 当启用时（应用程序发送了 \x1b[?2004h），粘贴时应该用转义序列包裹内容。
    /// 当未启用时，直接发送原始文本。
    func isActiveTerminalBracketedPasteEnabled() -> Bool {
        guard let terminalId = getActiveTerminalId() else {
            return false
        }
        return terminalPool.isBracketedPasteEnabled(terminalId: Int(terminalId))
    }

    /// 获取当前激活终端的前台进程名称
    func getActiveTerminalForegroundProcessName() -> String? {
        guard let terminalId = getActiveTerminalId() else {
            return nil
        }
        return terminalPool.getForegroundProcessName(terminalId: Int(terminalId))
    }

    /// 收集窗口中所有正在运行进程的信息
    ///
    /// 返回一个数组，包含所有正在运行非 shell 进程的 Tab 信息
    func collectRunningProcesses() -> [(tabTitle: String, processName: String)] {
        var processes: [(String, String)] = []

        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                guard let terminalId = tab.rustTerminalId else { continue }
                if terminalPool.hasRunningProcess(terminalId: Int(terminalId)),
                   let processName = terminalPool.getForegroundProcessName(terminalId: Int(terminalId)) {
                    processes.append((tab.title, processName))
                }
            }
        }

        return processes
    }

    /// 根据滚轮事件位置获取应滚动的终端 ID（鼠标所在 Panel 的激活 Tab）
    /// - Parameters:
    ///   - point: 鼠标位置（容器坐标，PageBar 下方区域）
    ///   - containerBounds: 容器区域（PageBar 下方区域）
    /// - Returns: 目标终端 ID，如果找不到则返回当前激活终端
    func getTerminalIdAtPoint(_ point: CGPoint, containerBounds: CGRect) -> Int? {
        if let panelId = findPanel(at: point, containerBounds: containerBounds),
           let panel = terminalWindow.getPanel(panelId),
           let activeTab = panel.activeTab,
           let terminalId = activeTab.rustTerminalId {
            return terminalId
        }

        return getActiveTerminalId()
    }

    /// 写入输入到指定终端
    func writeInput(terminalId: Int, data: String) {
        writeInputInternal(terminalId: terminalId, data: data)
        // 不主动触发渲染，依赖 Wakeup 事件（终端有输出时自动触发）
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
    func handleScroll(terminalId: Int, deltaLines: Int32) {
        _ = scrollInternal(terminalId: terminalId, deltaLines: deltaLines)
        renderView?.requestRender()
    }

    // MARK: - 文本选中 API (Text Selection)

    /// 设置指定终端的选中范围（用于高亮渲染）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - selection: 选中范围（使用真实行号）
    /// - Returns: 是否成功
    func setSelection(terminalId: Int, selection: TextSelection) -> Bool {
        let (startRow, startCol, endRow, endCol) = selection.normalized()

        // 使用终端池设置选区
        guard let wrapper = terminalPool as? TerminalPoolWrapper else {
            return false
        }

        let success = wrapper.setSelection(
            terminalId: terminalId,
            startAbsoluteRow: startRow,
            startCol: Int(startCol),
            endAbsoluteRow: endRow,
            endCol: Int(endCol)
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
    func clearSelection(terminalId: Int) -> Bool {
        let success = clearSelectionInternal(terminalId: terminalId)

        if success {
            renderView?.requestRender()
        }

        return success
    }

    /// 获取选中的文本（不清除选区）
    ///
    /// 用于 Cmd+C 复制等场景
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 选中的文本，或 nil（无选区）
    func getSelectionText(terminalId: Int) -> String? {
        return terminalPool.getSelectionText(terminalId: terminalId)
    }

    /// 获取指定终端的当前输入行号
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 输入行号，如果不在输入模式返回 nil
    func getInputRow(terminalId: Int) -> UInt16? {
        return terminalPool.getInputRow(terminalId: terminalId)
    }

    /// 获取指定终端的光标位置
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 光标位置，失败返回 nil
    func getCursorPosition(terminalId: Int) -> CursorPosition? {
        return getCursorPositionInternal(terminalId: terminalId)
    }

    // MARK: - Rendering (核心方法)

    /// 渲染所有 Panel
    ///
    /// 单向数据流：从 AR 拉取数据，调用 Rust 渲染
    func renderAllPanels(containerBounds: CGRect) {
        // 如果当前激活的 Page 是插件页面，不需要渲染终端
        if let activePage = terminalWindow.activePage, activePage.isPluginPage {
            return
        }

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

        // 🧹 清除渲染缓冲区（在渲染新内容前）
        // 这确保切换 Page 时旧内容不会残留
        terminalPool.clear()

        // 渲染每个 Tab
        // PTY 读取在 Rust 侧事件驱动处理，这里只负责渲染

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

        // 统一提交所有 objects
        let flushStart = CFAbsoluteTimeGetCurrent()
        terminalPool.flush()
        let flushTime = (CFAbsoluteTimeGetCurrent() - flushStart) * 1000

        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
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
        // 获取当前激活终端的 CWD（用于继承）
        var inheritedCwd: String? = nil
        if let terminalId = getActiveTerminalId() {
            inheritedCwd = getCwd(terminalId: Int(terminalId))
        }

        let newPage = terminalWindow.createPage(title: title)

        // 为新 Page 的初始 Tab 创建终端（继承 CWD）
        for panel in newPage.allPanels {
            for tab in panel.tabs {
                if tab.rustTerminalId == nil {
                    // 使用 Tab 的 stableId 创建终端
                    let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: inheritedCwd)
                    if terminalId >= 0 {
                        tab.setRustTerminalId(terminalId)
                    }
                }
            }
        }

        // 自动切换到新 Page
        _ = terminalWindow.switchToPage(newPage.pageId)

        // 更新激活的 Panel
        activePanelId = newPage.allPanels.first?.panelId

        // 同步布局到 Rust（新增 Page）
        syncLayoutToRust()

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        // 保存 Session
        WindowManager.shared.saveSession()

        return newPage.pageId
    }

    /// 切换到指定 Page
    ///
    /// - Parameter pageId: 目标 Page ID
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToPage(_ pageId: UUID) -> Bool {
        // Step 0: 收集旧 Page 的所有终端 ID（用于设置为 Background）
        var oldTerminalIds: [Int] = []
        if let oldPage = terminalWindow.activePage {
            for panel in oldPage.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        oldTerminalIds.append(terminalId)
                    }
                }
            }
        }

        // Step 1: Domain 层切换
        guard terminalWindow.switchToPage(pageId) else {
            return false
        }

        // Step 2: 延迟创建终端（Lazy Loading）
        if let activePage = terminalWindow.activePage {
            ensureTerminalsForPage(activePage)
        }

        // Step 3: 更新激活的 Panel
        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        // Step 4: 更新终端模式
        // 旧 Page 的所有终端 -> Background
        for oldId in oldTerminalIds {
            terminalPool.setMode(terminalId: Int(oldId), mode: .background)
        }
        // 新 Page 的激活终端 -> Active
        if let newPage = terminalWindow.activePage {
            for panel in newPage.allPanels {
                if let activeTab = panel.activeTab, let terminalId = activeTab.rustTerminalId {
                    terminalPool.setMode(terminalId: Int(terminalId), mode: .active)
                }
            }
        }

        // Step 5: 同步布局到 Rust（Page 切换改变了显示的终端）
        syncLayoutToRust()

        // Step 6: 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()

        // Step 7: 请求渲染（防抖）
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

        // 同步布局到 Rust（关闭 Page）
        syncLayoutToRust()

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        // 保存 Session
        WindowManager.shared.saveSession()

        return true
    }

    /// 关闭其他 Page（保留指定的 Page）
    func handlePageCloseOthers(keepPageId: UUID) {
        // 收集要关闭的 Page ID
        let pagesToClose = terminalWindow.pages.filter { $0.pageId != keepPageId }.map { $0.pageId }

        // 逐个关闭
        for pageId in pagesToClose {
            _ = closePage(pageId)
        }
    }

    /// 关闭左侧 Page
    func handlePageCloseLeft(fromPageId: UUID) {
        guard let fromIndex = terminalWindow.pages.firstIndex(where: { $0.pageId == fromPageId }) else {
            return
        }

        // 收集左侧要关闭的 Page ID
        let pagesToClose = terminalWindow.pages.prefix(fromIndex).map { $0.pageId }

        // 逐个关闭
        for pageId in pagesToClose {
            _ = closePage(pageId)
        }
    }

    /// 关闭右侧 Page
    func handlePageCloseRight(fromPageId: UUID) {
        guard let fromIndex = terminalWindow.pages.firstIndex(where: { $0.pageId == fromPageId }) else {
            return
        }

        // 收集右侧要关闭的 Page ID
        let pagesToClose = terminalWindow.pages.suffix(from: fromIndex + 1).map { $0.pageId }

        // 逐个关闭
        for pageId in pagesToClose {
            _ = closePage(pageId)
        }
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

        // 保存 Session
        WindowManager.shared.saveSession()

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

        // 同步布局到 Rust（Page 切换）
        syncLayoutToRust()

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

        // 同步布局到 Rust（Page 切换）
        syncLayoutToRust()

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

        // 从 TerminalWindow 移除 Page（使用 forceRemovePage 允许移除最后一个 Page）
        guard let removedPage = terminalWindow.forceRemovePage(pageId) else {
            return nil
        }

        // 更新激活的 Panel
        activePanelId = terminalWindow.activePage?.allPanels.first?.panelId

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return removedPage
    }

    /// 添加已有的 Page（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - page: 要添加的 Page
    ///   - insertBefore: 插入到指定 Page 之前（nil 表示插入到末尾）
    ///   - tabCwds: Tab ID 到 CWD 的映射（用于跨窗口移动时重建终端，已废弃）
    ///   - detachedTerminals: Tab ID 到分离终端的映射（用于真正的终端迁移）
    func addPage(_ page: Page, insertBefore targetPageId: UUID? = nil, tabCwds: [UUID: String]? = nil, detachedTerminals: [UUID: DetachedTerminalHandle]? = nil) {
        if let targetId = targetPageId {
            // 插入到指定位置
            terminalWindow.addExistingPage(page, insertBefore: targetId)
        } else {
            // 添加到末尾
            terminalWindow.addExistingPage(page)
        }

        // 优先使用终端迁移（保留 PTY 连接和历史）
        if let terminals = detachedTerminals {
            attachTerminalsForPage(page, detachedTerminals: terminals)
        } else if let cwds = tabCwds {
            // 回退到重建终端（会丢失历史）
            recreateTerminalsForPage(page, tabCwds: cwds)
        }

        // 切换到新添加的 Page
        _ = terminalWindow.switchToPage(page.pageId)

        // 更新激活的 Panel
        activePanelId = page.allPanels.first?.panelId

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    // MARK: - 终端迁移（跨窗口移动）

    /// 分离终端（用于跨窗口迁移）
    ///
    /// - Parameter terminalId: 要分离的终端 ID
    /// - Returns: DetachedTerminalHandle，失败返回 nil
    func detachTerminal(_ terminalId: Int) -> DetachedTerminalHandle? {
        return terminalPool.detachTerminal(terminalId)
    }

    /// 附加分离的终端到 Page（用于跨窗口迁移）
    ///
    /// - Parameters:
    ///   - page: 目标 Page
    ///   - detachedTerminals: Tab ID 到分离终端的映射
    private func attachTerminalsForPage(_ page: Page, detachedTerminals: [UUID: DetachedTerminalHandle]) {
        for panel in page.allPanels {
            for tab in panel.tabs {
                // 清除旧的终端 ID（它属于源窗口的 Pool）
                tab.setRustTerminalId(nil)

                // 查找并附加分离的终端
                if let detached = detachedTerminals[tab.tabId] {
                    let newTerminalId = terminalPool.attachTerminal(detached)
                    if newTerminalId >= 0 {
                        tab.setRustTerminalId(newTerminalId)
                    }
                }
            }
        }
    }

    /// 重建 Page 中所有 Tab 的终端（已废弃，使用 attachTerminalsForPage）
    ///
    /// 当 Page 从另一个窗口移动过来时，旧终端在源窗口的 Pool 中，
    /// 需要在当前窗口的 Pool 中重建终端。
    ///
    /// - Parameters:
    ///   - page: 要重建终端的 Page
    ///   - tabCwds: Tab ID 到 CWD 的映射
    private func recreateTerminalsForPage(_ page: Page, tabCwds: [UUID: String]) {
        for panel in page.allPanels {
            for tab in panel.tabs {
                // 清除旧的终端 ID（它属于源窗口的 Pool）
                tab.setRustTerminalId(nil)

                // 获取 CWD
                let cwd = tabCwds[tab.tabId]

                // 使用 Tab 的 stableId 在当前窗口的 Pool 中创建新终端
                let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwd)
                if terminalId >= 0 {
                    tab.setRustTerminalId(terminalId)
                }
            }
        }
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

        // 保存 Session
        WindowManager.shared.saveSession()

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

    // MARK: - Terminal Search (Tab-Level)

    /// 开始搜索（在当前激活的 Tab 中）
    ///
    /// - Parameters:
    ///   - pattern: 搜索模式
    ///   - isRegex: 是否为正则表达式（暂不支持）
    ///   - caseSensitive: 是否区分大小写（暂不支持）
    func startSearch(pattern: String, isRegex: Bool = false, caseSensitive: Bool = false) {
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId,
              let wrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        // 调用 Rust 端搜索
        let matchCount = wrapper.search(terminalId: Int(terminalId), query: pattern)

        if matchCount > 0 {
            // 更新 Tab 的搜索信息
            let searchInfo = TabSearchInfo(
                pattern: pattern,
                totalCount: matchCount,
                currentIndex: 1  // 搜索后光标在第一个匹配
            )
            activeTab.setSearchInfo(searchInfo)
        } else {
            // 无匹配，清除搜索信息
            activeTab.setSearchInfo(nil)
        }

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    /// 跳转到下一个匹配
    func searchNext() {
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId,
              let searchInfo = activeTab.searchInfo,
              let wrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        // 调用 Rust 端跳转
        wrapper.searchNext(terminalId: Int(terminalId))

        // 更新索引（循环）
        let newIndex = searchInfo.currentIndex % searchInfo.totalCount + 1
        activeTab.updateSearchIndex(currentIndex: newIndex, totalCount: searchInfo.totalCount)

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    /// 跳转到上一个匹配
    func searchPrev() {
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId,
              let searchInfo = activeTab.searchInfo,
              let wrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        // 调用 Rust 端跳转
        wrapper.searchPrev(terminalId: Int(terminalId))

        // 更新索引（循环）
        let newIndex = searchInfo.currentIndex > 1 ? searchInfo.currentIndex - 1 : searchInfo.totalCount
        activeTab.updateSearchIndex(currentIndex: newIndex, totalCount: searchInfo.totalCount)

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    /// 清除当前 Tab 的搜索
    func clearSearch() {
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 调用 Rust 端清除搜索
        if let terminalId = activeTab.rustTerminalId,
           let wrapper = terminalPool as? TerminalPoolWrapper {
            wrapper.clearSearch(terminalId: Int(terminalId))
        }

        // 清除 Tab 的搜索信息
        activeTab.setSearchInfo(nil)

        // 触发渲染更新
        showTerminalSearch = false
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    /// 切换搜索框显示状态
    func toggleTerminalSearch() {
        showTerminalSearch.toggle()
        if !showTerminalSearch {
            clearSearch()
        }
    }

    // MARK: - Divider Ratio Management

    /// 更新分隔线比例
    ///
    /// - Parameters:
    ///   - layoutPath: 从根节点到分割节点的路径（0=first, 1=second）
    ///   - newRatio: 新的比例值（0.1 到 0.9）
    func updateDividerRatio(layoutPath: [Int], newRatio: CGFloat) {
        // 更新 Domain 层的布局
        terminalWindow.updateDividerRatio(path: layoutPath, newRatio: newRatio)

        // 同步布局到 Rust（重新计算所有 Panel 的 bounds）
        syncLayoutToRust()

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        // 保存 Session
        WindowManager.shared.saveSession()
    }

    /// 获取指定路径的分割比例
    ///
    /// - Parameter layoutPath: 从根节点到分割节点的路径
    /// - Returns: 当前比例，失败返回 nil
    func getRatioAtPath(_ layoutPath: [Int]) -> CGFloat? {
        return getRatioAtPath(layoutPath, in: terminalWindow.rootLayout)
    }

    /// 递归查找指定路径的比例
    private func getRatioAtPath(_ path: [Int], in layout: PanelLayout) -> CGFloat? {
        // 空路径表示根节点
        if path.isEmpty {
            if case .split(_, _, _, let ratio) = layout {
                return ratio
            }
            return nil
        }

        // 继续向下查找
        guard case .split(_, let first, let second, _) = layout else {
            return nil
        }

        // 递归到子节点
        let nextPath = Array(path.dropFirst())
        let nextLayout = path[0] == 0 ? first : second
        return getRatioAtPath(nextPath, in: nextLayout)
    }

    // MARK: - Page Drag & Drop (SwiftUI PageBar)

    /// 处理 Page 重排序（同窗口内）
    ///
    /// - Parameters:
    ///   - draggedPageId: 被拖拽的 Page ID
    ///   - targetPageId: 目标 Page ID（插入到该 Page 之前）
    /// - Returns: 是否成功
    @discardableResult
    func handlePageReorder(draggedPageId: UUID, targetPageId: UUID) -> Bool {
        // 获取当前 Page 列表
        let pages = terminalWindow.pages
        guard let sourceIndex = pages.firstIndex(where: { $0.pageId == draggedPageId }),
              let targetIndex = pages.firstIndex(where: { $0.pageId == targetPageId }) else {
            return false
        }

        // 如果位置相同或相邻，不处理
        if sourceIndex == targetIndex || sourceIndex + 1 == targetIndex {
            return false
        }

        // 构建新的 Page ID 顺序
        var newPageIds = pages.map { $0.pageId }
        let movedPageId = newPageIds.remove(at: sourceIndex)
        let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        newPageIds.insert(movedPageId, at: insertIndex)

        // 调用重排序方法
        return reorderPages(newPageIds)
    }

    /// 处理 Page 移动到末尾（同窗口内）
    ///
    /// - Parameter pageId: 要移动的 Page ID
    /// - Returns: 是否成功
    @discardableResult
    func handlePageMoveToEnd(pageId: UUID) -> Bool {
        let pages = terminalWindow.pages
        guard let sourceIndex = pages.firstIndex(where: { $0.pageId == pageId }) else {
            return false
        }

        // 如果已经在末尾，不处理
        if sourceIndex == pages.count - 1 {
            return false
        }

        // 构建新的 Page ID 顺序
        var newPageIds = pages.map { $0.pageId }
        let movedPageId = newPageIds.remove(at: sourceIndex)
        newPageIds.append(movedPageId)

        return reorderPages(newPageIds)
    }

    /// 处理从其他窗口接收 Page（跨窗口拖拽）
    ///
    /// - Parameters:
    ///   - pageId: 被拖拽的 Page ID
    ///   - sourceWindowNumber: 源窗口编号
    ///   - targetWindowNumber: 目标窗口编号
    ///   - insertBefore: 插入到指定 Page 之前（nil 表示插入到末尾）
    func handlePageReceivedFromOtherWindow(_ pageId: UUID, sourceWindowNumber: Int, targetWindowNumber: Int, insertBefore targetPageId: UUID?) {
        WindowManager.shared.movePage(
            pageId,
            from: sourceWindowNumber,
            to: targetWindowNumber,
            insertBefore: targetPageId
        )
    }

    /// 处理 Page 拖出窗口（创建新窗口）
    ///
    /// - Parameters:
    ///   - pageId: 被拖拽的 Page ID
    ///   - screenPoint: 屏幕坐标
    func handlePageDragOutOfWindow(_ pageId: UUID, at screenPoint: NSPoint) {
        // 检查是否拖到了其他窗口
        if WindowManager.shared.findWindow(at: screenPoint) != nil {
            // 拖到了其他窗口，由 dropDestination 处理
            return
        }

        // 拖出了所有窗口，创建新窗口
        guard let page = terminalWindow.pages.first(where: { $0.pageId == pageId }) else {
            return
        }

        // 在新窗口位置创建窗口
        WindowManager.shared.createWindowWithPage(page, from: self, at: screenPoint)
    }

    // MARK: - Panel Navigation

    /// 向上导航到相邻 Panel
    func navigatePanelUp() {
        navigatePanel(direction: .up)
    }

    /// 向下导航到相邻 Panel
    func navigatePanelDown() {
        navigatePanel(direction: .down)
    }

    /// 向左导航到相邻 Panel
    func navigatePanelLeft() {
        navigatePanel(direction: .left)
    }

    /// 向右导航到相邻 Panel
    func navigatePanelRight() {
        navigatePanel(direction: .right)
    }

    /// Panel 导航统一入口
    ///
    /// - Parameter direction: 导航方向
    private func navigatePanel(direction: NavigationDirection) {
        guard let currentPanelId = activePanelId,
              let currentPage = terminalWindow.activePage else {
            return
        }

        // 获取容器尺寸（从 renderView 转换为 NSView）
        guard let renderViewAsNSView = renderView as? NSView else {
            return
        }

        let containerBounds = renderViewAsNSView.bounds

        // 使用导航服务查找目标 Panel
        guard let targetPanelId = PanelNavigationService.findNearestPanel(
            from: currentPanelId,
            direction: direction,
            in: currentPage,
            containerBounds: containerBounds
        ) else {
            // 没有找到目标 Panel，不执行任何操作
            return
        }

        // 切换到目标 Panel
        setActivePanel(targetPanelId)

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
    }
}
