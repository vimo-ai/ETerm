//
//  EditorPanel.swift
//  ETerm
//
//  领域聚合根 - 编辑器 Panel

import Foundation

/// 编辑器 Panel
///
/// 管理多个 Tab，类似于 VSCode 的 Editor Panel
final class EditorPanel {
    let panelId: UUID
    private(set) var tabs: [TerminalTab]
    private(set) var activeTabId: UUID?

    // MARK: - Initialization

    init(initialTab: TerminalTab) {
        self.panelId = UUID()
        self.tabs = [initialTab]
        self.activeTabId = initialTab.tabId
        initialTab.activate()
    }

    // MARK: - Tab Management

    /// 添加新 Tab
    func addTab(_ tab: TerminalTab) {
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
    var activeTab: TerminalTab? {
        guard let activeTabId = activeTabId else { return nil }
        return tabs.first(where: { $0.tabId == activeTabId })
    }

    /// Tab 数量
    var tabCount: Int {
        tabs.count
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
