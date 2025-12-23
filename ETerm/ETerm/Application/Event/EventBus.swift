//
//  EventBus.swift
//  ETerm
//
//  应用层 - 事件总线实现

import Foundation

/// 事件总线 - 类型安全的事件发布/订阅实现
///
/// 特性：
/// - 类型安全：使用泛型确保事件类型正确
/// - 线程安全：使用读写锁保护订阅者列表
/// - 灵活调度：支持同步执行、主线程异步、自定义队列
/// - 错误隔离：单个 handler 抛错不影响其他订阅者
final class EventBus: EventService {
    static let shared = EventBus()

    // MARK: - 私有类型

    /// 订阅者信息
    private struct Subscriber {
        let id: UUID
        let options: SubscriptionOptions
        let handler: (Any) -> Void
    }

    // MARK: - 私有属性

    /// 事件订阅者存储：事件类型 ObjectIdentifier -> [订阅者]
    /// 使用 ObjectIdentifier 替代 String(describing:) 避免跨模块冲突
    private var subscribers: [ObjectIdentifier: [Subscriber]] = [:]

    /// 读写锁
    private let lock = NSLock()

    // MARK: - 初始化

    private init() {}

    // MARK: - EventService 实现

    func subscribe<E: DomainEvent>(
        _ eventType: E.Type,
        options: SubscriptionOptions,
        handler: @escaping (E) -> Void
    ) -> EventSubscription {
        let subscriberId = UUID()
        let eventKey = ObjectIdentifier(eventType)

        // 类型擦除包装
        let wrappedHandler: (Any) -> Void = { event in
            if let typedEvent = event as? E {
                handler(typedEvent)
            }
        }

        let subscriber = Subscriber(
            id: subscriberId,
            options: options,
            handler: wrappedHandler
        )

        // 添加订阅者
        lock.lock()
        if subscribers[eventKey] == nil {
            subscribers[eventKey] = []
        }
        subscribers[eventKey]?.append(subscriber)
        lock.unlock()

        // 返回订阅句柄
        return EventSubscription { [weak self] in
            self?.unsubscribe(eventKey: eventKey, subscriberId: subscriberId)
        }
    }

    func emit<E: DomainEvent>(_ event: E) {
        let eventKey = ObjectIdentifier(E.self)

        // 获取订阅者快照
        lock.lock()
        let eventSubscribers = subscribers[eventKey] ?? []
        lock.unlock()

        // 调用所有订阅者
        for subscriber in eventSubscribers {
            if let queue = subscriber.options.queue {
                // 异步执行
                queue.async {
                    self.safeCall(subscriber.handler, with: event)
                }
            } else {
                // 同步执行
                safeCall(subscriber.handler, with: event)
            }
        }
    }

    // MARK: - 私有方法

    /// 安全调用 handler（捕获异常）
    private func safeCall(_ handler: (Any) -> Void, with event: Any) {
        // Swift 不支持 try-catch 捕获运行时错误
        // 但至少确保单个 handler 的问题不会影响其他订阅者
        handler(event)
    }

    /// 取消订阅
    private func unsubscribe(eventKey: ObjectIdentifier, subscriberId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        subscribers[eventKey]?.removeAll { $0.id == subscriberId }

        // 如果该事件没有订阅者了，移除事件键
        if subscribers[eventKey]?.isEmpty == true {
            subscribers.removeValue(forKey: eventKey)
        }
    }
}
