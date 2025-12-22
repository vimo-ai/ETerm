//
//  PaneProtocols.swift
//  ETerm
//
//  Pane 统一抽象层
//
//  设计说明：
//  - Pane: Tab 和 Page 的统一抽象（标签项）
//  - PaneContainer: Panel 和 Window 的统一抽象（容器）
//  - ActionAreaHost: Window 独有的 ActionArea 能力
//
//  关系：
//  - Window : Page = Panel : Tab
//  - Window 实现 PaneContainer<Page> + ActionAreaHost
//  - Panel 实现 PaneContainer<Tab>
//

import SwiftUI
import Combine

// MARK: - PluginDataStore

/// 插件数据存储（类型安全的键值存储）
///
/// 用于插件在 Pane 上存储自定义数据
/// 例如：Vlaude 插件存储 usage 统计
public final class PluginDataStore {
    private var storage: [String: Any] = [:]

    public init() {}

    /// 获取数据
    public func get<T>(_ key: String) -> T? {
        storage[key] as? T
    }

    /// 设置数据
    public func set<T>(_ key: String, value: T?) {
        if let value = value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    /// 检查是否存在
    public func contains(_ key: String) -> Bool {
        storage[key] != nil
    }

    /// 移除数据
    public func remove(_ key: String) {
        storage.removeValue(forKey: key)
    }

    /// 清空所有数据
    public func clear() {
        storage.removeAll()
    }
}

// MARK: - Pane 协议

/// Pane 协议 - Tab 和 Page 的统一抽象
///
/// 提供标签项的通用能力：
/// - 标识和标题
/// - 激活状态
/// - 装饰（插件可设置的视觉效果）
/// - 插件数据存储
/// - Slot 渲染能力
public protocol Pane: AnyObject, Identifiable where ID == UUID {
    /// 唯一标识
    nonisolated var id: UUID { get }

    /// 标题
    var title: String { get set }

    /// 是否激活
    var isActive: Bool { get }

    /// 插件设置的装饰
    var decoration: TabDecoration? { get set }

    /// 插件数据存储
    var pluginData: PluginDataStore { get }

    /// 激活
    func activate()

    /// 失活
    func deactivate()
}

// MARK: - PaneContainer 协议

/// PaneContainer 协议 - Panel 和 Window 的统一抽象
///
/// 提供容器的通用能力：
/// - 管理 Pane 列表
/// - 激活状态管理
/// - 添加/移除/切换 Pane
public protocol PaneContainer: AnyObject, Identifiable where ID == UUID {
    associatedtype Item: Pane

    /// 容器唯一标识
    nonisolated var id: UUID { get }

    /// 所有 Pane 项
    var items: [Item] { get }

    /// 当前激活的 Pane ID
    var activeItemId: UUID? { get }

    /// 当前激活的 Pane
    var activeItem: Item? { get }

    /// 项目数量
    var itemCount: Int { get }

    /// 激活指定 Pane
    @discardableResult
    func activateItem(_ itemId: UUID) -> Bool

    /// 添加 Pane
    func addItem(_ item: Item)

    /// 移除 Pane
    @discardableResult
    func removeItem(_ itemId: UUID) -> Item?

    /// 重新排序
    @discardableResult
    func reorderItems(_ itemIds: [UUID]) -> Bool
}

// MARK: - PaneContainer 默认实现

extension PaneContainer {
    /// 当前激活的 Pane（默认实现）
    public var activeItem: Item? {
        guard let activeId = activeItemId else { return nil }
        return items.first { $0.id == activeId }
    }

    /// 项目数量（默认实现）
    public var itemCount: Int {
        items.count
    }
}

// MARK: - ActionAreaHost 协议

/// ActionAreaHost 协议 - Window 独有的 ActionArea 能力
///
/// 允许插件在 Page 栏右侧注册自定义视图
public protocol ActionAreaHost: AnyObject {
    /// ActionArea 注册表
    var actionAreaRegistry: ActionAreaRegistry { get }
}

// MARK: - ActionAreaRegistry

/// ActionArea 注册表
///
/// 管理插件注册的 ActionArea 视图
public final class ActionAreaRegistry: ObservableObject {
    /// 已注册的视图定义
    @Published private(set) var definitions: [ActionAreaDefinition] = []

    /// 注册通知
    public static let didChangeNotification = Notification.Name("ActionAreaRegistryDidChange")

    public init() {}

    /// 注册 ActionArea 视图
    public func register(
        pluginId: String,
        viewId: String,
        priority: Int = 0,
        viewProvider: @escaping () -> AnyView
    ) {
        // 检查是否已存在
        guard !definitions.contains(where: { $0.id == viewId }) else {
            return
        }

        let definition = ActionAreaDefinition(
            id: viewId,
            pluginId: pluginId,
            priority: priority,
            viewProvider: viewProvider
        )
        definitions.append(definition)
        definitions.sort { $0.priority > $1.priority }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 注销插件的所有视图
    public func unregister(pluginId: String) {
        let hadViews = definitions.contains { $0.pluginId == pluginId }
        definitions.removeAll { $0.pluginId == pluginId }

        if hadViews {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// 注销指定视图
    public func unregister(viewId: String) {
        let hadView = definitions.contains { $0.id == viewId }
        definitions.removeAll { $0.id == viewId }

        if hadView {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// 获取所有视图（按优先级排序）
    public func getViews() -> [AnyView] {
        definitions.map { $0.viewProvider() }
    }
}

/// ActionArea 视图定义
public struct ActionAreaDefinition: Identifiable {
    public let id: String
    public let pluginId: String
    public let priority: Int
    public let viewProvider: () -> AnyView
}

// MARK: - SlotRegistry

/// 通用 Slot 注册表
///
/// 允许插件在 Pane 上注入自定义视图（图标、徽章等）
/// 泛型设计，Tab 和 Page 共用
public final class SlotRegistry<Item: Pane>: ObservableObject {
    /// 已注册的 Slot 定义
    @Published private(set) var slots: [SlotDefinition<Item>] = []

    /// Slot 变化通知
    public static var slotDidChangeNotification: Notification.Name {
        Notification.Name("SlotDidChange_\(String(describing: Item.self))")
    }

    public init() {}

    /// 注册 Slot
    public func register(
        pluginId: String,
        slotId: String,
        priority: Int = 0,
        viewProvider: @escaping (Item) -> AnyView?
    ) {
        // 检查是否已存在
        guard !slots.contains(where: { $0.id == slotId }) else {
            return
        }

        let slot = SlotDefinition(
            id: slotId,
            pluginId: pluginId,
            priority: priority,
            viewProvider: viewProvider
        )
        slots.append(slot)

        NotificationCenter.default.post(name: Self.slotDidChangeNotification, object: nil)
    }

    /// 注销插件的所有 Slot
    public func unregister(pluginId: String) {
        let hadSlots = slots.contains { $0.pluginId == pluginId }
        slots.removeAll { $0.pluginId == pluginId }

        if hadSlots {
            NotificationCenter.default.post(name: Self.slotDidChangeNotification, object: nil)
        }
    }

    /// 注销指定 Slot
    public func unregister(slotId: String) {
        let hadSlot = slots.contains { $0.id == slotId }
        slots.removeAll { $0.id == slotId }

        if hadSlot {
            NotificationCenter.default.post(name: Self.slotDidChangeNotification, object: nil)
        }
    }

    /// 获取指定 Pane 的所有 Slot 视图
    public func getSlotViews(for item: Item) -> [AnyView] {
        let sortedSlots = slots.sorted { $0.priority > $1.priority }
        return sortedSlots.compactMap { $0.viewProvider(item) }
    }

    /// 估算 Slot 宽度
    public func estimateSlotWidth(for item: Item) -> CGFloat {
        let views = getSlotViews(for: item)
        let estimated = CGFloat(views.count) * 18
        return min(estimated, 40)
    }
}

/// Slot 定义
public struct SlotDefinition<Item: Pane>: Identifiable {
    public let id: String
    public let pluginId: String
    public let priority: Int
    public let viewProvider: (Item) -> AnyView?
}

// MARK: - SlotRegistry 单例

/// Tab SlotRegistry 单例
let tabSlotRegistry = SlotRegistry<Tab>()

/// Page SlotRegistry 单例
let pageSlotRegistry = SlotRegistry<Page>()
