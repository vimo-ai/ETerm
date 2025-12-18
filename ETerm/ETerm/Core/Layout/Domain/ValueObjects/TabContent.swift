//
//  TabContent.swift
//  ETerm
//
//  Tab 内容枚举 - 定义 Tab 可承载的内容类型
//
//  设计说明：
//  - 封闭枚举，类型安全
//  - 每种内容类型有独立的实现类
//  - 便于扩展新的内容类型
//

import Foundation
import CoreGraphics

/// Tab 内容类型
enum TabContent {
    /// 终端内容
    case terminal(TerminalTabContent)

    /// 视图内容（SwiftUI View，如插件面板）
    case view(ViewTabContent)
}

// MARK: - 通用属性访问

extension TabContent {
    /// 内容 ID
    var contentId: UUID {
        switch self {
        case .terminal(let content):
            return content.contentId
        case .view(let content):
            return content.contentId
        }
    }

    /// 内容类型描述（用于调试）
    var contentTypeDescription: String {
        switch self {
        case .terminal:
            return "terminal"
        case .view(let content):
            return "view(\(content.viewId))"
        }
    }
}

// MARK: - 生命周期回调

extension TabContent {
    /// Tab 被激活时调用
    func didActivate() {
        switch self {
        case .terminal(let content):
            content.didActivate()
        case .view(let content):
            content.didActivate()
        }
    }

    /// Tab 被失活时调用
    func didDeactivate() {
        switch self {
        case .terminal(let content):
            content.didDeactivate()
        case .view(let content):
            content.didDeactivate()
        }
    }
}

// MARK: - 渲染相关

/// Tab 可渲染项
///
/// 用于渲染管线，区分不同类型的渲染目标
enum TabRenderable {
    /// 终端渲染项
    case terminal(terminalId: Int, bounds: CGRect)

    /// 视图渲染项
    case view(viewId: String, bounds: CGRect)
}

extension TabRenderable {
    /// 从 TabRenderable 数组中过滤出终端项
    ///
    /// 用于向后兼容现有的终端渲染逻辑
    static func filterTerminals(_ items: [TabRenderable]) -> [(Int, CGRect)] {
        items.compactMap { item in
            if case .terminal(let id, let bounds) = item {
                return (id, bounds)
            }
            return nil
        }
    }

    /// 从 TabRenderable 数组中过滤出视图项
    static func filterViews(_ items: [TabRenderable]) -> [(String, CGRect)] {
        items.compactMap { item in
            if case .view(let viewId, let bounds) = item {
                return (viewId, bounds)
            }
            return nil
        }
    }
}

// MARK: - Equatable

extension TabContent: Equatable {
    static func == (lhs: TabContent, rhs: TabContent) -> Bool {
        lhs.contentId == rhs.contentId
    }
}
