//
//  PanelNode.swift
//  PanelLayoutKit
//
//  Panel 节点（Tab 容器）
//

import Foundation

/// Panel 节点
///
/// 表示一个 Panel（Tab 容器）。
/// 在 Golden Layout 中对应 Stack。
public struct PanelNode: Codable, Equatable, Hashable, Identifiable {
    /// Panel 唯一标识符
    public let id: UUID

    /// Panel 包含的所有 Tab
    public var tabs: [TabNode]

    /// 当前激活的 Tab 索引
    public var activeTabIndex: Int

    /// 创建一个新的 Panel 节点
    ///
    /// - Parameters:
    ///   - id: Panel 唯一标识符
    ///   - tabs: Panel 包含的 Tab 列表
    ///   - activeTabIndex: 激活的 Tab 索引（默认为 0）
    public init(id: UUID = UUID(), tabs: [TabNode] = [], activeTabIndex: Int = 0) {
        self.id = id
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
    }

    /// 获取当前激活的 Tab
    public var activeTab: TabNode? {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else {
            return nil
        }
        return tabs[activeTabIndex]
    }

    /// 检查 Panel 是否为空（不包含任何 Tab）
    public var isEmpty: Bool {
        return tabs.isEmpty
    }

    /// 添加一个新的 Tab
    ///
    /// - Parameters:
    ///   - tab: 要添加的 Tab
    ///   - index: 插入位置（nil 表示添加到末尾）
    /// - Returns: 新的 Panel 节点
    public func addingTab(_ tab: TabNode, at index: Int? = nil) -> PanelNode {
        var newTabs = tabs
        let insertIndex = index ?? tabs.count

        // 边界检查：确保 insertIndex 在有效范围内 [0...count]
        let safeInsertIndex = max(0, min(insertIndex, newTabs.count))
        newTabs.insert(tab, at: safeInsertIndex)

        return PanelNode(
            id: id,
            tabs: newTabs,
            activeTabIndex: safeInsertIndex
        )
    }

    /// 移除一个 Tab
    ///
    /// - Parameter tabId: 要移除的 Tab ID
    /// - Returns: 新的 Panel 节点（如果移除后为空则返回 nil）
    public func removingTab(_ tabId: UUID) -> PanelNode? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else {
            // 找不到 Tab，返回原 Panel（没有变化）
            return self
        }

        var newTabs = tabs
        newTabs.remove(at: index)

        // 如果移除后为空，返回 nil
        guard !newTabs.isEmpty else {
            return nil
        }

        // 调整激活索引
        let newActiveIndex: Int
        if activeTabIndex == index {
            // 如果移除的是激活的 Tab，则激活相邻的 Tab
            newActiveIndex = index == 0 ? 0 : index - 1
        } else if activeTabIndex > index {
            // 如果移除的 Tab 在激活 Tab 之前，需要调整索引
            newActiveIndex = activeTabIndex - 1
        } else {
            newActiveIndex = activeTabIndex
        }

        return PanelNode(
            id: id,
            tabs: newTabs,
            activeTabIndex: newActiveIndex
        )
    }
}
