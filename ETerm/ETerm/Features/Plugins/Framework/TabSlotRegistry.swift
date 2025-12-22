//
//  TabSlotRegistry.swift
//  ETerm
//
//  插件层 - Tab Slot 注册表
//
//  允许插件在 Tab 的 title 和 close 之间注入自定义视图
//

import SwiftUI
import Combine

/// Tab Slot 定义
public struct TabSlotDefinition: Identifiable {
    public let id: String           // slotId
    public let pluginId: String
    public let priority: Int        // 数字大 = 靠左/优先显示
    public let viewProvider: (Int) -> AnyView?  // terminalId -> View?

    public init(
        id: String,
        pluginId: String,
        priority: Int,
        viewProvider: @escaping (Int) -> AnyView?
    ) {
        self.id = id
        self.pluginId = pluginId
        self.priority = priority
        self.viewProvider = viewProvider
    }
}

/// Tab Slot 注册表 - 管理插件注册的 Tab Slot
final class TabSlotRegistry: ObservableObject {
    static let shared = TabSlotRegistry()

    /// 已注册的 Slot 定义（按注册顺序）
    @Published private(set) var slots: [TabSlotDefinition] = []

    /// Slot 变化通知
    static let slotDidChangeNotification = Notification.Name("TabSlotDidChange")

    private init() {}

    /// 注册 Tab Slot
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID（唯一标识）
    ///   - priority: 优先级（数字大 = 靠左/优先显示）
    ///   - viewProvider: 视图提供者，接收 terminalId，返回 nil 表示该 Tab 不显示此 slot
    func register(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Int) -> AnyView?
    ) {
        // 检查是否已存在
        guard !slots.contains(where: { $0.id == slotId }) else {
            return
        }

        let slot = TabSlotDefinition(
            id: slotId,
            pluginId: pluginId,
            priority: priority,
            viewProvider: viewProvider
        )
        slots.append(slot)

        // 发送通知
        NotificationCenter.default.post(
            name: Self.slotDidChangeNotification,
            object: nil
        )
    }

    /// 注销插件的所有 Slot
    /// - Parameter pluginId: 插件 ID
    func unregister(for pluginId: String) {
        let hadSlots = slots.contains { $0.pluginId == pluginId }
        slots.removeAll { $0.pluginId == pluginId }

        if hadSlots {
            NotificationCenter.default.post(
                name: Self.slotDidChangeNotification,
                object: nil
            )
        }
    }

    /// 注销指定 Slot
    /// - Parameter slotId: Slot ID
    func unregister(slotId: String) {
        let hadSlot = slots.contains { $0.id == slotId }
        slots.removeAll { $0.id == slotId }

        if hadSlot {
            NotificationCenter.default.post(
                name: Self.slotDidChangeNotification,
                object: nil
            )
        }
    }

    /// 获取指定 Terminal 的所有 Slot 视图
    /// - Parameter terminalId: Terminal ID
    /// - Returns: 按优先级排序的视图数组（priority 大的在前）
    func getSlotViews(for terminalId: Int) -> [AnyView] {
        // 按 priority 降序排序（大的靠左/优先）
        let sortedSlots = slots.sorted { $0.priority > $1.priority }

        // 收集非 nil 的视图
        return sortedSlots.compactMap { slot in
            slot.viewProvider(terminalId)
        }
    }

    /// 计算指定 Terminal 的 Slot 总宽度（估算）
    /// - Parameter terminalId: Terminal ID
    /// - Returns: 预估的 Slot 宽度
    func estimateSlotWidth(for terminalId: Int) -> CGFloat {
        let views = getSlotViews(for: terminalId)
        // 每个图标约 16px + 2px 间距，最大 40px
        let estimated = CGFloat(views.count) * 18
        return min(estimated, 40)
    }
}
