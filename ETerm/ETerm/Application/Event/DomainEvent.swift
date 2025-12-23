//
//  DomainEvent.swift
//  ETerm
//
//  应用层 - 领域事件协议

import Foundation

// MARK: - DomainEvent 协议

/// 领域事件基础协议
///
/// 所有事件必须实现此协议，提供类型安全的事件系统
protocol DomainEvent {
    /// 事件名称（用于日志/调试）
    static var name: String { get }

    /// Schema 版本（用于未来兼容性）
    static var schemaVersion: Int { get }

    /// 事件唯一标识
    var eventId: UUID { get }

    /// 事件发生时间戳
    var timestamp: Date { get }
}

/// 默认实现
extension DomainEvent {
    static var schemaVersion: Int { 1 }
}

// MARK: - EventMetadata

/// 事件元数据（提供 eventId 和 timestamp 的默认存储）
///
/// 使用方式：在事件结构体中包含此属性
/// ```swift
/// struct MyEvent: DomainEvent {
///     static let name = "my.event"
///     let metadata = EventMetadata()
///     var eventId: UUID { metadata.eventId }
///     var timestamp: Date { metadata.timestamp }
///     // 其他字段...
/// }
/// ```
struct EventMetadata {
    let eventId: UUID
    let timestamp: Date

    init() {
        self.eventId = UUID()
        self.timestamp = Date()
    }
}

// MARK: - SubscriptionOptions

/// 订阅选项
struct SubscriptionOptions {
    /// 执行队列（nil = 同步，在发射线程执行）
    let queue: DispatchQueue?

    /// 默认：主线程异步
    static let `default` = SubscriptionOptions(queue: .main)

    /// 同步执行（在发射事件的线程）
    static let sync = SubscriptionOptions(queue: nil)

    /// 指定队列异步执行
    static func async(on queue: DispatchQueue) -> SubscriptionOptions {
        SubscriptionOptions(queue: queue)
    }
}

// MARK: - EventSubscription

/// 订阅句柄
///
/// 用于管理事件订阅的生命周期，支持手动取消和自动取消（deinit 时）
/// 线程安全：可以在任意线程调用 unsubscribe()
final class EventSubscription {
    private let unsubscribeAction: () -> Void
    private var isUnsubscribed = false
    private let lock = NSLock()

    init(unsubscribe: @escaping () -> Void) {
        self.unsubscribeAction = unsubscribe
    }

    /// 取消订阅（线程安全）
    func unsubscribe() {
        lock.lock()
        guard !isUnsubscribed else {
            lock.unlock()
            return
        }
        isUnsubscribed = true
        lock.unlock()
        unsubscribeAction()
    }

    /// 自动取消订阅
    deinit {
        unsubscribe()
    }
}
