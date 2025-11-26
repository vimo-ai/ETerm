//
//  EventBus.swift
//  ETerm
//
//  应用层 - 事件总线实现

import Foundation

/// 事件总线 - 线程安全的事件发布/订阅实现
///
/// 使用串行队列确保线程安全
final class EventBus: EventService {
    static let shared = EventBus()

    // MARK: - 私有属性

    /// 事件订阅者存储：EventID -> [SubscriberID: Handler]
    private var subscribers: [String: [UUID: Any]] = [:]

    /// 同步队列
    private let queue = DispatchQueue(label: "com.eterm.eventbus", attributes: .concurrent)

    // MARK: - 初始化

    private init() {}

    // MARK: - EventService 实现

    func subscribe<T>(_ eventId: String, handler: @escaping (T) -> Void) -> EventSubscription {
        let subscriberId = UUID()

        // 写操作使用 barrier
        queue.async(flags: .barrier) { [weak self] in
            if self?.subscribers[eventId] == nil {
                self?.subscribers[eventId] = [:]
            }
            self?.subscribers[eventId]?[subscriberId] = handler
        }

        // 返回订阅对象
        return EventSubscription { [weak self] in
            self?.unsubscribe(eventId: eventId, subscriberId: subscriberId)
        }
    }

    func publish<T>(_ eventId: String, payload: T) {
        // 读操作
        queue.sync { [weak self] in
            guard let eventSubscribers = self?.subscribers[eventId] else {
                return
            }

            // 调用所有订阅者的处理器
            for (_, handler) in eventSubscribers {
                if let typedHandler = handler as? (T) -> Void {
                    // 在主线程执行处理器（UI 操作需要在主线程）
                    DispatchQueue.main.async {
                        typedHandler(payload)
                    }
                }
            }
        }
    }

    // MARK: - 私有方法

    /// 取消订阅
    private func unsubscribe(eventId: String, subscriberId: UUID) {
        queue.async(flags: .barrier) { [weak self] in
            self?.subscribers[eventId]?.removeValue(forKey: subscriberId)

            // 如果该事件没有订阅者了，移除事件键
            if self?.subscribers[eventId]?.isEmpty == true {
                self?.subscribers.removeValue(forKey: eventId)
            }
        }
    }
}
