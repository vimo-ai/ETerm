//
//  PluginContext.swift
//  ETerm
//
//  插件层 - 插件上下文

import Foundation

/// 插件上下文 - 聚合插件所需的系统能力
///
/// 提供插件与核心系统交互的统一接口：
/// - 命令服务：注册和执行命令
/// - 事件服务：发布和订阅事件
/// - 键盘服务：绑定快捷键
protocol PluginContext: AnyObject {
    /// 命令服务
    var commands: CommandService { get }

    /// 事件服务
    var events: EventService { get }

    /// 键盘服务
    var keyboard: KeyboardService { get }
}
