//
//  PluginContext.swift
//  ETerm
//
//  插件层 - 插件上下文

import Foundation
import SwiftUI

/// 插件上下文 - 聚合插件所需的系统能力
///
/// 提供插件与核心系统交互的统一接口：
/// - 命令服务：注册和执行命令
/// - 事件服务：发布和订阅事件
/// - 键盘服务：绑定快捷键
/// - UI 服务：注册侧边栏 Tab
/// - 服务注册表：插件间能力共享
protocol PluginContext: AnyObject {
    /// 命令服务
    var commands: CommandService { get }

    /// 事件服务
    var events: EventService { get }

    /// 键盘服务
    var keyboard: KeyboardService { get }

    /// UI 服务
    var ui: UIService { get }

    /// 服务注册表 - 插件间能力共享
    var services: ServiceRegistry { get }
}

/// UI 服务协议 - 提供 UI 扩展能力
protocol UIService: AnyObject {
    /// 注册侧边栏 Tab
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - pluginName: 插件名称
    ///   - tab: Tab 定义
    func registerSidebarTab(for pluginId: String, pluginName: String, tab: SidebarTab)

    /// 注销插件的所有侧边栏 Tab
    /// - Parameter pluginId: 插件 ID
    func unregisterSidebarTabs(for pluginId: String)

    /// 注册信息窗口内容
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 内容 ID（唯一标识）
    ///   - title: 内容标题
    ///   - viewProvider: 视图提供者
    func registerInfoContent(for pluginId: String, id: String, title: String, viewProvider: @escaping () -> AnyView)

    /// 注册插件页面（显示在 PageBar 上，与终端 Page 同层级）
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - title: 页面标题
    ///   - icon: 图标名称（SF Symbols）
    ///   - viewProvider: 视图提供者
    func registerPage(for pluginId: String, title: String, icon: String, viewProvider: @escaping () -> AnyView)

    /// 注册插件页面入口（在侧边栏显示按钮，点击后打开 PluginPage）
    ///
    /// 与 registerPage 的区别：
    /// - registerPage：直接创建并打开 Page（一次性）
    /// - registerPluginPageEntry：注册入口按钮，可多次打开/切换到 Page
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - pluginName: 插件名称
    ///   - icon: 图标名称（SF Symbols）
    ///   - viewProvider: 视图提供者
    func registerPluginPageEntry(
        for pluginId: String,
        pluginName: String,
        icon: String,
        viewProvider: @escaping () -> AnyView
    )

    /// 注册 PageBar 组件（显示在 PageBar 右侧，翻译模式左边）
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 组件 ID（唯一标识）
    ///   - viewProvider: 视图提供者
    func registerPageBarItem(
        for pluginId: String,
        id: String,
        viewProvider: @escaping () -> AnyView
    )
}
