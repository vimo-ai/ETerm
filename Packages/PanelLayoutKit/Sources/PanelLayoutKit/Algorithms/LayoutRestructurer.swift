//
//  LayoutRestructurer.swift
//  PanelLayoutKit
//
//  布局重构算法
//
//  参考 Golden Layout 的 stack.ts:447-532 实现
//

import Foundation
import CoreGraphics

/// 布局重构算法
///
/// 负责处理拖拽结束后的布局重构。
/// 参考 Golden Layout 的 onDrop 实现。
public struct LayoutRestructurer {
    /// 默认分割比例
    private let defaultSplitRatio: CGFloat = 0.5

    /// 创建布局重构器
    public init() {}

    /// 处理拖拽结束
    ///
    /// - Parameters:
    ///   - layout: 当前布局树
    ///   - tab: 被拖拽的 Tab
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 新的布局树
    public func handleDrop(
        layout: LayoutTree,
        tab: TabNode,
        dropZone: DropZone,
        targetPanelId: UUID
    ) -> LayoutTree {
        // 查找源 Panel（Tab 当前所在的 Panel）
        let sourcePanel = layout.findPanel(containingTab: tab.id)

        // 特殊情况：拖拽唯一的 Tab 到自己身上（通常是双击触发）
        if let sourcePanel = sourcePanel,
           sourcePanel.id == targetPanelId,
           sourcePanel.tabs.count == 1 {
            // 不做任何操作，返回原 layout
            return layout
        }

        // 1. 先从原位置移除 Tab
        let layoutWithoutTab = layout.removingTab(tab.id) ?? layout

        // 2. 根据 Drop Zone 类型处理
        switch dropZone.type {
        case .header:
            // 添加到 Header（现有 Panel 的 Tab 列表）
            var adjustedInsertIndex = dropZone.insertIndex ?? 0

            // 如果源 Panel 和目标 Panel 是同一个，需要调整 insertIndex
            if let sourcePanel = sourcePanel,
               sourcePanel.id == targetPanelId,
               let originalIndex = sourcePanel.tabs.firstIndex(where: { $0.id == tab.id }),
               originalIndex < adjustedInsertIndex {
                // Tab 原来在 insertIndex 之前，移除后位置会前移
                adjustedInsertIndex -= 1
            }

            return handleHeaderDrop(
                layout: layoutWithoutTab,
                tab: tab,
                targetPanelId: targetPanelId,
                insertIndex: adjustedInsertIndex
            )

        case .body:
            // 添加到空 Panel
            return handleBodyDrop(
                layout: layoutWithoutTab,
                tab: tab,
                targetPanelId: targetPanelId
            )

        case .left:
            // 在左侧分割
            // 检查 targetPanel 是否还存在（移除后可能被删除）
            if layoutWithoutTab.findPanel(byId: targetPanelId) != nil {
                return handleSplitDrop(
                    layout: layoutWithoutTab,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .horizontal,
                    insertBefore: true
                )
            } else {
                // targetPanel 被删除了，使用原始 layout（但需要替换 Panel 的内容）
                return handleSplitDropWithReplace(
                    layout: layout,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .horizontal,
                    insertBefore: true
                )
            }

        case .right:
            // 在右侧分割
            if layoutWithoutTab.findPanel(byId: targetPanelId) != nil {
                return handleSplitDrop(
                    layout: layoutWithoutTab,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .horizontal,
                    insertBefore: false
                )
            } else {
                return handleSplitDropWithReplace(
                    layout: layout,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .horizontal,
                    insertBefore: false
                )
            }

        case .top:
            // 在顶部分割（macOS 坐标系）
            if layoutWithoutTab.findPanel(byId: targetPanelId) != nil {
                return handleSplitDrop(
                    layout: layoutWithoutTab,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .vertical,
                    insertBefore: false  // top 在 second（上方）
                )
            } else {
                return handleSplitDropWithReplace(
                    layout: layout,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .vertical,
                    insertBefore: false
                )
            }

        case .bottom:
            // 在底部分割
            if layoutWithoutTab.findPanel(byId: targetPanelId) != nil {
                return handleSplitDrop(
                    layout: layoutWithoutTab,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .vertical,
                    insertBefore: true  // bottom 在 first（下方）
                )
            } else {
                return handleSplitDropWithReplace(
                    layout: layout,
                    tab: tab,
                    targetPanelId: targetPanelId,
                    direction: .vertical,
                    insertBefore: true
                )
            }
        }
    }

    // MARK: - Private Methods

    /// 处理 Header Drop
    ///
    /// 将 Tab 添加到目标 Panel 的 Tab 列表中。
    private func handleHeaderDrop(
        layout: LayoutTree,
        tab: TabNode,
        targetPanelId: UUID,
        insertIndex: Int
    ) -> LayoutTree {
        return layout.updatingPanel(targetPanelId) { panel in
            panel.addingTab(tab, at: insertIndex)
        }
    }

    /// 处理 Body Drop
    ///
    /// 将 Tab 添加到空 Panel 中。
    private func handleBodyDrop(
        layout: LayoutTree,
        tab: TabNode,
        targetPanelId: UUID
    ) -> LayoutTree {
        return layout.updatingPanel(targetPanelId) { panel in
            panel.addingTab(tab)
        }
    }

    /// 处理分割 Drop（targetPanel 被删除的特殊情况）
    ///
    /// 当 targetPanel 只有一个 Tab（就是被拖拽的 Tab）时，移除后 Panel 会被删除。
    /// 这种情况下，实现 Split 行为：创建分割视图，每个 Panel 都有一个独立的 Tab。
    /// 类似 VS Code 的 "Split Editor" 功能（创建新的编辑器实例）。
    private func handleSplitDropWithReplace(
        layout: LayoutTree,
        tab: TabNode,
        targetPanelId: UUID,
        direction: SplitDirection,
        insertBefore: Bool
    ) -> LayoutTree {
        // 创建新 Tab（新的 ID，但标题和内容相同）
        // 这样确保每个 Tab ID 在布局树中唯一
        let newTab = TabNode(
            id: UUID(),  // 新的 ID
            title: tab.title,
            rustTerminalId: tab.rustTerminalId
        )

        // 创建新 Panel（包含新的 Tab）
        let newPanel = PanelNode(
            tabs: [newTab],
            activeTabIndex: 0
        )

        // 替换 targetPanel 为分割节点
        return layout.replacingPanel(targetPanelId, with: {
            // 获取原 Panel
            guard let originalPanel = layout.findPanel(byId: targetPanelId) else {
                return .panel(newPanel)
            }

            if insertBefore {
                // 新 Panel 在前
                return .split(
                    direction: direction,
                    first: .panel(newPanel),
                    second: .panel(originalPanel),
                    ratio: defaultSplitRatio
                )
            } else {
                // 新 Panel 在后
                return .split(
                    direction: direction,
                    first: .panel(originalPanel),
                    second: .panel(newPanel),
                    ratio: defaultSplitRatio
                )
            }
        }())
    }

    /// 处理分割 Drop
    ///
    /// 在目标 Panel 旁边创建新 Panel，并重构布局树。
    /// 参考 Golden Layout 的算法。
    private func handleSplitDrop(
        layout: LayoutTree,
        tab: TabNode,
        targetPanelId: UUID,
        direction: SplitDirection,
        insertBefore: Bool
    ) -> LayoutTree {
        // 创建新 Panel（包含被拖拽的 Tab）
        let newPanel = PanelNode(
            tabs: [tab],
            activeTabIndex: 0
        )

        // 检查父节点类型，判断是否需要重构
        let needsRestructure = checkNeedsRestructure(
            layout: layout,
            targetPanelId: targetPanelId,
            direction: direction
        )

        if needsRestructure {
            // 父节点类型正确，直接在父节点中插入新 Panel
            return insertIntoParent(
                layout: layout,
                newPanel: newPanel,
                targetPanelId: targetPanelId,
                insertBefore: insertBefore
            )
        } else {
            // 父节点类型不正确，需要创建新的分割节点
            return createSplitNode(
                layout: layout,
                newPanel: newPanel,
                targetPanelId: targetPanelId,
                direction: direction,
                insertBefore: insertBefore
            )
        }
    }

    /// 检查是否需要重构
    ///
    /// 判断父节点的分割方向是否与目标方向一致。
    private func checkNeedsRestructure(
        layout: LayoutTree,
        targetPanelId: UUID,
        direction: SplitDirection
    ) -> Bool {
        // 递归查找目标 Panel 的父节点
        return findParentDirection(layout: layout, targetPanelId: targetPanelId) == direction
    }

    /// 查找父节点的分割方向
    private func findParentDirection(
        layout: LayoutTree,
        targetPanelId: UUID
    ) -> SplitDirection? {
        switch layout {
        case .panel:
            return nil

        case .split(let direction, let first, let second, _):
            // 检查子节点是否包含目标 Panel
            if containsPanel(first, panelId: targetPanelId) ||
               containsPanel(second, panelId: targetPanelId) {
                return direction
            }

            // 递归查找
            return findParentDirection(layout: first, targetPanelId: targetPanelId)
                ?? findParentDirection(layout: second, targetPanelId: targetPanelId)
        }
    }

    /// 检查布局树是否包含指定的 Panel
    private func containsPanel(_ layout: LayoutTree, panelId: UUID) -> Bool {
        switch layout {
        case .panel(let panel):
            return panel.id == panelId
        case .split:
            return false  // 只检查直接子节点
        }
    }

    /// 在父节点中插入新 Panel
    ///
    /// 当父节点的分割方向与目标方向一致时，直接在父节点中插入。
    private func insertIntoParent(
        layout: LayoutTree,
        newPanel: PanelNode,
        targetPanelId: UUID,
        insertBefore: Bool
    ) -> LayoutTree {
        switch layout {
        case .panel:
            // 不应该到这里
            return layout

        case .split(let direction, let first, let second, let ratio):
            // 检查哪个子节点包含目标 Panel
            if case .panel(let panel) = first, panel.id == targetPanelId {
                // 目标 Panel 在 first
                if insertBefore {
                    // 在前面插入：新 Panel -> 原 Panel
                    return .split(
                        direction: direction,
                        first: .panel(newPanel),
                        second: .split(
                            direction: direction,
                            first: first,
                            second: second,
                            ratio: 0.5
                        ),
                        ratio: ratio * 0.5
                    )
                } else {
                    // 在后面插入：原 Panel -> 新 Panel
                    return .split(
                        direction: direction,
                        first: .split(
                            direction: direction,
                            first: first,
                            second: .panel(newPanel),
                            ratio: 0.5
                        ),
                        second: second,
                        ratio: ratio
                    )
                }
            }

            if case .panel(let panel) = second, panel.id == targetPanelId {
                // 目标 Panel 在 second
                if insertBefore {
                    // 在前面插入
                    return .split(
                        direction: direction,
                        first: first,
                        second: .split(
                            direction: direction,
                            first: .panel(newPanel),
                            second: second,
                            ratio: 0.5
                        ),
                        ratio: ratio
                    )
                } else {
                    // 在后面插入
                    return .split(
                        direction: direction,
                        first: first,
                        second: .split(
                            direction: direction,
                            first: second,
                            second: .panel(newPanel),
                            ratio: 0.5
                        ),
                        ratio: ratio
                    )
                }
            }

            // 递归处理子树
            let newFirst = insertIntoParent(
                layout: first,
                newPanel: newPanel,
                targetPanelId: targetPanelId,
                insertBefore: insertBefore
            )
            let newSecond = insertIntoParent(
                layout: second,
                newPanel: newPanel,
                targetPanelId: targetPanelId,
                insertBefore: insertBefore
            )

            if newFirst != first || newSecond != second {
                return .split(
                    direction: direction,
                    first: newFirst,
                    second: newSecond,
                    ratio: ratio
                )
            }

            return layout
        }
    }

    /// 创建新的分割节点
    ///
    /// 当父节点的分割方向与目标方向不一致时，创建新的分割节点。
    private func createSplitNode(
        layout: LayoutTree,
        newPanel: PanelNode,
        targetPanelId: UUID,
        direction: SplitDirection,
        insertBefore: Bool
    ) -> LayoutTree {
        return layout.replacingPanel(targetPanelId, with: { () -> LayoutTree in
            let targetPanel = layout.findPanel(byId: targetPanelId)!

            if insertBefore {
                // 新 Panel 在前
                return .split(
                    direction: direction,
                    first: .panel(newPanel),
                    second: .panel(targetPanel),
                    ratio: defaultSplitRatio
                )
            } else {
                // 新 Panel 在后
                return .split(
                    direction: direction,
                    first: .panel(targetPanel),
                    second: .panel(newPanel),
                    ratio: defaultSplitRatio
                )
            }
        }())
    }
}
