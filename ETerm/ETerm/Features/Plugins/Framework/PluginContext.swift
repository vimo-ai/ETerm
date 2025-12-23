//
//  PluginContext.swift
//  ETerm
//
//  插件层 - 插件上下文

import Foundation
import SwiftUI
import AppKit

// MARK: - Tab 装饰（通用机制，核心层定义）

/// 装饰优先级
///
/// 类型安全的优先级系统，区分系统级装饰和插件级装饰
public enum DecorationPriority: Equatable, Comparable {
    /// 系统级装饰（保留给核心系统使用）
    case system(SystemLevel)

    /// 插件级装饰（插件使用，包含插件 ID 和优先级）
    case plugin(id: String, priority: Int)

    /// 系统级优先级
    public enum SystemLevel: Int, Comparable {
        /// 默认状态（灰色，最低优先级）
        case `default` = 0

        /// Active 状态（深红色，系统最高优先级）
        case active = 100

        public static func < (lhs: SystemLevel, rhs: SystemLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 获取数值优先级（用于比较）
    public var numericValue: Int {
        switch self {
        case .system(let level):
            return level.rawValue
        case .plugin(_, let priority):
            return priority
        }
    }

    /// 比较优先级（数值越大越优先）
    ///
    /// 比较规则（按优先级排序）：
    /// 1. 先按数值比较（高优先级在前）
    /// 2. 数值相同时，system 优先于 plugin（系统装饰优先）
    /// 3. 同为 plugin 且数值相同时，按 plugin ID 字典序排序（确保稳定排序）
    public static func < (lhs: DecorationPriority, rhs: DecorationPriority) -> Bool {
        // 1. 首先按数值比较
        if lhs.numericValue != rhs.numericValue {
            return lhs.numericValue < rhs.numericValue
        }

        // 2. 数值相同时，按类型比较（system < plugin，使 system 在 max 时胜出）
        switch (lhs, rhs) {
        case (.system, .plugin):
            return true  // system 更优先（在 max 时会被选中）
        case (.plugin, .system):
            return false
        case (.system, .system):
            return false  // 同类型且数值相同，视为相等
        case let (.plugin(lhsId, _), .plugin(rhsId, _)):
            // 3. 同为 plugin 且数值相同时，按 ID 字典序排序（确保稳定性）
            return lhsId < rhsId
        }
    }

    /// 是否为默认优先级（用于过滤）
    public var isDefault: Bool {
        if case .system(.default) = self {
            return true
        }
        return false
    }
}

/// Tab 装饰状态
///
/// 插件可以通过 UIService.setTabDecoration() 设置 Tab 的视觉装饰。
/// 显示时取最高优先级的装饰，Page 收敛所有 Tab 的最高优先级。
public struct TabDecoration: Equatable {
    /// 优先级（数值越大越优先显示）
    public let priority: DecorationPriority

    /// 装饰颜色
    public let color: NSColor

    /// 动画样式
    public let style: Style

    /// 是否序列化（插件临时状态设为 false，quit 后消失）
    public let persistent: Bool

    /// 动画样式
    public enum Style: Equatable {
        /// 静态颜色（无动画）
        case solid
        /// 脉冲动画（透明度周期变化）
        case pulse
        /// 呼吸动画（颜色渐变）
        case breathing
    }

    public init(priority: DecorationPriority, color: NSColor, style: Style = .solid, persistent: Bool = false) {
        self.priority = priority
        self.color = color
        self.style = style
        self.persistent = persistent
    }

    // MARK: - 预定义装饰

    /// 默认装饰（系统级，最低优先级）
    public static let `default` = TabDecoration(
        priority: .system(.default),
        color: .gray,
        style: .solid
    )

    /// Active 装饰（系统级，深红色）
    public static let active = TabDecoration(
        priority: .system(.active),
        color: NSColor(red: 0x86/255, green: 0x17/255, blue: 0x17/255, alpha: 1.0),
        style: .solid
    )

    /// 思考中装饰（Claude 插件专用，蓝色脉冲）
    ///
    /// - Parameter pluginId: 插件 ID（必须传入，确保类型安全）
    public static func thinking(pluginId: String) -> TabDecoration {
        TabDecoration(
            priority: .plugin(id: pluginId, priority: 101),
            color: .systemBlue,
            style: .pulse
        )
    }

    /// 已完成装饰（Claude 插件专用，橙色静态）
    ///
    /// - Parameter pluginId: 插件 ID（必须传入，确保类型安全）
    public static func completed(pluginId: String) -> TabDecoration {
        TabDecoration(
            priority: .plugin(id: pluginId, priority: 5),
            color: .systemOrange,
            style: .solid
        )
    }

    /// 等待用户输入装饰（Claude 插件专用，黄色脉冲）
    ///
    /// 优先级 102，高于 thinking(101)：当需要用户输入时，黄色提醒优先显示
    ///
    /// - Parameter pluginId: 插件 ID（必须传入，确保类型安全）
    public static func waitingInput(pluginId: String) -> TabDecoration {
        TabDecoration(
            priority: .plugin(id: pluginId, priority: 102),
            color: .systemYellow,
            style: .pulse
        )
    }
}

/// Tab 装饰变化通知（UI 内部事件）
///
/// userInfo:
/// - "terminal_id": Int - 目标终端 ID
/// - "decoration": TabDecoration? - 装饰状态，nil 表示清除
extension Notification.Name {
    public static let tabDecorationChanged = Notification.Name("tabDecorationChanged")
}

/// 插件上下文 - 聚合插件所需的系统能力
///
/// 提供插件与核心系统交互的统一接口：
/// - 命令服务：注册和执行命令
/// - 事件服务：发布和订阅事件
/// - 键盘服务：绑定快捷键
/// - UI 服务：注册侧边栏 Tab
/// - 终端服务：与终端交互
/// - 服务注册表：插件间能力共享
protocol PluginContext: AnyObject {
    /// 命令服务
    var commands: CommandService { get }

    /// 事件服务
    var events: EventService { get }

    /// 键盘服务
    var keyboard: KeyboardService { get }

    /// UI 服务
    var ui: UIService { get }

    /// 终端服务
    var terminal: TerminalService { get }

    /// 服务注册表 - 插件间能力共享
    var services: ServiceRegistry { get }
}

// MARK: - 终端服务协议

/// 终端服务协议 - 提供终端操作能力
protocol TerminalService: AnyObject {
    /// 向终端写入数据
    ///
    /// - Parameters:
    ///   - terminalId: 目标终端 ID
    ///   - data: 要写入的数据
    /// - Returns: 是否成功
    @discardableResult
    func write(terminalId: Int, data: String) -> Bool

    /// 根据 terminalId 查找 tabId
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: Tab 的 UUID string，找不到返回 nil
    func getTabId(for terminalId: Int) -> String?
}

/// View Tab 的放置方式
enum ViewTabPlacement {
    /// 分栏创建新 Panel（默认，类似 Ctrl+D）
    case split(SplitDirection)
    /// 在当前 Panel 新增 Tab（类似 Ctrl+T）
    case tab
    /// 创建独立 Page
    case page
}

/// UI 服务协议 - 提供 UI 扩展能力
protocol UIService: AnyObject {
    /// 注册侧边栏 Tab
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - pluginName: 插件名称
    ///   - tab: Tab 定义
    func registerSidebarTab(for pluginId: String, pluginName: String, tab: SidebarTab)

    /// 注销插件的所有侧边栏 Tab
    /// - Parameter pluginId: 插件 ID
    func unregisterSidebarTabs(for pluginId: String)

    /// 注册信息窗口内容
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 内容 ID（唯一标识）
    ///   - title: 内容标题
    ///   - viewProvider: 视图提供者
    func registerInfoContent(for pluginId: String, id: String, title: String, viewProvider: @escaping () -> AnyView)

    /// 注册 PageBar 组件（显示在 PageBar 右侧，翻译模式左边）
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 组件 ID（唯一标识）
    ///   - viewProvider: 视图提供者
    func registerPageBarItem(
        for pluginId: String,
        id: String,
        viewProvider: @escaping () -> AnyView
    )

    /// 创建 View Tab
    ///
    /// 在当前窗口中创建一个显示自定义视图的 Tab。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - viewId: 视图标识符（用于 Session 恢复）
    ///   - title: Tab 标题
    ///   - placement: 放置方式，默认分栏
    ///   - viewProvider: SwiftUI 视图提供者
    /// - Returns: 创建的 Tab，失败返回 nil
    @discardableResult
    func createViewTab(
        for pluginId: String,
        viewId: String,
        title: String,
        placement: ViewTabPlacement,
        viewProvider: @escaping () -> AnyView
    ) -> Tab?

    /// 预注册视图 Provider（用于 Session 恢复）
    ///
    /// 插件应在 activate() 时调用此方法预注册视图，
    /// 这样 Session 恢复时能正确显示插件视图而非占位符。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - viewId: 视图标识符
    ///   - title: Tab 标题
    ///   - viewProvider: SwiftUI 视图提供者
    func registerViewProvider(
        for pluginId: String,
        viewId: String,
        title: String,
        viewProvider: @escaping () -> AnyView
    )

    // MARK: - Tab 装饰 API

    /// 设置 Tab 装饰
    ///
    /// 用于在 Tab 上显示视觉反馈（如运行状态、完成提醒等）。
    /// 核心层只负责渲染，不知道具体业务含义。
    ///
    /// - Parameters:
    ///   - terminalId: 目标终端 ID
    ///   - decoration: 装饰状态，nil 表示清除
    ///   - skipIfActive: 如果为 true，且该 terminal 是当前 active 的，则不设置装饰
    func setTabDecoration(terminalId: Int, decoration: TabDecoration?, skipIfActive: Bool)

    /// 清除 Tab 装饰
    ///
    /// 等同于 setTabDecoration(terminalId:, decoration: nil)
    ///
    /// - Parameter terminalId: 目标终端 ID
    func clearTabDecoration(terminalId: Int)

    /// 检查指定终端是否是当前 active 的
    ///
    /// - Parameter terminalId: 目标终端 ID
    /// - Returns: 如果是当前 active 的返回 true
    func isTerminalActive(terminalId: Int) -> Bool

    // MARK: - Tab Slot API

    /// 注册 Tab Slot
    ///
    /// 在 Tab 的 title 和 close 按钮之间注入自定义视图。
    /// 插件可以用这个显示状态图标、徽章等。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID（唯一标识）
    ///   - priority: 优先级（数字大 = 靠左/优先显示）
    ///   - viewProvider: 视图提供者，接收 Tab，返回 nil 表示该 Tab 不显示此 slot
    func registerTabSlot(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Tab) -> AnyView?
    )

    /// 注销插件的所有 Tab Slot
    /// - Parameter pluginId: 插件 ID
    func unregisterTabSlots(for pluginId: String)

    // MARK: - Page Slot API

    /// 注册 Page Slot
    ///
    /// 在 Page 的 title 和 close 按钮之间注入自定义视图。
    /// 插件可以用这个显示状态统计（如思考中的 tab 数量、已完成的 tab 数量等）。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID（唯一标识）
    ///   - priority: 优先级（数字大 = 靠左/优先显示）
    ///   - viewProvider: 视图提供者，接收 Page，返回 nil 表示该 Page 不显示此 slot
    func registerPageSlot(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Page) -> AnyView?
    )

    /// 注销插件的所有 Page Slot
    /// - Parameter pluginId: 插件 ID
    func unregisterPageSlots(for pluginId: String)

    // MARK: - Tab 标题 API

    /// 设置 Tab 标题（插件覆盖）
    ///
    /// 插件可以通过此 API 覆盖 Tab 的系统标题（目录名/进程名）。
    /// 覆盖后的标题优先显示，直到被清除或进程退出时自动恢复。
    ///
    /// - Parameters:
    ///   - terminalId: 目标终端 ID
    ///   - title: 插件标题
    func setTabTitle(terminalId: Int, title: String)

    /// 清除 Tab 标题（恢复系统标题）
    ///
    /// 清除插件设置的标题，恢复显示系统标题（目录名/进程名）。
    ///
    /// - Parameter terminalId: 目标终端 ID
    func clearTabTitle(terminalId: Int)
}
