//
//  SidebarRegistry.swift
//  ETerm
//
//  插件层 - 侧边栏 Tab 注册表

import SwiftUI
import Combine

/// 侧边栏 Tab 定义
public struct SidebarTab: Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let viewProvider: () -> AnyView

    public init(id: String, title: String, icon: String, viewProvider: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.viewProvider = viewProvider
    }
}

/// 侧边栏注册表 - 管理插件注册的 Tab
final class SidebarRegistry: ObservableObject {
    static let shared = SidebarRegistry()

    /// 已注册的 Tab（插件 ID -> Tab 列表）
    @Published private(set) var tabs: [String: [SidebarTab]] = [:]

    private init() {}

    /// 注册侧边栏 Tab
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - tab: Tab 定义
    func registerTab(for pluginId: String, tab: SidebarTab) {
        if tabs[pluginId] == nil {
            tabs[pluginId] = []
        }
        tabs[pluginId]?.append(tab)
        print("🎨 [Sidebar] 插件 \(pluginId) 注册了 Tab: \(tab.title)")
    }

    /// 注销插件的所有 Tab
    /// - Parameter pluginId: 插件 ID
    func unregisterTabs(for pluginId: String) {
        tabs.removeValue(forKey: pluginId)
        print("🎨 [Sidebar] 插件 \(pluginId) 的 Tab 已注销")
    }

    /// 获取所有已注册的 Tab（扁平化）
    var allTabs: [SidebarTab] {
        tabs.values.flatMap { $0 }
    }
}
