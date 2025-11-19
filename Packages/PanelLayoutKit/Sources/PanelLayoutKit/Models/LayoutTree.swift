//
//  LayoutTree.swift
//  PanelLayoutKit
//
//  布局树
//

import Foundation
import CoreGraphics

/// 布局树
///
/// 使用递归枚举表示 Panel 的布局结构。
/// 类似于现有的 PanelLayout，但包含更多拖拽相关的功能。
public indirect enum LayoutTree: Codable, Equatable {
    /// 叶子节点：单个 Panel
    case panel(PanelNode)

    /// 分割节点：包含两个子树
    case split(
        direction: SplitDirection,
        first: LayoutTree,
        second: LayoutTree,
        ratio: CGFloat  // first 节点占用的比例（0.1 ~ 0.9）
    )

    // MARK: - 查询方法

    /// 查找包含指定 Tab 的 Panel
    ///
    /// - Parameter tabId: Tab 的 ID
    /// - Returns: 包含该 Tab 的 Panel，如果不存在则返回 nil
    public func findPanel(containingTab tabId: UUID) -> PanelNode? {
        switch self {
        case .panel(let panelNode):
            return panelNode.tabs.contains(where: { $0.id == tabId }) ? panelNode : nil

        case .split(_, let first, let second, _):
            return first.findPanel(containingTab: tabId) ?? second.findPanel(containingTab: tabId)
        }
    }

    /// 查找指定 ID 的 Panel
    ///
    /// - Parameter panelId: Panel 的 ID
    /// - Returns: 找到的 Panel，如果不存在则返回 nil
    public func findPanel(byId panelId: UUID) -> PanelNode? {
        switch self {
        case .panel(let panelNode):
            return panelNode.id == panelId ? panelNode : nil

        case .split(_, let first, let second, _):
            return first.findPanel(byId: panelId) ?? second.findPanel(byId: panelId)
        }
    }

    /// 获取所有 Panel
    ///
    /// - Returns: 布局树中的所有 Panel
    public func allPanels() -> [PanelNode] {
        switch self {
        case .panel(let panelNode):
            return [panelNode]

        case .split(_, let first, let second, _):
            return first.allPanels() + second.allPanels()
        }
    }

    /// 获取所有 Tab
    ///
    /// - Returns: 布局树中的所有 Tab
    public func allTabs() -> [TabNode] {
        return allPanels().flatMap { $0.tabs }
    }

    /// 检查是否包含指定的 Tab
    ///
    /// - Parameter tabId: Tab 的 ID
    /// - Returns: 如果包含返回 true
    public func containsTab(_ tabId: UUID) -> Bool {
        return findPanel(containingTab: tabId) != nil
    }

    // MARK: - 修改方法（返回新的不可变值）

    /// 替换指定的 Panel
    ///
    /// - Parameters:
    ///   - panelId: 要替换的 Panel ID
    ///   - newNode: 新的布局树节点
    /// - Returns: 新的布局树（如果未找到则返回原树）
    public func replacingPanel(_ panelId: UUID, with newNode: LayoutTree) -> LayoutTree {
        switch self {
        case .panel(let panelNode):
            return panelNode.id == panelId ? newNode : self

        case .split(let direction, let first, let second, let ratio):
            let newFirst = first.replacingPanel(panelId, with: newNode)
            let newSecond = second.replacingPanel(panelId, with: newNode)

            // 如果有子节点被替换，返回新的 split 节点
            if newFirst != first || newSecond != second {
                return .split(
                    direction: direction,
                    first: newFirst,
                    second: newSecond,
                    ratio: ratio
                )
            }

            return self
        }
    }

    /// 更新指定的 Panel
    ///
    /// - Parameters:
    ///   - panelId: Panel ID
    ///   - transform: 转换函数
    /// - Returns: 新的布局树（如果未找到则返回原树）
    public func updatingPanel(_ panelId: UUID, transform: (PanelNode) -> PanelNode) -> LayoutTree {
        switch self {
        case .panel(let panelNode):
            if panelNode.id == panelId {
                return .panel(transform(panelNode))
            }
            return self

        case .split(let direction, let first, let second, let ratio):
            let newFirst = first.updatingPanel(panelId, transform: transform)
            let newSecond = second.updatingPanel(panelId, transform: transform)

            if newFirst != first || newSecond != second {
                return .split(
                    direction: direction,
                    first: newFirst,
                    second: newSecond,
                    ratio: ratio
                )
            }

            return self
        }
    }

    /// 移除指定的 Tab
    ///
    /// - Parameter tabId: 要移除的 Tab ID
    /// - Returns: 新的布局树（如果移除后 Panel 为空会自动清理）
    public func removingTab(_ tabId: UUID) -> LayoutTree? {
        switch self {
        case .panel(let panelNode):
            // 从 Panel 中移除 Tab
            if let newPanel = panelNode.removingTab(tabId) {
                return .panel(newPanel)
            }
            // 如果移除后 Panel 为空，返回 nil
            return nil

        case .split(let direction, let first, let second, let ratio):
            let newFirst = first.removingTab(tabId)
            let newSecond = second.removingTab(tabId)

            // 如果一侧被移除，返回另一侧
            if newFirst == nil {
                return newSecond
            }
            if newSecond == nil {
                return newFirst
            }

            // 两侧都存在，返回新的 split
            return .split(
                direction: direction,
                first: newFirst!,
                second: newSecond!,
                ratio: ratio
            )
        }
    }
}

// MARK: - Codable 实现

extension LayoutTree {
    private enum CodingKeys: String, CodingKey {
        case type
        case panel
        case direction
        case first
        case second
        case ratio
    }

    private enum NodeType: String, Codable {
        case panel
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .panel:
            let panel = try container.decode(PanelNode.self, forKey: .panel)
            self = .panel(panel)

        case .split:
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let first = try container.decode(LayoutTree.self, forKey: .first)
            let second = try container.decode(LayoutTree.self, forKey: .second)
            let ratio = try container.decode(CGFloat.self, forKey: .ratio)
            self = .split(direction: direction, first: first, second: second, ratio: ratio)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .panel(let panel):
            try container.encode(NodeType.panel, forKey: .type)
            try container.encode(panel, forKey: .panel)

        case .split(let direction, let first, let second, let ratio):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
            try container.encode(ratio, forKey: .ratio)
        }
    }
}
