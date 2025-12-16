//
//  PageBarItemRegistry.swift
//  ETerm
//
//  插件层 - PageBar 组件注册表
//

import SwiftUI
import Combine

/// PageBar 组件定义
public struct PageBarItem: Identifiable {
    public let id: String
    public let pluginId: String
    public let viewProvider: () -> AnyView

    public init(
        id: String,
        pluginId: String,
        viewProvider: @escaping () -> AnyView
    ) {
        self.id = id
        self.pluginId = pluginId
        self.viewProvider = viewProvider
    }
}

/// PageBar 组件注册表 - 管理插件注册的 PageBar 组件
final class PageBarItemRegistry: ObservableObject {
    static let shared = PageBarItemRegistry()

    /// 已注册的组件（按注册顺序）
    @Published private(set) var items: [PageBarItem] = []

    private init() {}

    /// 注册 PageBar 组件
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 组件 ID（唯一标识）
    ///   - viewProvider: 视图提供者
    func registerItem(for pluginId: String, id: String, viewProvider: @escaping () -> AnyView) {
        // 检查是否已存在
        guard !items.contains(where: { $0.id == id }) else {
            return
        }

        let item = PageBarItem(id: id, pluginId: pluginId, viewProvider: viewProvider)
        items.append(item)
    }

    /// 注销插件的所有 PageBar 组件
    /// - Parameter pluginId: 插件 ID
    func unregisterItems(for pluginId: String) {
        items.removeAll { $0.pluginId == pluginId }
    }

    /// 注销指定组件
    /// - Parameter id: 组件 ID
    func unregisterItem(id: String) {
        items.removeAll { $0.id == id }
    }
}
