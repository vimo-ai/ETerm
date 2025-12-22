//
//  TerminalWindow.swift
//  ETerm
//
//  领域聚合根 - 终端窗口

import Foundation
import CoreGraphics
import SwiftUI
import Combine

/// 当前激活的焦点（Page + Panel 的组合）
struct ActiveFocus: Codable, Equatable {
    var pageId: UUID
    var panelId: UUID
}

/// 终端窗口
///
/// 管理整个窗口的 Page
/// 这是窗口层级的聚合根，负责：
/// - 维护 Page 列表
/// - 协调 Page 切换
final class TerminalWindow {
    let windowId: UUID

    // MARK: - Accessors

    /// 激活状态访问器
    private(set) lazy var active = ActiveAccessor(owner: self)

    /// Page 管理访问器
    private(set) lazy var pages = PageAccessor(owner: self)

    /// 激活状态访问器 - 聚合所有 active 相关的状态和查询
    final class ActiveAccessor {
        private unowned let owner: TerminalWindow

        /// 记录每个 Page 上次激活的 Panel ID（用于切换 Page 时恢复）
        fileprivate var lastPanelIdByPage: [UUID: UUID] = [:]

        /// 焦点变化发布器（单一数据源，Coordinator 订阅此发布器）
        let focusPublisher = CurrentValueSubject<ActiveFocus?, Never>(nil)

        fileprivate init(owner: TerminalWindow) {
            self.owner = owner
        }

        // MARK: 状态

        /// 当前激活的焦点（原始状态）
        fileprivate(set) var focus: ActiveFocus? {
            didSet {
                focusPublisher.send(focus)
            }
        }

        /// 当前激活的 Page ID
        var pageId: UUID? { focus?.pageId }

        /// 当前激活的 Panel ID
        var panelId: UUID? { focus?.panelId }

        // MARK: 派生查询

        /// 当前激活的 Page
        var page: Page? {
            guard let pageId = pageId else { return nil }
            return owner.pages.list.first { $0.pageId == pageId }
        }

        /// 当前激活的 Panel
        var panel: EditorPanel? {
            guard let panelId = panelId else { return nil }
            return page?.getPanel(panelId)
        }

        /// 当前激活的终端 ID（穿透查询到 Tab 层）
        var terminalId: Int? {
            if let panel = panel, let activeTab = panel.activeTab {
                return activeTab.rustTerminalId
            }
            // Fallback：第一个 Panel 的 activeTab
            return page?.allPanels.first?.activeTab?.rustTerminalId
        }

        // MARK: 操作

        /// 设置激活的 Panel（在当前 Page 内切换 Panel）
        func setPanel(_ panelId: UUID) {
            guard let pageId = focus?.pageId,
                  let currentPage = owner.pages.list.first(where: { $0.pageId == pageId }),
                  currentPage.containsPanel(panelId) else {
                return
            }
            focus = ActiveFocus(pageId: pageId, panelId: panelId)
            lastPanelIdByPage[pageId] = panelId
        }

        /// 设置完整的 activeFocus（用于恢复 Session）
        func setFocus(_ newFocus: ActiveFocus) {
            focus = newFocus
            lastPanelIdByPage[newFocus.pageId] = newFocus.panelId
        }

        /// 获取指定 Page 的上次激活 Panel ID（用于 Session 保存）
        func panelId(for pageId: UUID) -> UUID? {
            if focus?.pageId == pageId {
                return focus?.panelId
            }
            return lastPanelIdByPage[pageId]
        }
    }

    /// Page 管理访问器 - 聚合所有 Page 相关的状态和操作
    final class PageAccessor {
        private unowned let owner: TerminalWindow

        /// Page 列表
        fileprivate var list: [Page] = []

        fileprivate init(owner: TerminalWindow) {
            self.owner = owner
        }

        // MARK: 查询

        /// 所有 Pages
        var all: [Page] { list }

        /// Page 数量
        var count: Int { list.count }

        /// 通过 ID 获取 Page
        func get(_ pageId: UUID) -> Page? {
            list.first { $0.pageId == pageId }
        }

        /// 通过索引获取 Page
        subscript(index: Int) -> Page? {
            guard index >= 0 && index < list.count else { return nil }
            return list[index]
        }

        /// 查找指定插件的 PluginPage
        func findPlugin(pluginId: String) -> Page? {
            list.first { page in
                if case .plugin(let id, _) = page.content {
                    return id == pluginId
                }
                return false
            }
        }

        // MARK: 创建

        /// 默认 Tab 标题
        private static let defaultTabTitle = "终端"

        /// 创建新 Page
        @discardableResult
        func create(title: String? = nil) -> Page {
            let pageTitle = title ?? "Page \(list.count + 1)"
            let initialTab = TerminalTab(tabId: UUID(), title: Self.defaultTabTitle)
            let initialPanel = EditorPanel(initialTab: initialTab)
            let newPage = Page(title: pageTitle, initialPanel: initialPanel)
            list.append(newPage)
            return newPage
        }

        /// 创建插件 Page
        @discardableResult
        func addPlugin(pluginId: String, title: String, viewProvider: @escaping () -> AnyView) -> Page {
            let newPage = Page.createPluginPage(title: title, pluginId: pluginId, viewProvider: viewProvider)
            list.append(newPage)
            return newPage
        }

        /// 打开或切换到插件页面（如果已存在则返回现有页面）
        @discardableResult
        func openOrSwitchToPlugin(pluginId: String, title: String, viewProvider: @escaping () -> AnyView) -> Page {
            if let existingPage = findPlugin(pluginId: pluginId) {
                return existingPage
            }
            return addPlugin(pluginId: pluginId, title: title, viewProvider: viewProvider)
        }

        /// 添加已有的 Page（用于跨窗口移动）
        func addExisting(_ page: Page, insertBefore targetPageId: UUID? = nil) {
            if let targetId = targetPageId,
               let targetIndex = list.firstIndex(where: { $0.pageId == targetId }) {
                list.insert(page, at: targetIndex)
            } else {
                list.append(page)
            }
        }

        // MARK: 切换

        /// 切换到指定 Page
        @discardableResult
        func switchTo(_ pageId: UUID) -> Bool {
            guard let newPage = list.first(where: { $0.pageId == pageId }) else {
                return false
            }

            // 保存当前 Page 的 panelId
            if let currentPageId = owner.active.focus?.pageId,
               let currentPanelId = owner.active.focus?.panelId {
                owner.active.lastPanelIdByPage[currentPageId] = currentPanelId
            }

            // 恢复目标 Page 的 panelId
            var targetPanelId: UUID?
            if let lastPanelId = owner.active.lastPanelIdByPage[pageId],
               newPage.containsPanel(lastPanelId) {
                targetPanelId = lastPanelId
            } else {
                targetPanelId = newPage.allPanels.first?.panelId
            }

            // 设置 activeFocus
            if let panelId = targetPanelId {
                owner.active.focus = ActiveFocus(pageId: pageId, panelId: panelId)
            } else {
                // Plugin Page：只更新 pageId
                owner.active.focus = ActiveFocus(pageId: pageId, panelId: owner.active.focus?.panelId ?? UUID())
            }
            return true
        }

        /// 切换到下一个 Page
        @discardableResult
        func switchToNext() -> Bool {
            guard let currentId = owner.active.pageId,
                  let currentIndex = list.firstIndex(where: { $0.pageId == currentId }),
                  list.count > 1 else {
                return false
            }
            let nextIndex = (currentIndex + 1) % list.count
            return switchTo(list[nextIndex].pageId)
        }

        /// 切换到上一个 Page
        @discardableResult
        func switchToPrevious() -> Bool {
            guard let currentId = owner.active.pageId,
                  let currentIndex = list.firstIndex(where: { $0.pageId == currentId }),
                  list.count > 1 else {
                return false
            }
            let previousIndex = (currentIndex - 1 + list.count) % list.count
            return switchTo(list[previousIndex].pageId)
        }

        // MARK: 修改

        /// 关闭指定 Page
        @discardableResult
        func close(_ pageId: UUID) -> Bool {
            guard list.count > 1 else { return false }
            guard let index = list.firstIndex(where: { $0.pageId == pageId }) else {
                return false
            }

            list.remove(at: index)
            owner.active.lastPanelIdByPage.removeValue(forKey: pageId)

            if owner.active.pageId == pageId {
                let newIndex = min(index, list.count - 1)
                _ = switchTo(list[newIndex].pageId)
            }
            return true
        }

        /// 强制移除 Page（用于跨窗口移动，允许移除最后一个）
        func forceRemove(_ pageId: UUID) -> Page? {
            guard let index = list.firstIndex(where: { $0.pageId == pageId }) else {
                return nil
            }

            let page = list.remove(at: index)
            owner.active.lastPanelIdByPage.removeValue(forKey: pageId)

            if !list.isEmpty && owner.active.pageId == pageId {
                let newIndex = min(index, list.count - 1)
                _ = switchTo(list[newIndex].pageId)
            }
            return page
        }

        /// 重命名 Page
        @discardableResult
        func rename(_ pageId: UUID, to newTitle: String) -> Bool {
            guard let page = list.first(where: { $0.pageId == pageId }) else {
                return false
            }
            page.rename(to: newTitle)
            return true
        }

        /// 重新排序 Pages
        @discardableResult
        func reorder(_ pageIds: [UUID]) -> Bool {
            guard Set(pageIds) == Set(list.map { $0.pageId }),
                  pageIds.count == list.count else {
                return false
            }

            var reorderedPages: [Page] = []
            for pageId in pageIds {
                if let page = list.first(where: { $0.pageId == pageId }) {
                    reorderedPages.append(page)
                }
            }
            list = reorderedPages
            return true
        }

        /// 移动 Page 到指定位置之前
        ///
        /// - Parameters:
        ///   - pageId: 要移动的 Page ID
        ///   - targetId: 目标位置的 Page ID
        /// - Returns: 新的 Page ID 顺序，如果无需移动返回 nil
        func move(_ pageId: UUID, before targetId: UUID) -> [UUID]? {
            guard let sourceIndex = list.firstIndex(where: { $0.pageId == pageId }),
                  let targetIndex = list.firstIndex(where: { $0.pageId == targetId }) else {
                return nil
            }

            // 如果位置相同或相邻（已在目标前），不处理
            if sourceIndex == targetIndex || sourceIndex + 1 == targetIndex {
                return nil
            }

            // 构建新的 Page ID 顺序
            var newPageIds = list.map { $0.pageId }
            let movedPageId = newPageIds.remove(at: sourceIndex)
            let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
            newPageIds.insert(movedPageId, at: insertIndex)

            // 执行重排序
            if reorder(newPageIds) {
                return newPageIds
            }
            return nil
        }

        /// 移动 Page 到末尾
        ///
        /// - Parameter pageId: 要移动的 Page ID
        /// - Returns: 新的 Page ID 顺序，如果无需移动返回 nil
        func moveToEnd(_ pageId: UUID) -> [UUID]? {
            guard let sourceIndex = list.firstIndex(where: { $0.pageId == pageId }) else {
                return nil
            }

            // 如果已在末尾，不处理
            if sourceIndex == list.count - 1 {
                return nil
            }

            // 构建新的 Page ID 顺序
            var newPageIds = list.map { $0.pageId }
            let movedPageId = newPageIds.remove(at: sourceIndex)
            newPageIds.append(movedPageId)

            // 执行重排序
            if reorder(newPageIds) {
                return newPageIds
            }
            return nil
        }
    }

    // MARK: - Initialization

    init(initialPanel: EditorPanel) {
        self.windowId = UUID()

        // 创建初始 Page
        let initialPage = Page(title: "Page 1", initialPanel: initialPanel)

        // 触发 lazy 初始化并设置初始状态
        _ = pages
        _ = active
        pages.list = [initialPage]
        active.focus = ActiveFocus(pageId: initialPage.pageId, panelId: initialPanel.panelId)
    }

    /// 使用已有的 Page 初始化（用于恢复 Session）
    init(initialPage: Page) {
        self.windowId = UUID()

        // 触发 lazy 初始化并设置初始状态
        _ = pages
        _ = active
        pages.list = [initialPage]

        // 使用第一个 Panel 作为初始 focus（如果存在）
        if let initialPanelId = initialPage.allPanels.first?.panelId {
            active.focus = ActiveFocus(pageId: initialPage.pageId, panelId: initialPanelId)
        }
        // Plugin Page 没有 Panel，active.focus 保持 nil
    }

    // MARK: - Tab Creation

    /// 默认 Tab 标题
    private static let defaultTabTitle = "终端"

    /// 创建默认 Tab（静态工厂方法）
    static func makeDefaultTab(rustTerminalId: Int = 0) -> TerminalTab {
        return TerminalTab(
            tabId: UUID(),
            title: defaultTabTitle,
            rustTerminalId: rustTerminalId
        )
    }

    /// 在指定 Panel 中创建新 Tab
    func createTab(in panelId: UUID, rustTerminalId: Int = 0) -> Tab? {
        guard let panel = getPanel(panelId) else { return nil }

        let terminalTab = TerminalTab(
            tabId: UUID(),
            title: Self.defaultTabTitle,
            rustTerminalId: rustTerminalId
        )
        let tab = Tab(
            tabId: terminalTab.tabId,
            title: terminalTab.title,
            content: .terminal(terminalTab)
        )
        panel.addTab(tab)
        return tab
    }

    // MARK: - Panel Management (通过 Active Page 代理)

    /// 分割指定的 Panel（在当前 Page 中）
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
        guard let page = active.page else {
            return nil
        }

        // 检查 Panel 是否存在
        guard page.getPanel(panelId) != nil else {
            return nil
        }

        // 创建新 Panel（包含一个默认 Tab，使用全局唯一标题）
        let newPanel = EditorPanel(
            initialTab: TerminalTab(tabId: UUID(), title: Self.defaultTabTitle)
        )

        // 在 Page 中执行分割
        guard page.splitPanel(
            panelId: panelId,
            newPanel: newPanel,
            direction: direction,
            layoutCalculator: layoutCalculator
        ) else {
            return nil
        }

        return newPanel.panelId
    }

    /// 分割 Panel 并使用已有的 Tab（用于拖拽场景）
    ///
    /// 与 `splitPanel` 不同，此方法不会创建默认 Tab，而是直接使用传入的 Tab。
    /// 适用于拖拽 Tab 到边缘创建新 Panel 的场景。
    ///
    /// - Parameters:
    ///   - panelId: 要分割的 Panel ID
    ///   - existingTab: 已有的 Tab（将被移动到新 Panel）
    ///   - edge: 边缘方向（决定新 Panel 在目标 Panel 的哪个边缘）
    ///   - layoutCalculator: 布局计算器
    /// - Returns: 新创建的 Panel ID，如果失败返回 nil
    func splitPanelWithExistingTab(
        panelId: UUID,
        existingTab: Tab,
        edge: EdgeDirection,
        layoutCalculator: LayoutCalculator
    ) -> UUID? {
        guard let page = active.page else {
            return nil
        }

        // 检查 Panel 是否存在
        guard page.getPanel(panelId) != nil else {
            return nil
        }

        // 创建新 Panel，直接使用已有的 Tab（不消耗编号）
        let newPanel = EditorPanel(initialTab: existingTab)

        // 在 Page 中执行分割
        guard page.splitPanel(
            panelId: panelId,
            newPanel: newPanel,
            edge: edge,
            layoutCalculator: layoutCalculator
        ) else {
            return nil
        }

        return newPanel.panelId
    }

    /// 获取指定 Panel（在当前 Page 中）
    func getPanel(_ panelId: UUID) -> EditorPanel? {
        return active.page?.getPanel(panelId)
    }

    /// 获取所有 Panel（在当前 Page 中）
    var allPanels: [EditorPanel] {
        return active.page?.allPanels ?? []
    }

    /// Panel 数量（在当前 Page 中）
    var panelCount: Int {
        return active.page?.panelCount ?? 0
    }

    /// 获取所有 Panel ID（在当前 Page 中）
    var allPanelIds: [UUID] {
        return active.page?.allPanelIds ?? []
    }

    /// 获取当前 Page 的 rootLayout
    var rootLayout: PanelLayout {
        return active.page?.rootLayout ?? .leaf(panelId: UUID())
    }

    // MARK: - Rendering

    /// 获取所有需要渲染的 Tab（新架构）
    func getActiveTabRenderables(
        containerBounds: CGRect,
        headerHeight: CGFloat
    ) -> [TabRenderable] {
        return active.page?.getActiveTabRenderables(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        ) ?? []
    }

    /// 获取所有需要渲染的 Tab（兼容旧 API）
    @available(*, deprecated, message: "Use getActiveTabRenderables instead")
    func getActiveTabsForRendering(
        containerBounds: CGRect,
        headerHeight: CGFloat
    ) -> [(Int, CGRect)] {
        let renderables = getActiveTabRenderables(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )
        return TabRenderable.filterTerminals(renderables)
    }

    // MARK: - Layout Query

    /// 检查布局是否包含指定 Panel（在当前 Page 中）
    func containsPanel(_ panelId: UUID) -> Bool {
        return active.page?.containsPanel(panelId) ?? false
    }

    /// 更新分隔线比例（在当前 Page 中）
    func updateDividerRatio(path: [Int], newRatio: CGFloat) {
        active.page?.updateDividerRatio(path: path, newRatio: newRatio)
    }

    /// 移除指定 Panel（在当前 Page 中）
    func removePanel(_ panelId: UUID) -> Bool {
        return active.page?.removePanel(panelId) ?? false
    }

    /// 在布局树中移动 Panel（复用 Panel，不创建新的）
    ///
    /// 用于边缘分栏场景：当源 Panel 只有 1 个 Tab 时，不创建新 Panel，
    /// 而是将源 Panel 移动到目标位置。
    ///
    /// - Parameters:
    ///   - panelId: 要移动的 Panel ID
    ///   - targetPanelId: 目标 Panel ID（在此 Panel 旁边插入）
    ///   - edge: 边缘方向（决定在目标 Panel 的哪个边缘插入）
    ///   - layoutCalculator: 布局计算器
    /// - Returns: 是否成功
    func movePanelInLayout(
        panelId: UUID,
        targetPanelId: UUID,
        edge: EdgeDirection,
        layoutCalculator: LayoutCalculator
    ) -> Bool {
        guard let page = active.page else {
            return false
        }

        return page.movePanelInLayout(
            panelId: panelId,
            targetPanelId: targetPanelId,
            edge: edge,
            layoutCalculator: layoutCalculator
        )
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

// MARK: - Command Execution

extension TerminalWindow {

    /// 执行窗口命令
    ///
    /// 领域层的统一入口，负责：
    /// - 执行业务规则（激活规则、关闭规则、CWD 继承等）
    /// - 返回需要执行的副作用（终端激活/创建/关闭、渲染、保存等）
    ///
    /// Coordinator 负责根据返回的 CommandResult 执行副作用
    func execute(_ command: WindowCommand) -> CommandResult {
        switch command {
        case .tab(let tabCommand):
            return executeTab(tabCommand)
        case .panel(let panelCommand):
            return executePanel(panelCommand)
        case .page(let pageCommand):
            return executePage(pageCommand)
        case .window(let windowCommand):
            return executeWindow(windowCommand)
        }
    }

    // MARK: - Tab Commands

    private func executeTab(_ command: TabCommand) -> CommandResult {
        switch command {
        case .switch(let panelId, let tabId):
            return executeTabSwitch(panelId: panelId, tabId: tabId)
        case .add(let panelId):
            return executeTabAdd(panelId: panelId)
        case .addWithConfig(let panelId, let config):
            return executeTabAddWithConfig(panelId: panelId, config: config)
        case .close(let panelId, let scope):
            return executeTabClose(panelId: panelId, scope: scope)
        case .remove(let tabId, let panelId, let closeTerminal):
            return executeTabRemove(tabId: tabId, panelId: panelId, closeTerminal: closeTerminal)
        case .reorder(let panelId, let order):
            return executeTabReorder(panelId: panelId, order: order)
        case .move(let tabId, let from, let to):
            return executeTabMove(tabId: tabId, from: from, to: to)
        }
    }

    private func executeTabSwitch(panelId: UUID, tabId: UUID) -> CommandResult {
        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        let oldTerminalId = panel.activeTab?.rustTerminalId
        guard panel.setActiveTab(tabId) else {
            return .failure(.tabNotFound(tabId))
        }
        let newTerminalId = panel.activeTab?.rustTerminalId

        // 发送 Tab Focus 事件，让插件决定是否清除装饰
        if let terminalId = newTerminalId {
            NotificationCenter.default.post(
                name: .tabDidFocus,
                object: nil,
                userInfo: ["terminal_id": terminalId]
            )
        }

        var result = CommandResult()
        if let id = newTerminalId {
            result.terminalsToActivate = [id]
        }
        if let oldId = oldTerminalId, oldId != newTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        result.effects = .viewChange
        return result
    }

    private func executeTabAdd(panelId: UUID) -> CommandResult {
        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        // 创建新 Tab（终端由 Coordinator 创建）
        let newTab = Tab(
            tabId: UUID(),
            title: Self.defaultTabTitle,
            content: .terminal(TerminalTab(tabId: UUID(), title: Self.defaultTabTitle))
        )
        panel.addTab(newTab)

        // 切换到新 Tab
        let oldTerminalId = panel.activeTab?.rustTerminalId
        _ = panel.setActiveTab(newTab.tabId)

        var result = CommandResult()
        result.terminalsToCreate = [TerminalSpec(tabId: newTab.tabId)]
        if let oldId = oldTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        // 新终端激活由 Coordinator 在创建后处理
        result.effects = .stateChange
        return result
    }

    private func executeTabClose(panelId: UUID, scope: CloseScope) -> CommandResult {
        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        let tabsToClose: [Tab]
        switch scope {
        case .single(let tabId):
            guard let tab = panel.tabs.first(where: { $0.tabId == tabId }) else {
                return .failure(.tabNotFound(tabId))
            }
            // 不能关闭最后一个 Tab
            if panel.tabs.count == 1 {
                return .failure(.cannotCloseLastTab)
            }
            tabsToClose = [tab]

        case .others(let keepId):
            tabsToClose = panel.tabs.filter { $0.tabId != keepId }

        case .left(let refId):
            guard let refIndex = panel.tabs.firstIndex(where: { $0.tabId == refId }) else {
                return .failure(.tabNotFound(refId))
            }
            tabsToClose = Array(panel.tabs.prefix(refIndex))

        case .right(let refId):
            guard let refIndex = panel.tabs.firstIndex(where: { $0.tabId == refId }) else {
                return .failure(.tabNotFound(refId))
            }
            tabsToClose = Array(panel.tabs.suffix(from: refIndex + 1))
        }

        // 收集需要关闭的终端
        var terminalsToClose: [Int] = []
        for tab in tabsToClose {
            if let terminalId = tab.rustTerminalId {
                terminalsToClose.append(terminalId)
            }
            _ = panel.closeTab(tab.tabId)
        }

        var result = CommandResult()
        result.terminalsToClose = terminalsToClose
        if let id = panel.activeTab?.rustTerminalId {
            result.terminalsToActivate = [id]
        }
        result.effects = .stateChange
        return result
    }

    private func executeTabReorder(panelId: UUID, order: [UUID]) -> CommandResult {
        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        guard panel.reorderTabs(order) else {
            return CommandResult(success: false)
        }

        var result = CommandResult()
        result.effects = .stateChange
        return result
    }

    private func executeTabAddWithConfig(panelId: UUID, config: TabConfig) -> CommandResult {
        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        // 创建新 Tab（终端由 Coordinator 创建）
        let newTab = Tab(
            tabId: UUID(),
            title: Self.defaultTabTitle,
            content: .terminal(TerminalTab(tabId: UUID(), title: Self.defaultTabTitle))
        )
        panel.addTab(newTab)

        // 切换到新 Tab
        let oldTerminalId = panel.activeTab?.rustTerminalId
        _ = panel.setActiveTab(newTab.tabId)

        var result = CommandResult()
        result.createdTabId = newTab.tabId
        result.terminalsToCreate = [TerminalSpec(
            tabId: newTab.tabId,
            cwd: config.cwd,
            command: config.command,
            env: config.env
        )]
        if let oldId = oldTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        // 新终端激活由 Coordinator 在创建后处理
        result.effects = .stateChange
        return result
    }

    // MARK: - Panel 移除后的激活处理

    /// Panel 移除后，激活下一个可用 Panel
    ///
    /// 统一处理 Panel 被移除后的激活逻辑：
    /// 1. 如果被移除的 Panel 是当前激活的 Panel，切换到下一个 Panel
    /// 2. 返回需要激活的终端 ID
    ///
    /// - Parameters:
    ///   - removedPanelId: 被移除的 Panel ID
    ///   - page: 当前 Page
    /// - Returns: 需要激活的终端 ID（如果有）
    private func activateNextPanelAfterRemoval(removedPanelId: UUID, page: Page) -> Int? {
        // 只有当被移除的 Panel 是当前激活的 Panel 时才需要切换
        guard active.panelId == removedPanelId else {
            return nil
        }

        // 找到下一个可用的 Panel
        guard let nextPanel = page.allPanels.first else {
            return nil
        }

        // 切换到下一个 Panel
        active.setPanel(nextPanel.panelId)

        // 返回需要激活的终端
        return nextPanel.activeTab?.rustTerminalId
    }

    private func executeTabRemove(tabId: UUID, panelId: UUID, closeTerminal: Bool) -> CommandResult {
        guard let page = active.page else {
            return .failure(.noActivePage)
        }

        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        guard let tab = panel.tabs.first(where: { $0.tabId == tabId }) else {
            return .failure(.tabNotFound(tabId))
        }

        var result = CommandResult()

        // 收集需要关闭的终端（仅当 closeTerminal=true 时）
        if closeTerminal, let terminalId = tab.rustTerminalId {
            result.terminalsToClose = [terminalId]
        }

        // 如果是最后一个 Tab，移除整个 Panel
        if panel.tabCount == 1 {
            // 移除 Panel（现在允许移除根节点）
            _ = removePanel(panelId)
            result.removedPanelId = panelId

            // 冒泡检查：Page 是否变空
            if page.isEmpty {
                // Page 变空，标记需要移除（由 Coordinator 执行）
                result.removedPageId = page.pageId
            } else {
                // Page 还有其他 Panel，使用统一的激活逻辑
                if let terminalId = activateNextPanelAfterRemoval(removedPanelId: panelId, page: page) {
                    result.terminalsToActivate = [terminalId]
                }
            }
        } else {
            // 从 Panel 移除 Tab
            _ = panel.closeTab(tabId)

            // 新激活 Tab 的终端需要设为 Active 模式
            if let terminalId = panel.activeTab?.rustTerminalId {
                result.terminalsToActivate = [terminalId]
            }
        }

        result.effects = .stateChange
        return result
    }

    private func executeTabMove(tabId: UUID, from sourcePanelId: UUID, to target: MoveTarget) -> CommandResult {
        guard let sourcePanel = getPanel(sourcePanelId) else {
            return .failure(.panelNotFound(sourcePanelId))
        }
        guard let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return .failure(.tabNotFound(tabId))
        }

        switch target {
        case .existingPanel(let targetPanelId):
            guard let targetPanel = getPanel(targetPanelId) else {
                return .failure(.panelNotFound(targetPanelId))
            }

            var result = CommandResult()

            // 1. 添加到目标 Panel 并设为激活
            targetPanel.addTab(tab)
            _ = targetPanel.setActiveTab(tabId)

            // 2. 从源 Panel 移除
            if sourcePanel.tabCount > 1 {
                // 源 Panel 有多个 Tab，只移除这一个
                _ = sourcePanel.closeTab(tabId)
            } else {
                // 源 Panel 只有这一个 Tab，移除整个 Panel
                // 注意：此时 sourcePanel.tabs 仍包含 tab 引用，但 tab 已添加到 target
                // 移除 Panel 不会关闭已转移的终端
                _ = removePanel(sourcePanelId)
                // 标记需要处理的副作用（如搜索状态清理）
                result.removedPanelId = sourcePanelId
            }

            // 3. 设置目标 Panel 为激活
            active.setPanel(targetPanelId)

            if let id = tab.rustTerminalId {
                result.terminalsToActivate = [id]
                result.focusedTerminalId = id
            }
            result.effects = .stateChange
            return result

        case .splitNew:
            // splitNew 需要 layoutCalculator（基础设施依赖）
            // 由 Coordinator 层处理，不走命令管道
            return CommandResult(success: false)
        }
    }

    // MARK: - Panel Commands

    private func executePanel(_ command: PanelCommand) -> CommandResult {
        switch command {
        case .split(let panelId, let direction, let cwd):
            return executePanelSplit(panelId: panelId, direction: direction, cwd: cwd)
        case .close(let panelId):
            return executePanelClose(panelId: panelId)
        case .setActive(let panelId):
            return executePanelSetActive(panelId: panelId)
        }
    }

    private func executePanelSplit(panelId: UUID, direction: SplitDirection, cwd: String?) -> CommandResult {
        // 使用默认的布局计算器
        let layoutCalculator = BinaryTreeLayoutCalculator()

        guard let newPanelId = splitPanel(
            panelId: panelId,
            direction: direction,
            layoutCalculator: layoutCalculator
        ) else {
            return .failure(.panelNotFound(panelId))
        }

        // 查找新创建的 Panel 及其默认 Tab
        guard let newPanel = getPanel(newPanelId),
              let newTab = newPanel.tabs.first else {
            return CommandResult(success: false)
        }

        // 停用旧终端
        let oldTerminalId = active.terminalId

        // 激活新 Panel
        active.setPanel(newPanelId)

        var result = CommandResult()
        result.terminalsToCreate = [TerminalSpec(tabId: newTab.tabId, cwd: cwd)]
        if let oldId = oldTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        result.effects = .layoutChange
        return result
    }

    private func executePanelClose(panelId: UUID) -> CommandResult {
        guard let page = active.page else {
            return .failure(.noActivePage)
        }

        // 不能关闭最后一个 Panel
        if page.panelCount == 1 {
            return .failure(.cannotCloseLastPanel)
        }

        guard let panel = getPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        // 收集需要关闭的终端
        var terminalsToClose: [Int] = []
        for tab in panel.tabs {
            if let terminalId = tab.rustTerminalId {
                terminalsToClose.append(terminalId)
            }
        }

        // 移除 Panel
        guard removePanel(panelId) else {
            return CommandResult(success: false)
        }

        var result = CommandResult()
        result.terminalsToClose = terminalsToClose
        result.removedPanelId = panelId

        // 使用统一的激活逻辑
        if let terminalId = activateNextPanelAfterRemoval(removedPanelId: panelId, page: page) {
            result.terminalsToActivate = [terminalId]
        }
        result.effects = .layoutChange
        return result
    }

    /// 执行 Panel 导航（需要 containerBounds）
    ///
    /// 由 Coordinator 调用，因为需要 UI 层的 containerBounds
    func navigatePanel(direction: NavigationDirection, containerBounds: CGRect) -> CommandResult {
        guard let page = active.page,
              let currentPanelId = active.panelId else {
            return .failure(.noActivePanel)
        }

        guard let targetPanelId = PanelNavigationService.findNearestPanel(
            from: currentPanelId,
            direction: direction,
            in: page,
            containerBounds: containerBounds
        ) else {
            // 没有找到相邻 Panel，不是错误，只是没有可导航的目标
            return CommandResult()
        }

        // 切换到目标 Panel
        let oldTerminalId = active.terminalId
        active.setPanel(targetPanelId)
        let newTerminalId = active.terminalId

        var result = CommandResult()
        if let id = newTerminalId {
            result.terminalsToActivate = [id]
            result.focusedTerminalId = id
        }
        if let oldId = oldTerminalId, oldId != newTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        result.effects = .viewChange
        return result
    }

    private func executePanelSetActive(panelId: UUID) -> CommandResult {
        guard let page = active.page else {
            return .failure(.noActivePage)
        }
        guard page.containsPanel(panelId) else {
            return .failure(.panelNotFound(panelId))
        }

        let oldTerminalId = active.terminalId
        active.setPanel(panelId)
        let newTerminalId = active.terminalId

        // 发送 Tab Focus 事件，让插件决定是否清除装饰
        if let terminalId = newTerminalId {
            NotificationCenter.default.post(
                name: .tabDidFocus,
                object: nil,
                userInfo: ["terminal_id": terminalId]
            )
        }

        var result = CommandResult()
        if let id = newTerminalId {
            result.terminalsToActivate = [id]
        }
        if let oldId = oldTerminalId, oldId != newTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        result.effects = .viewChange
        return result
    }

    // MARK: - Page Commands

    private func executePage(_ command: PageCommand) -> CommandResult {
        switch command {
        case .switch(let target):
            return executePageSwitch(target: target)
        case .create(let title, let cwd):
            return executePageCreate(title: title, cwd: cwd)
        case .close(let scope):
            return executePageClose(scope: scope)
        case .reorder(let order):
            return executePageReorder(order: order)
        case .move(let pageId, let beforeId):
            return executePageMove(pageId: pageId, before: beforeId)
        case .moveToEnd(let pageId):
            return executePageMoveToEnd(pageId: pageId)
        }
    }

    private func executePageSwitch(target: PageTarget) -> CommandResult {
        // 收集当前 Page 所有终端（需要停用）
        var terminalsToDeactivate: [Int] = []
        if let currentPage = active.page {
            for panel in currentPage.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        terminalsToDeactivate.append(terminalId)
                    }
                }
            }
        }

        let success: Bool
        switch target {
        case .specific(let pageId):
            success = pages.switchTo(pageId)
        case .next:
            success = pages.switchToNext()
        case .previous:
            success = pages.switchToPrevious()
        }

        guard success else {
            return CommandResult(success: false)
        }

        // 激活新 Page 所有 Panel 的激活终端
        var terminalsToActivate: [Int] = []
        if let newPage = active.page {
            for panel in newPage.allPanels {
                if let terminalId = panel.activeTab?.rustTerminalId {
                    terminalsToActivate.append(terminalId)
                }
            }
        }

        // 发送 Tab Focus 事件，让插件决定是否清除装饰
        // 只发送当前激活 Panel 的激活 Tab（用户实际聚焦的 Tab）
        if let focusedTerminalId = active.terminalId {
            NotificationCenter.default.post(
                name: .tabDidFocus,
                object: nil,
                userInfo: ["terminal_id": focusedTerminalId]
            )
        }

        var result = CommandResult()
        result.terminalsToDeactivate = terminalsToDeactivate
        result.terminalsToActivate = terminalsToActivate
        result.effects = .layoutChange
        return result
    }

    private func executePageCreate(title: String?, cwd: String?) -> CommandResult {
        // 停用当前终端
        let oldTerminalId = active.terminalId

        let newPage = pages.create(title: title)

        // 切换到新 Page
        _ = pages.switchTo(newPage.pageId)

        // 新 Page 的第一个 Tab 需要创建终端
        let newTabId = newPage.allPanels.first?.activeTab?.tabId

        var result = CommandResult()
        if let tabId = newTabId {
            result.terminalsToCreate = [TerminalSpec(tabId: tabId, cwd: cwd)]
        }
        if let oldId = oldTerminalId {
            result.terminalsToDeactivate = [oldId]
        }
        result.effects = .layoutChange
        return result
    }

    private func executePageClose(scope: CloseScope) -> CommandResult {
        let pagesToClose: [Page]
        switch scope {
        case .single(let pageId):
            guard let page = pages.get(pageId) else {
                return .failure(.pageNotFound(pageId))
            }
            if pages.count == 1 {
                return .failure(.cannotCloseLastPage)
            }
            pagesToClose = [page]

        case .others(let keepId):
            pagesToClose = pages.all.filter { $0.pageId != keepId }

        case .left(let refId):
            guard let refIndex = pages.all.firstIndex(where: { $0.pageId == refId }) else {
                return .failure(.pageNotFound(refId))
            }
            pagesToClose = Array(pages.all.prefix(refIndex))

        case .right(let refId):
            guard let refIndex = pages.all.firstIndex(where: { $0.pageId == refId }) else {
                return .failure(.pageNotFound(refId))
            }
            pagesToClose = Array(pages.all.suffix(from: refIndex + 1))
        }

        // 收集需要关闭的终端
        var terminalsToClose: [Int] = []
        for page in pagesToClose {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        terminalsToClose.append(terminalId)
                    }
                }
            }
            _ = pages.close(page.pageId)
        }

        // 激活新 Page 所有 Panel 的激活终端
        var terminalsToActivate: [Int] = []
        if let newPage = active.page {
            for panel in newPage.allPanels {
                if let terminalId = panel.activeTab?.rustTerminalId {
                    terminalsToActivate.append(terminalId)
                }
            }
        }

        var result = CommandResult()
        result.terminalsToClose = terminalsToClose
        result.terminalsToActivate = terminalsToActivate
        result.effects = .layoutChange
        return result
    }

    private func executePageReorder(order: [UUID]) -> CommandResult {
        guard pages.reorder(order) else {
            return CommandResult(success: false)
        }

        var result = CommandResult()
        result.effects = .stateChange
        return result
    }

    private func executePageMove(pageId: UUID, before targetId: UUID) -> CommandResult {
        guard pages.move(pageId, before: targetId) != nil else {
            return CommandResult(success: false)
        }

        var result = CommandResult()
        result.effects = .stateChange
        return result
    }

    private func executePageMoveToEnd(pageId: UUID) -> CommandResult {
        guard pages.moveToEnd(pageId) != nil else {
            return CommandResult(success: false)
        }

        var result = CommandResult()
        result.effects = .stateChange
        return result
    }

    // MARK: - Window Commands

    private func executeWindow(_ command: WindowOnlyCommand) -> CommandResult {
        switch command {
        case .smartClose:
            return executeSmartClose()
        }
    }

    private func executeSmartClose() -> CommandResult {
        guard let page = active.page,
              let panel = active.panel else {
            return .failure(.noActivePanel)
        }

        // 层级决策：Tab → Panel → Page → Window
        if panel.tabs.count > 1 {
            // 关闭当前 Tab
            guard let activeTabId = panel.activeTab?.tabId else {
                return CommandResult(success: false)
            }
            return executeTabClose(panelId: panel.panelId, scope: .single(activeTabId))

        } else if page.panelCount > 1 {
            // 关闭当前 Panel
            return executePanelClose(panelId: panel.panelId)

        } else if pages.count > 1 {
            // 关闭当前 Page
            return executePageClose(scope: .single(page.pageId))

        } else {
            // 需要关闭窗口，返回特殊标记
            var result = CommandResult()
            result.effects.updateTrigger = true  // 用作 shouldCloseWindow 标记
            return result
        }
    }
}
