//
//  Plugin.swift
//  ETerm
//
//  插件层 - 插件协议定义

import Foundation

/// 插件协议 - 所有插件必须实现此协议
///
/// 插件生命周期：
/// 1. 注册：PluginManager 收集插件类型
/// 2. 排序：按依赖关系拓扑排序（Kahn 算法）
/// 3. 加载：按顺序创建实例并激活
/// 4. 停用：调用 deactivate() 清理资源
protocol Plugin: AnyObject {
    /// 插件唯一标识符（如 "english-assistant"）
    static var id: String { get }

    /// 插件显示名称（如 "英语助手"）
    static var name: String { get }

    /// 插件版本号（如 "1.0.0"）
    static var version: String { get }

    /// 依赖的插件 ID 列表（DAG 结构）
    ///
    /// PluginManager 会确保依赖的插件先加载完成
    /// 循环依赖会导致加载失败
    static var dependencies: [String] { get }

    /// 无参初始化器（PluginManager 用于创建实例）
    init()

    /// 激活插件
    ///
    /// 在此方法中应该：
    /// - 注册命令
    /// - 订阅事件
    /// - 初始化资源
    /// - 通过 context.services 注册对外暴露的能力
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

// MARK: - 默认实现

extension Plugin {
    /// 默认无依赖
    static var dependencies: [String] { [] }
}
