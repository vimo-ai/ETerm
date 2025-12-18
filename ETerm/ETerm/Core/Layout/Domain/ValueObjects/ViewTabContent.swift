//
//  ViewTabContent.swift
//  ETerm
//
//  View Tab 内容 - 用于显示 SwiftUI 视图
//
//  设计说明：
//  - 轻量级，主要是标识符
//  - 视图解析由 Presentation 层的 Resolver 负责
//  - 不在领域层存储 AnyView 闭包
//

import Foundation

/// View Tab 内容
///
/// 用于在 Tab 中显示 SwiftUI 视图（如插件面板、设置页等）
final class ViewTabContent {
    // MARK: - 属性

    /// 内容 ID（唯一标识）
    let contentId: UUID

    /// 视图标识符（用于 Resolver 查找对应视图）
    let viewId: String

    /// 关联的插件 ID（可选，仅插件视图有）
    let pluginId: String?

    /// 视图参数（可选，用于传递额外信息）
    let parameters: [String: String]

    // MARK: - 初始化

    init(
        contentId: UUID = UUID(),
        viewId: String,
        pluginId: String? = nil,
        parameters: [String: String] = [:]
    ) {
        self.contentId = contentId
        self.viewId = viewId
        self.pluginId = pluginId
        self.parameters = parameters
    }

    // MARK: - 生命周期

    /// Tab 被激活时调用
    func didActivate() {
        // View 内容通常不需要特殊处理
        // 如有需要可以发送通知
    }

    /// Tab 被失活时调用
    func didDeactivate() {
        // View 内容通常不需要特殊处理
    }
}

// MARK: - 便捷构造器

extension ViewTabContent {
    /// 创建插件视图内容
    static func plugin(pluginId: String, viewId: String? = nil) -> ViewTabContent {
        ViewTabContent(
            viewId: viewId ?? pluginId,
            pluginId: pluginId
        )
    }

    /// 创建内置视图内容（如设置页）
    static func builtin(viewId: String) -> ViewTabContent {
        ViewTabContent(viewId: viewId)
    }
}

// MARK: - Equatable

extension ViewTabContent: Equatable {
    static func == (lhs: ViewTabContent, rhs: ViewTabContent) -> Bool {
        lhs.contentId == rhs.contentId
    }
}

// MARK: - Hashable

extension ViewTabContent: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(contentId)
    }
}
