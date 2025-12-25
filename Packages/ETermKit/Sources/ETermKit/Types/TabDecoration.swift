// TabDecoration.swift
// ETermKit
//
// Tab 装饰配置

import Foundation

/// Tab 装饰配置
///
/// 用于自定义终端 Tab 的视觉外观，如添加图标、徽章、颜色等。
public struct TabDecoration: Sendable, Codable, Equatable {

    /// 装饰图标
    ///
    /// SF Symbol 名称，显示在 Tab 标题前
    public var icon: String?

    /// 图标颜色
    ///
    /// 十六进制颜色值，如 "#FF5733"
    public var iconColor: String?

    /// 徽章文本
    ///
    /// 显示在 Tab 右上角的短文本，如 "3" 或 "!"
    public var badge: String?

    /// 徽章背景颜色
    public var badgeColor: String?

    /// 背景高亮颜色
    ///
    /// 用于特殊状态提示
    public var backgroundColor: String?

    /// 是否显示活动指示器
    ///
    /// 用于表示进行中的操作
    public var showActivity: Bool

    /// 初始化 Tab 装饰
    public init(
        icon: String? = nil,
        iconColor: String? = nil,
        badge: String? = nil,
        badgeColor: String? = nil,
        backgroundColor: String? = nil,
        showActivity: Bool = false
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.badge = badge
        self.badgeColor = badgeColor
        self.backgroundColor = backgroundColor
        self.showActivity = showActivity
    }
}
