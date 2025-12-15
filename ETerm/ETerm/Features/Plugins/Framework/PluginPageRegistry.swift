//
//  PluginPageRegistry.swift
//  ETerm
//
//  插件页面注册表 - 管理插件页面的定义和创建

import SwiftUI
import Combine

/// 插件页面注册表 - 单例
///
/// 负责：
/// 1. 存储插件页面的定义（pluginId -> PageDefinition）
/// 2. 提供按需创建页面的能力
/// 3. 支持打开或切换到已有插件页面
final class PluginPageRegistry {
    static let shared = PluginPageRegistry()

    // MARK: - Page Definition

    /// 插件页面定义
    struct PageDefinition {
        let pluginId: String
        let title: String
        let icon: String
        let viewProvider: () -> AnyView
    }

    // MARK: - Private Properties

    /// 已注册的页面定义：pluginId -> PageDefinition
    private var definitions: [String: PageDefinition] = [:]

    private init() {}

    // MARK: - Public Methods

    /// 注册插件页面定义
    ///
    /// - Parameter definition: 页面定义
    func register(_ definition: PageDefinition) {
        definitions[definition.pluginId] = definition
    }

    /// 获取插件页面定义
    ///
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 页面定义（如果存在）
    func getDefinition(for pluginId: String) -> PageDefinition? {
        return definitions[pluginId]
    }

    /// 打开或切换到插件页面
    ///
    /// - Parameter pluginId: 插件 ID
    func openPage(pluginId: String) {
        guard let definition = definitions[pluginId] else {
            return
        }

        DispatchQueue.main.async {
            // 获取当前激活的窗口
            guard let activeWindow = NSApp.keyWindow,
                  let coordinator = WindowManager.shared.getCoordinator(for: activeWindow.windowNumber) else {
                return
            }

            // 尝试打开或切换到插件页面
            let page = coordinator.terminalWindow.openOrSwitchToPluginPage(
                pluginId: pluginId,
                title: definition.title,
                viewProvider: definition.viewProvider
            )

            // 切换到该页面
            _ = coordinator.terminalWindow.switchToPage(page.pageId)

            // 触发 UI 更新
            coordinator.objectWillChange.send()
            coordinator.updateTrigger = UUID()

        }
    }

    /// 注销插件页面定义
    ///
    /// - Parameter pluginId: 插件 ID
    func unregister(pluginId: String) {
        if definitions.removeValue(forKey: pluginId) != nil {
        }
    }
}
