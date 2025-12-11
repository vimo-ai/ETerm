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
    /// 点击时的回调（可选），用于直接执行操作（如打开 PluginPage）
    public let onSelect: (() -> Void)?

    public init(
        id: String,
        title: String,
        icon: String,
        viewProvider: @escaping () -> AnyView,
        onSelect: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.viewProvider = viewProvider
        self.onSelect = onSelect
    }
}

/// 插件 Tab 分组 - 用于在侧边栏显示插件分组
public struct PluginTabGroup: Identifiable {
    public let id: String           // 插件 ID
    public let pluginName: String   // 插件名称
    public let tabs: [SidebarTab]   // 该插件的 Tabs
}

/// 侧边栏注册表 - 管理插件注册的 Tab
final class SidebarRegistry: ObservableObject {
    static let shared = SidebarRegistry()

    /// 已注册的 Tab（插件 ID -> Tab 列表）
    @Published private(set) var tabs: [String: [SidebarTab]] = [:]

    /// 插件名称映射（插件 ID -> 插件名称）
    @Published private(set) var pluginNames: [String: String] = [:]

    private init() {}

    /// 注册侧边栏 Tab
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - pluginName: 插件名称
    ///   - tab: Tab 定义
    func registerTab(for pluginId: String, pluginName: String, tab: SidebarTab) {
        if tabs[pluginId] == nil {
            tabs[pluginId] = []
        }
        tabs[pluginId]?.append(tab)
        pluginNames[pluginId] = pluginName
        print("🎨 [Sidebar] 插件 \(pluginName) 注册了 Tab: \(tab.title)")
    }

    /// 注销插件的所有 Tab
    /// - Parameter pluginId: 插件 ID
    func unregisterTabs(for pluginId: String) {
        let pluginName = pluginNames[pluginId] ?? pluginId
        tabs.removeValue(forKey: pluginId)
        pluginNames.removeValue(forKey: pluginId)
        print("🎨 [Sidebar] 插件 \(pluginName) 的 Tab 已注销")
    }

    /// 获取所有已注册的 Tab（扁平化）
    var allTabs: [SidebarTab] {
        tabs.values.flatMap { $0 }
    }

    /// 获取按插件分组的 Tab 列表
    var allTabGroups: [PluginTabGroup] {
        tabs.compactMap { (pluginId, tabs) in
            guard !tabs.isEmpty else { return nil }
            return PluginTabGroup(
                id: pluginId,
                pluginName: pluginNames[pluginId] ?? pluginId,
                tabs: tabs
            )
        }.sorted { $0.pluginName < $1.pluginName }
    }
}
