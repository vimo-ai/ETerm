//
//  TerminalWindow.swift
//  ETerm
//
//  领域聚合根 - 终端窗口

import Foundation
import CoreGraphics
import SwiftUI

/// 终端窗口
///
/// 管理整个窗口的 Page 和 Tab 编号
/// 这是窗口层级的聚合根，负责：
/// - 维护 Page 列表
/// - 管理全局 Tab 编号
/// - 协调 Page 切换
final class TerminalWindow {
    let windowId: UUID
    private(set) var pages: [Page]
    private(set) var activePageId: UUID?

    /// 下一个终端编号（全局唯一，跨所有 Page）
    private var nextTerminalNumber: Int = 1

    // MARK: - Initialization

    init(initialPanel: EditorPanel) {
        self.windowId = UUID()

        // 创建初始 Page
        let initialPage = Page(title: "Page 1", initialPanel: initialPanel)
        self.pages = [initialPage]
        self.activePageId = initialPage.pageId

        // 初始化计数器
        scanAndInitNextTerminalNumber()
    }

    /// 使用已有的 Page 初始化（用于恢复 Session）
    init(initialPage: Page) {
        self.windowId = UUID()
        self.pages = [initialPage]
        self.activePageId = initialPage.pageId

        // 初始化计数器
        scanAndInitNextTerminalNumber()
    }

    // MARK: - Active Page Access

    /// 获取当前激活的 Page
    var activePage: Page? {
        guard let activePageId = activePageId else { return nil }
        return pages.first { $0.pageId == activePageId }
    }

    // MARK: - Tab Title Generation

    /// 生成下一个 Tab 标题（全局唯一）
    func generateNextTabTitle() -> String {
        let title = "终端 \(nextTerminalNumber)"
        nextTerminalNumber += 1
        return title
    }

    /// 获取当前的终端计数器（用于保存Session）
    func getNextTerminalNumber() -> Int {
        return nextTerminalNumber
    }

    /// 设置终端计数器（用于恢复Session）
    func setNextTerminalNumber(_ number: Int) {
        nextTerminalNumber = number
        print("🔢 [TerminalWindow] Restored nextTerminalNumber: \(nextTerminalNumber)")
    }

    /// 扫描现有 Tab 初始化计数器
    ///
    /// 策略：找到所有已使用的编号，下次生成时使用最大编号+1
    /// 注意：这样会导致编号跳号（如关闭"终端 2"后，新建会得到"终端 4"）
    /// 这是自增ID的正常行为，确保编号不会重复
    private func scanAndInitNextTerminalNumber() {
        var maxNumber = 0
        for page in pages {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    // 尝试从 "终端 N" 格式中提取编号
                    // 如果 Tab 被重命名（如 "SSH Server"），则跳过
                    if let title = tab.title.components(separatedBy: " ").last,
                       let number = Int(title) {
                        maxNumber = max(maxNumber, number)
                    }
                }
            }
        }
        nextTerminalNumber = maxNumber + 1
        print("🔢 [TerminalWindow] Scanned terminal numbers, next will be: \(nextTerminalNumber)")
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
            print("🔄 [TerminalWindow] 切换到已有插件页面: \(title)")
            return existingPage
        }

        // 创建新页面
        print("➕ [TerminalWindow] 创建新插件页面: \(title)")
        return addPluginPage(pluginId: pluginId, title: title, viewProvider: viewProvider)
    }

    /// 切换到指定 Page
    ///
    /// - Parameter pageId: 目标 Page ID
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToPage(_ pageId: UUID) -> Bool {
        guard pages.contains(where: { $0.pageId == pageId }) else {
            return false
        }
        activePageId = pageId
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
        activePageId = pages[nextIndex].pageId
        return true
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
        activePageId = pages[previousIndex].pageId
        return true
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

        // 如果关闭的是当前 Page，切换到相邻 Page
        if activePageId == pageId {
            let newIndex = min(index, pages.count - 1)
            activePageId = pages[newIndex].pageId
        }

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
    /// - Parameter page: 要添加的 Page
    func addExistingPage(_ page: Page) {
        pages.append(page)
        // 重新扫描计数器以确保正确性
        scanAndInitNextTerminalNumber()
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
        existingTab: TerminalTab,
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

    /// 获取所有需要渲染的 Tab
    func getActiveTabsForRendering(
        containerBounds: CGRect,
        headerHeight: CGFloat
    ) -> [(UInt32, CGRect)] {
        return activePage?.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        ) ?? []
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
