// PluginViewModel.swift
// ETermKit
//
// 插件 ViewModel 协议 - 在主进程中运行

import Foundation
import Combine

/// 插件 ViewModel 协议
///
/// 在主进程中运行的数据容器，接收来自 Extension Host 的状态更新，
/// 驱动 SwiftUI View 刷新。
///
/// 设计说明：
/// - ViewModel 运行在主进程，崩溃会影响主应用
/// - 因此 `update(from:)` 必须实现防御性编程
/// - 所有字段更新必须使用可选解包，静默忽略无效数据
public protocol PluginViewModel: ObservableObject {

    /// 无参初始化器
    ///
    /// 主进程通过此初始化器创建 ViewModel 实例。
    init()

    /// 从 IPC 消息更新状态
    ///
    /// 接收来自 Extension Host 的状态数据，更新 @Published 属性。
    ///
    /// 实现要求（强制）：
    /// - 必须使用可选解包，不能假设数据格式正确
    /// - 必须静默忽略无效数据，绝不抛出异常
    /// - 类型不匹配时保持原值不变
    ///
    /// 示例实现：
    /// ```swift
    /// func update(from data: [String: Any]) {
    ///     if let servers = data["servers"] as? [[String: Any]] {
    ///         self.servers = servers.compactMap { ServerInfo(from: $0) }
    ///     }
    ///     if let isRunning = data["isRunning"] as? Bool {
    ///         self.isRunning = isRunning
    ///     }
    ///     // 未知字段静默忽略
    /// }
    /// ```
    ///
    /// - Parameter data: 序列化的状态数据
    func update(from data: [String: Any])
}
