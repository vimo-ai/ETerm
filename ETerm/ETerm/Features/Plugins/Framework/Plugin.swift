//
//  Plugin.swift
//  ETerm
//
//  插件层 - 插件协议定义

import Foundation

/// 插件协议 - 所有插件必须实现此协议
///
/// 插件生命周期：
/// 1. 加载：PluginManager 创建插件实例
/// 2. 激活：调用 activate(context:) 注册命令、订阅事件
/// 3. 停用：调用 deactivate() 清理资源
protocol Plugin: AnyObject {
    /// 插件唯一标识符（如 "english-assistant"）
    static var id: String { get }

    /// 插件显示名称（如 "英语助手"）
    static var name: String { get }

    /// 插件版本号（如 "1.0.0"）
    static var version: String { get }

    /// 无参初始化器（PluginManager 用于创建实例）
    init()

    /// 激活插件
    ///
    /// 在此方法中应该：
    /// - 注册命令
    /// - 订阅事件
    /// - 初始化资源
    ///
    /// - Parameter context: 插件上下文，提供系统能力
    func activate(context: PluginContext)

    /// 停用插件
    ///
    /// 在此方法中应该：
    /// - 注销命令
    /// - 取消事件订阅
    /// - 清理资源
    func deactivate()
}
