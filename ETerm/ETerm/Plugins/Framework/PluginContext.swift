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
protocol PluginContext: AnyObject {
    /// 命令服务
    var commands: CommandService { get }

    /// 事件服务
    var events: EventService { get }

    /// 键盘服务
    var keyboard: KeyboardService { get }

    /// UI 服务
    var ui: UIService { get }
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
}
