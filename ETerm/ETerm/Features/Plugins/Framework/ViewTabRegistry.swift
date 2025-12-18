//
//  ViewTabRegistry.swift
//  ETerm
//
//  View Tab 注册表 - 管理 View Tab 的视图提供者
//

import Foundation
import SwiftUI

// MARK: - Notifications

extension Notification.Name {
    /// View Tab 视图已注册通知
    ///
    /// userInfo: ["viewId": String]
    static let viewTabRegistered = Notification.Name("viewTabRegistered")
}

/// View Tab 注册表 - 单例
///
/// 负责：
/// 1. 存储 View Tab 的视图提供者（viewId -> ViewProvider）
/// 2. 提供视图解析能力（供 DomainPanelView 渲染）
final class ViewTabRegistry {
    static let shared = ViewTabRegistry()

    // MARK: - View Definition

    /// View Tab 视图定义
    struct ViewDefinition {
        let viewId: String
        let pluginId: String
        let title: String
        let viewProvider: () -> AnyView
    }

    // MARK: - Private Properties

    /// 已注册的视图定义：viewId -> ViewDefinition
    private var definitions: [String: ViewDefinition] = [:]

    private init() {}

    // MARK: - Public Methods

    /// 注册 View Tab 视图
    ///
    /// - Parameter definition: 视图定义
    func register(_ definition: ViewDefinition) {
        definitions[definition.viewId] = definition

        // 通知已显示占位符的视图刷新
        NotificationCenter.default.post(
            name: .viewTabRegistered,
            object: nil,
            userInfo: ["viewId": definition.viewId]
        )
    }

    /// 获取视图定义
    ///
    /// - Parameter viewId: 视图 ID
    /// - Returns: 视图定义（如果存在）
    func getDefinition(for viewId: String) -> ViewDefinition? {
        return definitions[viewId]
    }

    /// 获取视图
    ///
    /// - Parameter viewId: 视图 ID
    /// - Returns: SwiftUI 视图（如果存在）
    func getView(for viewId: String) -> AnyView? {
        return definitions[viewId]?.viewProvider()
    }

    /// 注销视图定义
    ///
    /// - Parameter viewId: 视图 ID
    func unregister(viewId: String) {
        definitions.removeValue(forKey: viewId)
    }

    /// 注销插件的所有视图定义
    ///
    /// - Parameter pluginId: 插件 ID
    func unregisterAll(for pluginId: String) {
        definitions = definitions.filter { $0.value.pluginId != pluginId }
    }
}
