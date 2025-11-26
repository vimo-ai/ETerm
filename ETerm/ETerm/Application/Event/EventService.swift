//
//  EventService.swift
//  ETerm
//
//  应用层 - 事件服务协议

import Foundation

/// 事件订阅 - 用于管理和取消订阅
///
/// 调用 unsubscribe() 可以取消订阅
final class EventSubscription {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    /// 取消订阅
    func unsubscribe() {
        cancel()
    }

    /// 自动取消订阅（当对象被释放时）
    deinit {
        cancel()
    }
}

/// 事件服务 - 发布/订阅模式的事件总线
///
/// 提供松耦合的事件通信机制，插件可以：
/// - 订阅感兴趣的事件
/// - 发布自定义事件
protocol EventService: AnyObject {
    /// 订阅事件
    /// - Parameters:
    ///   - eventId: 事件标识符
    ///   - handler: 事件处理器
    /// - Returns: 订阅对象，用于取消订阅
    func subscribe<T>(_ eventId: String, handler: @escaping (T) -> Void) -> EventSubscription

    /// 发布事件
    /// - Parameters:
    ///   - eventId: 事件标识符
    ///   - payload: 事件载荷数据
    func publish<T>(_ eventId: String, payload: T)
}
