//
//  EventService.swift
//  ETerm
//
//  应用层 - 事件服务协议

import Foundation

/// 事件服务协议（通过 PluginContext 暴露给插件）
///
/// 提供类型安全的事件发布/订阅机制
protocol EventService: AnyObject {

    /// 订阅事件
    ///
    /// - Parameters:
    ///   - eventType: 事件类型
    ///   - options: 订阅选项（队列、同步/异步）
    ///   - handler: 事件处理器
    /// - Returns: 订阅句柄（用于取消订阅，deinit 时自动取消）
    func subscribe<E: DomainEvent>(
        _ eventType: E.Type,
        options: SubscriptionOptions,
        handler: @escaping (E) -> Void
    ) -> EventSubscription

    /// 发射事件
    ///
    /// - Parameter event: 事件实例
    func emit<E: DomainEvent>(_ event: E)
}

// MARK: - 便捷方法

extension EventService {
    /// 订阅事件（使用默认选项：主线程异步）
    func subscribe<E: DomainEvent>(
        _ eventType: E.Type,
        handler: @escaping (E) -> Void
    ) -> EventSubscription {
        subscribe(eventType, options: .default, handler: handler)
    }
}
