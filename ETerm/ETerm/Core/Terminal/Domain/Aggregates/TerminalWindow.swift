//
//  TerminalWindow.swift
//  ETerm
//
//  领域聚合根 - 终端窗口

import Foundation
import CoreGraphics
import SwiftUI

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
    private(set) var pages: [Page]
    private(set) var activeFocus: ActiveFocus?

    /// 记录每个 Page 上次激活的 Panel ID（用于切换 Page 时恢复）
    private var lastPanelIdByPage: [UUID: UUID] = [:]

    /// 便捷访问：当前激活的 Page ID
    var activePageId: UUID? { activeFocus?.pageId }

    /// 便捷访问：当前激活的 Panel ID
    var activePanelId: UUID? { activeFocus?.panelId }

    // MARK: - Initialization

    init(initialPanel: EditorPanel) {
        self.windowId = UUID()

        // 创建初始 Page
        let initialPage = Page(title: "Page 1", initialPanel: initialPanel)
        self.pages = [initialPage]
        self.activeFocus = ActiveFocus(pageId: initialPage.pageId, panelId: initialPanel.panelId)
    }

    /// 使用已有的 Page 初始化（用于恢复 Session）
    init(initialPage: Page) {
        self.windowId = UUID()
        self.pages = [initialPage]
        // 使用第一个 Panel 作为初始 focus（如果存在）
        if let initialPanelId = initialPage.allPanels.first?.panelId {
            self.activeFocus = ActiveFocus(pageId: initialPage.pageId, panelId: initialPanelId)
        } else {
            // Plugin Page 没有 Panel，activeFocus 暂时为 nil
            self.activeFocus = nil
        }
    }

    // MARK: - Focus Management

    /// 设置激活的 Panel（在当前 Page 内切换 Panel）
    func setActivePanel(_ panelId: UUID) {
        guard let pageId = activeFocus?.pageId,
              let page = pages.first(where: { $0.pageId == pageId }),
              page.containsPanel(panelId) else {
            return
        }
        activeFocus = ActiveFocus(pageId: pageId, panelId: panelId)
        lastPanelIdByPage[pageId] = panelId
    }

    /// 设置完整的 activeFocus（用于恢复 Session）
    func setActiveFocus(_ focus: ActiveFocus) {
        activeFocus = focus
        lastPanelIdByPage[focus.pageId] = focus.panelId
    }

    /// 获取指定 Page 的上次激活 Panel ID（用于 Session 保存）
    func getActivePanelId(for pageId: UUID) -> UUID? {
        // 如果是当前激活的 Page，返回当前 activePanelId
        if activeFocus?.pageId == pageId {
            return activeFocus?.panelId
        }
        // 否则返回记录的上次 panelId
        return lastPanelIdByPage[pageId]
    }

    // MARK: - Active Page Access

    /// 获取当前激活的 Page
    var activePage: Page? {
        guard let activePageId = activePageId else { return nil }
        return pages.first { $0.pageId == activePageId }
    }

    // MARK: - Tab Creation (统一入口)

    /// 默认 Tab 标题
    private static let defaultTabTitle = "终端"

    /// 创建默认 Tab（静态工厂方法）
    ///
    /// 用于创建新窗口时的初始 Tab，此时还没有 TerminalWindow 实例
    static func makeDefaultTab(rustTerminalId: Int = 0) -> TerminalTab {
        return TerminalTab(
            tabId: UUID(),
            title: defaultTabTitle,
            rustTerminalId: rustTerminalId
        )
    }

    /// 在指定 Panel 中创建新 Tab
    ///
    /// - Parameters:
    ///   - panelId: 目标 Panel ID
    ///   - rustTerminalId: Rust 终端 ID
    /// - Returns: 创建的 Tab，如果 Panel 不存在返回 nil
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

    /// 生成 Tab 标题（保留兼容性）
    func generateNextTabTitle() -> String {
        return Self.defaultTabTitle
    }

    // MARK: - Page Management

    /// 创建新 Page
    ///
    /// - Parameter title: 页面标题（可选，默认自动生成）
    /// - Returns: 新创建的 Page
    @discardableResult
    func createPage(title: String? = nil) -> Page {
        // 生成默认标题
        let pageTitle = title ?? "Page \(pages.count + 1)"

        // 创建默认 Tab 和 Panel
        let initialTab = TerminalTab(tabId: UUID(), title: generateNextTabTitle())
        let initialPanel = EditorPanel(initialTab: initialTab)

        // 创建 Page
        let newPage = Page(title: pageTitle, initialPanel: initialPanel)
        pages.append(newPage)

        return newPage
    }

    /// 创建插件 Page
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - title: 页面标题
    ///   - viewProvider: 视图提供者
    /// - Returns: 新创建的 Page
    @discardableResult
    func addPluginPage(pluginId: String, title: String, viewProvider: @escaping () -> AnyView) -> Page {
        let newPage = Page.createPluginPage(title: title, pluginId: pluginId, viewProvider: viewProvider)
        pages.append(newPage)
        return newPage
    }

    /// 查找指定插件的 PluginPage
    ///
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 找到的 Page（如果存在）
    func findPluginPage(pluginId: String) -> Page? {
        return pages.first { page in
            if case .plugin(let id, _) = page.content {
                return id == pluginId
            }
            return false
        }
    }

    /// 打开或切换到插件页面
    ///
    /// 如果该插件的页面已存在，直接返回；否则创建新页面
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - title: 页面标题
    ///   - viewProvider: 视图提供者
    /// - Returns: 插件页面（已有或新创建）
    @discardableResult
    func openOrSwitchToPluginPage(pluginId: String, title: String, viewProvider: @escaping () -> AnyView) -> Page {
        // 检查是否已有该插件的页面
        if let existingPage = findPluginPage(pluginId: pluginId) {
            return existingPage
        }

        // 创建新页面
        return addPluginPage(pluginId: pluginId, title: title, viewProvider: viewProvider)
    }

    /// 切换到指定 Page
    ///
    /// - Parameter pageId: 目标 Page ID
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToPage(_ pageId: UUID) -> Bool {
        guard let newPage = pages.first(where: { $0.pageId == pageId }) else {
            return false
        }

        // 保存当前 Page 的 panelId
        if let currentPageId = activeFocus?.pageId, let currentPanelId = activeFocus?.panelId {
            lastPanelIdByPage[currentPageId] = currentPanelId
        }

        // 恢复目标 Page 的 panelId，验证其仍然存在
        var targetPanelId: UUID?
        if let lastPanelId = lastPanelIdByPage[pageId], newPage.containsPanel(lastPanelId) {
            targetPanelId = lastPanelId
        } else {
            targetPanelId = newPage.allPanels.first?.panelId
        }

        // 只有当 panelId 有效时才设置 activeFocus（Plugin Page 可能没有 Panel）
        if let panelId = targetPanelId {
            activeFocus = ActiveFocus(pageId: pageId, panelId: panelId)
        } else {
            // Plugin Page：只更新 pageId，保持 panelId 为之前的值（或 nil）
            activeFocus = ActiveFocus(pageId: pageId, panelId: activeFocus?.panelId ?? UUID())
        }
        return true
    }

    /// 切换到下一个 Page
    ///
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToNextPage() -> Bool {
        guard let currentId = activePageId,
              let currentIndex = pages.firstIndex(where: { $0.pageId == currentId }),
              pages.count > 1 else {
            return false
        }

        let nextIndex = (currentIndex + 1) % pages.count
        return switchToPage(pages[nextIndex].pageId)
    }

    /// 切换到上一个 Page
    ///
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToPreviousPage() -> Bool {
        guard let currentId = activePageId,
              let currentIndex = pages.firstIndex(where: { $0.pageId == currentId }),
              pages.count > 1 else {
            return false
        }

        let previousIndex = (currentIndex - 1 + pages.count) % pages.count
        return switchToPage(pages[previousIndex].pageId)
    }

    /// 关闭指定 Page
    ///
    /// - Parameter pageId: 要关闭的 Page ID
    /// - Returns: 是否成功关闭
    @discardableResult
    func closePage(_ pageId: UUID) -> Bool {
        // 至少保留一个 Page
        guard pages.count > 1 else {
            return false
        }

        guard let index = pages.firstIndex(where: { $0.pageId == pageId }) else {
            return false
        }

        pages.remove(at: index)
        lastPanelIdByPage.removeValue(forKey: pageId)

        // 如果关闭的是当前 Page，切换到相邻 Page
        if activePageId == pageId {
            let newIndex = min(index, pages.count - 1)
            _ = switchToPage(pages[newIndex].pageId)
        }

        return true
    }

    /// 强制移除 Page（用于跨窗口移动，允许移除最后一个 Page）
    ///
    /// - Parameter pageId: 要移除的 Page ID
    /// - Returns: 被移除的 Page，失败返回 nil
    func forceRemovePage(_ pageId: UUID) -> Page? {
        guard let index = pages.firstIndex(where: { $0.pageId == pageId }) else {
            return nil
        }

        let page = pages.remove(at: index)
        lastPanelIdByPage.removeValue(forKey: pageId)

        // 如果还有其他 Page，更新激活状态
        if !pages.isEmpty && activePageId == pageId {
            let newIndex = min(index, pages.count - 1)
            _ = switchToPage(pages[newIndex].pageId)
        }

        return page
    }

    /// 重命名 Page
    ///
    /// - Parameters:
    ///   - pageId: Page ID
    ///   - newTitle: 新标题
    /// - Returns: 是否成功
    @discardableResult
    func renamePage(_ pageId: UUID, to newTitle: String) -> Bool {
        guard let page = pages.first(where: { $0.pageId == pageId }) else {
            return false
        }
        page.rename(to: newTitle)
        return true
    }

    /// 重新排序 Pages
    ///
    /// - Parameter pageIds: 新的 Page ID 顺序
    /// - Returns: 是否成功
    @discardableResult
    func reorderPages(_ pageIds: [UUID]) -> Bool {
        // 验证 pageIds 是否与当前 pages 匹配
        guard Set(pageIds) == Set(pages.map { $0.pageId }),
              pageIds.count == pages.count else {
            return false
        }

        // 根据新顺序重新排列 pages
        var reorderedPages: [Page] = []
        for pageId in pageIds {
            if let page = pages.first(where: { $0.pageId == pageId }) {
                reorderedPages.append(page)
            }
        }

        pages = reorderedPages
        return true
    }

    /// 获取 Page 数量
    var pageCount: Int {
        return pages.count
    }

    /// 添加已有的 Page（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - page: 要添加的 Page
    ///   - insertBefore: 插入到指定 Page 之前（nil 表示插入到末尾）
    func addExistingPage(_ page: Page, insertBefore targetPageId: UUID? = nil) {
        if let targetId = targetPageId,
           let targetIndex = pages.firstIndex(where: { $0.pageId == targetId }) {
            // 插入到指定位置
            pages.insert(page, at: targetIndex)
        } else {
            // 添加到末尾
            pages.append(page)
        }
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
        guard let page = activePage else {
            return nil
        }

        // 检查 Panel 是否存在
        guard page.getPanel(panelId) != nil else {
            return nil
        }

        // 创建新 Panel（包含一个默认 Tab，使用全局唯一标题）
        let newPanel = EditorPanel(
            initialTab: TerminalTab(tabId: UUID(), title: generateNextTabTitle())
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
        guard let page = activePage else {
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
        return activePage?.getPanel(panelId)
    }

    /// 获取所有 Panel（在当前 Page 中）
    var allPanels: [EditorPanel] {
        return activePage?.allPanels ?? []
    }

    /// Panel 数量（在当前 Page 中）
    var panelCount: Int {
        return activePage?.panelCount ?? 0
    }

    /// 获取所有 Panel ID（在当前 Page 中）
    var allPanelIds: [UUID] {
        return activePage?.allPanelIds ?? []
    }

    /// 获取当前 Page 的 rootLayout
    var rootLayout: PanelLayout {
        return activePage?.rootLayout ?? .leaf(panelId: UUID())
    }

    // MARK: - Rendering

    /// 获取所有需要渲染的 Tab（新架构）
    func getActiveTabRenderables(
        containerBounds: CGRect,
        headerHeight: CGFloat
    ) -> [TabRenderable] {
        return activePage?.getActiveTabRenderables(
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
        return activePage?.containsPanel(panelId) ?? false
    }

    /// 更新分隔线比例（在当前 Page 中）
    func updateDividerRatio(path: [Int], newRatio: CGFloat) {
        activePage?.updateDividerRatio(path: path, newRatio: newRatio)
    }

    /// 移除指定 Panel（在当前 Page 中）
    func removePanel(_ panelId: UUID) -> Bool {
        return activePage?.removePanel(panelId) ?? false
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
        guard let page = activePage else {
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
