// TabDecoration.swift
// ETermKit
//
// Tab 装饰系统

import Foundation
import AppKit

// MARK: - 装饰优先级

/// 装饰优先级
///
/// 类型安全的优先级系统，区分系统级装饰和插件级装饰
public enum DecorationPriority: Equatable, Comparable, Sendable {
    /// 系统级装饰（保留给核心系统使用）
    case system(SystemLevel)

    /// 插件级装饰（插件使用，包含插件 ID 和优先级）
    case plugin(id: String, priority: Int)

    /// 系统级优先级
    public enum SystemLevel: Int, Comparable, Sendable {
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

// MARK: - Tab 装饰

/// Tab 装饰状态
///
/// 插件可以通过 UIService.setTabDecoration() 设置 Tab 的视觉装饰。
/// 显示时取最高优先级的装饰，Page 收敛所有 Tab 的最高优先级。
public struct TabDecoration: Equatable, @unchecked Sendable {
    /// 优先级（数值越大越优先显示）
    public let priority: DecorationPriority

    /// 装饰颜色
    public let color: NSColor

    /// 动画样式
    public let style: Style

    /// 是否序列化（插件临时状态设为 false，quit 后消失）
    public let persistent: Bool

    /// 动画样式
    public enum Style: Equatable, Sendable {
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

    /// Active 装饰（系统级，主题色低调版）
    public static let active = TabDecoration(
        priority: .system(.active),
        color: ThemeColors.accent.withAlphaComponent(0.5),
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

// MARK: - 通知

/// Tab 装饰变化通知（UI 内部事件）
///
/// userInfo:
/// - "terminal_id": Int - 目标终端 ID
/// - "decoration": TabDecoration? - 装饰状态，nil 表示清除
extension Notification.Name {
    public static let tabDecorationChanged = Notification.Name("tabDecorationChanged")
    public static let tabTitleChanged = Notification.Name("tabTitleChanged")
}
