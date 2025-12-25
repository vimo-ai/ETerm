// PluginLogic.swift
// ETermKit
//
// 插件逻辑协议 - 在 Extension Host 进程中运行

import Foundation

/// 插件逻辑协议
///
/// 所有插件的业务逻辑入口。此协议的实现运行在 Extension Host 独立进程中，
/// 与主应用通过 IPC 通信，确保插件崩溃不影响主应用。
///
/// 实现要求：
/// - 必须提供无参初始化器
/// - `handleEvent` 和 `handleCommand` 必须能处理未知输入，静默忽略而非崩溃
/// - 所有与主应用的通信必须通过 `HostBridge` 进行
public protocol PluginLogic: AnyObject {

    /// 插件唯一标识符
    ///
    /// 必须与 manifest.json 中的 `id` 字段一致，采用反向域名格式。
    /// 示例: `com.eterm.mcp-router`
    static var id: String { get }

    /// 无参初始化器
    ///
    /// Extension Host 通过此初始化器创建插件实例。
    /// 不应在初始化器中执行耗时操作或访问 HostBridge。
    init()

    /// 激活插件
    ///
    /// 在插件被加载并准备就绪后调用。此时可以：
    /// - 初始化内部状态
    /// - 注册服务
    /// - 发送初始 UI 数据到 ViewModel
    ///
    /// - Parameter host: 主应用桥接接口，用于调用主应用能力
    func activate(host: HostBridge)

    /// 停用插件
    ///
    /// 在插件被卸载前调用，应当：
    /// - 清理所有资源
    /// - 取消正在进行的操作
    /// - 保存需要持久化的状态
    func deactivate()

    /// 处理事件
    ///
    /// 接收来自主应用的事件通知。事件通过 IPC 传递，
    /// payload 中的数据必须是可序列化类型。
    ///
    /// 实现要求：
    /// - 必须处理未知事件名称，静默忽略
    /// - 必须处理 payload 格式不符合预期的情况
    /// - 不应抛出异常
    ///
    /// - Parameters:
    ///   - eventName: 事件名称，参见 `CoreEventNames`
    ///   - payload: 事件载荷，键值对格式
    func handleEvent(_ eventName: String, payload: [String: Any])

    /// 处理命令
    ///
    /// 接收用户触发的命令（如快捷键、菜单项）。
    /// 命令 ID 对应 manifest.json 中 `commands` 数组的 `id` 字段。
    ///
    /// 实现要求：
    /// - 必须处理未知命令 ID，静默忽略
    ///
    /// - Parameter commandId: 命令标识符
    func handleCommand(_ commandId: String)

    /// 处理请求（可选）
    ///
    /// 接收来自主应用的请求并返回结果。用于需要响应的操作。
    /// 默认实现返回空结果。
    ///
    /// - Parameters:
    ///   - requestId: 请求标识符
    ///   - params: 请求参数
    /// - Returns: 响应数据
    func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any]
}

// MARK: - Default Implementation

public extension PluginLogic {
    /// 默认实现：返回空响应
    func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        return ["success": false, "error": "Not implemented"]
    }
}
