// SlotContext.swift
// ETermKit
//
// Slot 上下文协议 - 定义 Tab/Page Slot 需要访问的接口

import Foundation

// MARK: - TabSlotContext

/// Tab Slot 上下文协议
///
/// 定义 Tab Slot 渲染时需要访问的 Tab 信息。
/// 主程序的 Tab 类型需要 conform 此协议。
///
/// 使用示例：
/// ```swift
/// func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
///     guard let terminalId = tab.terminalId else { return nil }
///     // 根据 terminalId 或 decoration 渲染视图
/// }
/// ```
public protocol TabSlotContext: AnyObject, Identifiable where ID == UUID {
    /// Tab 唯一标识
    nonisolated var id: UUID { get }

    /// 终端 ID（仅终端 Tab 有效，View Tab 为 nil）
    var terminalId: Int? { get }

    /// 插件设置的装饰状态
    var decoration: TabDecoration? { get }

    /// Tab 标题
    var title: String { get }

    /// 是否激活
    var isActive: Bool { get }
}

// MARK: - PageSlotContext

/// Page Slot 上下文协议
///
/// 定义 Page Slot 渲染时需要访问的 Page 信息。
/// 主程序的 Page 类型需要 conform 此协议。
///
/// 使用示例：
/// ```swift
/// func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
///     let thinkingCount = page.slotTabs.filter {
///         $0.decoration?.priority == .plugin(id: "claude", priority: 101)
///     }.count
///     // 渲染统计视图
/// }
/// ```
public protocol PageSlotContext: AnyObject, Identifiable where ID == UUID {
    /// Page 唯一标识
    nonisolated var id: UUID { get }

    /// Page 标题
    var title: String { get }

    /// 是否激活
    var isActive: Bool { get }

    /// Page 下所有 Tab（用于统计装饰状态等）
    ///
    /// 使用 `slotTabs` 避免与主程序 Page.allTabs 命名冲突
    var slotTabs: [any TabSlotContext] { get }

    /// Page 的有效装饰（聚合子 Tab 的最高优先级装饰）
    var effectiveDecoration: TabDecoration? { get }
}
