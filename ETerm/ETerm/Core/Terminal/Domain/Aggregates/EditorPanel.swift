//
//  EditorPanel.swift
//  ETerm
//
//  领域聚合根 - 编辑器 Panel
//
//  重构说明（2025/12）：
//  - tabs 类型从 [TerminalTab] 改为 [Tab]
//  - 支持多种 Tab 内容类型（Terminal、View 等）
//  - 保留便捷方法兼容现有代码
//

import Foundation
import CoreGraphics

/// 编辑器 Panel
///
/// 管理多个 Tab，类似于 VSCode 的 Editor Panel
/// 支持多种 Tab 类型（Terminal、View 等）
final class EditorPanel {
    /// 内容区域内边距
    static let contentPadding: CGFloat = 4.0

    let panelId: UUID
    private(set) var tabs: [Tab]
    private(set) var activeTabId: UUID?

    /// Panel 在窗口中的位置和尺寸（由 TerminalWindow 更新）
    private(set) var bounds: CGRect = .zero

    // MARK: - Initialization

    /// 使用 Tab 初始化
    init(initialTab: Tab) {
        self.panelId = UUID()
        self.tabs = [initialTab]
        self.activeTabId = initialTab.tabId
        initialTab.activate()
    }

    /// 使用 TerminalTab 初始化（便捷方法）
    convenience init(initialTab terminalTab: TerminalTab) {
        let tab = Tab(
            tabId: terminalTab.tabId,
            title: terminalTab.title,
            content: .terminal(terminalTab)
        )
        self.init(initialTab: tab)
    }

    // MARK: - Tab Management

    /// 添加新 Tab
    func addTab(_ tab: Tab) {
        tabs.append(tab)
    }

    /// 添加 TerminalTab（便捷方法）
    func addTab(_ terminalTab: TerminalTab) {
        let tab = Tab(
            tabId: terminalTab.tabId,
            title: terminalTab.title,
            content: .terminal(terminalTab)
        )
        tabs.append(tab)
    }

    /// 切换到指定 Tab
    func switchToTab(_ tabId: UUID) -> Bool {
        guard tabs.contains(where: { $0.tabId == tabId }) else {
            return false
        }

        // 取消激活当前 Tab
        if let currentTabId = activeTabId,
           let currentTab = tabs.first(where: { $0.tabId == currentTabId }) {
            currentTab.deactivate()
        }

        // 激活新 Tab
        if let newTab = tabs.first(where: { $0.tabId == tabId }) {
            newTab.activate()
            activeTabId = tabId
            return true
        }

        return false
    }

    /// 关闭指定 Tab
    func closeTab(_ tabId: UUID) -> Bool {
        guard tabs.count > 1 else {
            // 至少保留一个 Tab
            return false
        }

        guard let index = tabs.firstIndex(where: { $0.tabId == tabId }) else {
            return false
        }

        tabs.remove(at: index)

        // 如果关闭的是激活的 Tab，切换到第一个 Tab
        if activeTabId == tabId {
            if let firstTab = tabs.first {
                switchToTab(firstTab.tabId)
            }
        }

        return true
    }

    /// 获取激活的 Tab
    var activeTab: Tab? {
        guard let activeTabId = activeTabId else { return nil }
        return tabs.first(where: { $0.tabId == activeTabId })
    }

    /// Tab 数量
    var tabCount: Int {
        tabs.count
    }

    /// 重新排序 Tabs
    ///
    /// - Parameter tabIds: 新的 Tab ID 顺序
    /// - Returns: 是否成功
    func reorderTabs(_ tabIds: [UUID]) -> Bool {
        // 验证 ID 列表与当前 tabs 一致
        guard tabIds.count == tabs.count,
              Set(tabIds) == Set(tabs.map { $0.tabId }) else {
            return false
        }

        // 按新顺序重新排列 tabs
        var newTabs: [Tab] = []
        for tabId in tabIds {
            if let tab = tabs.first(where: { $0.tabId == tabId }) {
                newTabs.append(tab)
            }
        }

        tabs = newTabs
        return true
    }

    // MARK: - Layout Management

    /// 更新 Panel 的位置和尺寸（由 TerminalWindow 调用）
    func updateBounds(_ newBounds: CGRect) {
        self.bounds = newBounds
    }

    // MARK: - Rendering

    /// 获取激活的 Tab 用于渲染
    ///
    /// - Parameter headerHeight: Tab Bar 的高度
    /// - Returns: TabRenderable 如果有激活的 Tab
    func getActiveTabRenderable(headerHeight: CGFloat) -> TabRenderable? {
        guard let activeTab = activeTab else {
            return nil
        }

        let contentBounds = calculateContentBounds(headerHeight: headerHeight)

        // 根据 Tab 内容类型返回对应的 Renderable
        switch activeTab.content {
        case .terminal(let terminalContent):
            if let terminalId = terminalContent.rustTerminalId {
                return .terminal(terminalId: terminalId, bounds: contentBounds)
            }
            return nil

        case .view(let viewContent):
            return .view(viewId: viewContent.viewId, bounds: contentBounds)
        }
    }

    /// 获取激活的 Tab 用于渲染（兼容旧 API）
    ///
    /// - Parameter headerHeight: Tab Bar 的高度
    /// - Returns: (terminalId, contentBounds) 如果有激活的 Tab
    @available(*, deprecated, message: "Use getActiveTabRenderable instead")
    func getActiveTabForRendering(headerHeight: CGFloat) -> (Int, CGRect)? {
        guard let renderable = getActiveTabRenderable(headerHeight: headerHeight),
              case .terminal(let terminalId, let bounds) = renderable else {
            return nil
        }
        return (terminalId, bounds)
    }

    /// 计算内容区域 bounds
    private func calculateContentBounds(headerHeight: CGFloat) -> CGRect {
        let padding = Self.contentPadding
        return CGRect(
            x: bounds.origin.x + padding,
            y: bounds.origin.y + padding,
            width: bounds.width - padding * 2,
            height: bounds.height - headerHeight - padding * 2
        )
    }

    /// 设置激活的 Tab（替代 switchToTab，提供更清晰的语义）
    func setActiveTab(_ tabId: UUID) -> Bool {
        return switchToTab(tabId)
    }

    // MARK: - 终端便捷方法（兼容现有代码）

    /// 获取激活的终端内容
    ///
    /// 便捷方法，用于需要终端特有属性的场景
    var activeTerminalContent: TerminalTabContent? {
        return activeTab?.terminalContent
    }

    /// 获取所有 Tab 的简化信息（用于 UI 显示）
    var tabInfos: [(id: UUID, title: String, isTerminal: Bool)] {
        tabs.map { (id: $0.tabId, title: $0.title, isTerminal: $0.isTerminal) }
    }
}

// MARK: - Equatable

extension EditorPanel: Equatable {
    static func == (lhs: EditorPanel, rhs: EditorPanel) -> Bool {
        lhs.panelId == rhs.panelId
    }
}

// MARK: - Hashable

extension EditorPanel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(panelId)
    }
}
