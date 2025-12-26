// SelectionAction.swift
// ETermKit
//
// 选中操作配置

import Foundation

/// 选中操作配置
///
/// 用于在终端选中文本时显示的 Popover 菜单中注册 Action。
public struct SelectionAction: Sendable, Codable, Equatable {

    /// Action ID
    ///
    /// 格式: `pluginId.actionId`，如 `com.eterm.translation.translate`
    public let id: String

    /// 显示标题
    public let title: String

    /// SF Symbol 图标名
    public let icon: String

    /// 优先级
    ///
    /// 数字越大越靠前，默认 0
    public let priority: Int

    /// 自动触发模式（可选）
    ///
    /// 当对应模式开启时，不显示 Popover，直接触发此 Action。
    /// 例如 `"translation"` 表示翻译模式开启时自动触发。
    public let autoTriggerOnMode: String?

    public init(
        id: String,
        title: String,
        icon: String,
        priority: Int = 0,
        autoTriggerOnMode: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.priority = priority
        self.autoTriggerOnMode = autoTriggerOnMode
    }
}
