//
//  ServiceRegistry.swift
//  ETerm
//
//  插件层 - 服务注册表
//
//  管理插件间的能力暴露与消费

import Foundation

/// 服务注册表 - 插件间能力共享
///
/// 设计原则：
/// - 命名空间隔离：服务 key = "{pluginId}.{serviceName}"
/// - 单例服务：同一 key 只能注册一次
/// - 强依赖：resolve 失败应由调用方处理
final class ServiceRegistry {
    static let shared = ServiceRegistry()

    // MARK: - Private Properties

    /// 服务存储：key -> service instance
    private var services: [String: Any] = [:]

    /// 线程安全锁
    private let lock = NSLock()

    private init() {}

    // MARK: - Public Methods

    /// 注册服务（带命名空间）
    ///
    /// - Parameters:
    ///   - service: 服务实例
    ///   - pluginId: 插件 ID（命名空间）
    ///   - name: 服务名称
    /// - Returns: 是否注册成功（重复注册返回 false）
    @discardableResult
    func register<T>(_ service: T, pluginId: String, name: String) -> Bool {
        let key = "\(pluginId).\(name)"

        lock.lock()
        defer { lock.unlock() }

        guard services[key] == nil else {
            print("⚠️ [ServiceRegistry] 服务已存在: \(key)")
            return false
        }

        services[key] = service
        print("📦 [ServiceRegistry] 注册服务: \(key) (\(type(of: service)))")
        return true
    }

    /// 注册插件主服务（简化版，name 默认为 "main"）
    ///
    /// - Parameters:
    ///   - service: 服务实例
    ///   - pluginId: 插件 ID
    @discardableResult
    func register<T>(_ service: T, from pluginId: String) -> Bool {
        return register(service, pluginId: pluginId, name: "main")
    }

    /// 获取服务（带命名空间）
    ///
    /// - Parameters:
    ///   - type: 服务类型
    ///   - pluginId: 插件 ID
    ///   - name: 服务名称
    /// - Returns: 服务实例（如果存在且类型匹配）
    func resolve<T>(_ type: T.Type, pluginId: String, name: String) -> T? {
        let key = "\(pluginId).\(name)"

        lock.lock()
        defer { lock.unlock() }

        guard let service = services[key] else {
            print("⚠️ [ServiceRegistry] 服务不存在: \(key)")
            return nil
        }

        guard let typed = service as? T else {
            print("⚠️ [ServiceRegistry] 类型不匹配: \(key), 期望 \(T.self), 实际 \(Swift.type(of: service))")
            return nil
        }

        return typed
    }

    /// 获取插件主服务（简化版）
    ///
    /// - Parameters:
    ///   - type: 服务类型
    ///   - pluginId: 插件 ID
    /// - Returns: 服务实例
    func resolve<T>(_ type: T.Type, from pluginId: String) -> T? {
        return resolve(type, pluginId: pluginId, name: "main")
    }

    /// 注销插件的所有服务
    ///
    /// - Parameter pluginId: 插件 ID
    func unregisterAll(for pluginId: String) {
        lock.lock()
        defer { lock.unlock() }

        let prefix = "\(pluginId)."
        let keysToRemove = services.keys.filter { $0.hasPrefix(prefix) }

        for key in keysToRemove {
            services.removeValue(forKey: key)
            print("📦 [ServiceRegistry] 注销服务: \(key)")
        }
    }

    /// 检查服务是否存在
    func hasService(pluginId: String, name: String = "main") -> Bool {
        let key = "\(pluginId).\(name)"
        lock.lock()
        defer { lock.unlock() }
        return services[key] != nil
    }
}
