//
//  PanelLayout.swift
//  ETerm
//
//  领域值对象 - Panel 布局树

import Foundation

/// Panel 布局树
///
/// 使用二叉树结构表示 Panel 的布局，这是整个布局系统的核心数据结构
///
/// 设计说明：
/// - leaf: 表示叶子节点，对应一个实际的 Panel
/// - split: 表示分割节点，包含两个子布局和分割比例
///
/// 示例：
/// ```
/// // 单个 Panel
/// .leaf(panelId: UUID())
///
/// // 左右分割
/// .split(
///     direction: .horizontal,
///     first: .leaf(panelId: leftPanelId),
///     second: .leaf(panelId: rightPanelId),
///     ratio: 0.5
/// )
/// ```
indirect enum PanelLayout: Equatable {
    /// 叶子节点 - 实际的 Panel
    case leaf(panelId: UUID)

    /// 分割节点 - 包含两个子布局
    case split(
        direction: SplitDirection,
        first: PanelLayout,
        second: PanelLayout,
        ratio: CGFloat  // first 占总空间的比例 (0.0 ~ 1.0)
    )

    /// 获取布局树中的所有 Panel ID
    ///
    /// - Returns: 所有 Panel ID 的数组
    func allPanelIds() -> [UUID] {
        switch self {
        case .leaf(let panelId):
            return [panelId]
        case .split(_, let first, let second, _):
            return first.allPanelIds() + second.allPanelIds()
        }
    }

    /// 统计布局树中的 Panel 数量
    var panelCount: Int {
        allPanelIds().count
    }

    /// 检查是否包含指定的 Panel ID
    func contains(_ panelId: UUID) -> Bool {
        allPanelIds().contains(panelId)
    }
}
