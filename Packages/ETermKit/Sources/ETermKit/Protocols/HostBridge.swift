// HostBridge.swift
// ETermKit
//
// 主应用桥接协议 - 插件通过此协议调用主应用能力

import Foundation

/// 主应用桥接协议
///
/// 定义插件可以调用的主应用能力。此协议的实现由 Extension Host 提供，
/// 内部通过 IPC 与主进程通信。
///
/// 设计说明：
/// - 所有方法内部都通过 IPC 与主进程通信
/// - 接口设计为同步风格，内部实现等待 IPC 响应
/// - 调用失败时返回 nil 或静默处理，不抛出异常
///
/// Capability 检查：
/// - 每个方法对应特定的 capability
/// - 调用未声明 capability 的方法会返回权限错误
public protocol HostBridge: AnyObject, Sendable {

    // MARK: - 主应用信息

    /// 获取主应用信息
    var hostInfo: HostInfo { get }

    // MARK: - UI 更新（发送数据给 ViewModel）

    /// 更新 ViewModel 数据
    ///
    /// 向主进程发送状态更新，触发对应 ViewModel 的 `update(from:)` 方法。
    ///
    /// - Parameters:
    ///   - viewModelId: ViewModel 标识符，通常与插件 ID 相同
    ///   - data: 状态数据，必须是可序列化的类型（基本类型、数组、字典）
    func updateViewModel(_ viewModelId: String, data: [String: Any])

    // MARK: - Tab 装饰

    /// 设置 Tab 装饰
    ///
    /// 需要 capability: `ui.tabDecoration`
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - decoration: 装饰配置，传 nil 清除装饰
    func setTabDecoration(terminalId: Int, decoration: TabDecoration?)

    /// 清除 Tab 装饰
    ///
    /// 需要 capability: `ui.tabDecoration`
    ///
    /// - Parameter terminalId: 终端 ID
    func clearTabDecoration(terminalId: Int)

    // MARK: - Tab 标题

    /// 设置 Tab 标题
    ///
    /// 需要 capability: `ui.tabTitle`
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - title: 自定义标题
    func setTabTitle(terminalId: Int, title: String)

    /// 清除 Tab 标题（恢复默认）
    ///
    /// 需要 capability: `ui.tabTitle`
    ///
    /// - Parameter terminalId: 终端 ID
    func clearTabTitle(terminalId: Int)

    // MARK: - 终端操作

    /// 写入终端
    ///
    /// 需要 capability: `terminal.write`
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - data: 要写入的字符串数据
    func writeToTerminal(terminalId: Int, data: String)

    /// 获取终端信息
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 终端信息，不存在时返回 nil
    func getTerminalInfo(terminalId: Int) -> TerminalInfo?

    /// 获取所有终端列表
    ///
    /// - Returns: 当前所有终端的信息列表
    func getAllTerminals() -> [TerminalInfo]

    // MARK: - 服务注册与调用

    /// 注册服务
    ///
    /// 注册一个服务供其他插件调用。
    ///
    /// 需要 capability: `service.register`
    ///
    /// - Parameters:
    ///   - name: 服务名称，在插件范围内唯一
    ///   - handler: 服务处理函数，接收参数字典，返回结果字典
    func registerService(
        name: String,
        handler: @escaping @Sendable ([String: Any]) -> [String: Any]?
    )

    /// 调用其他插件的服务
    ///
    /// 需要 capability: `service.call`
    ///
    /// - Parameters:
    ///   - pluginId: 目标插件 ID
    ///   - name: 服务名称
    ///   - params: 调用参数
    /// - Returns: 服务返回结果，调用失败返回 nil
    func callService(
        pluginId: String,
        name: String,
        params: [String: Any]
    ) -> [String: Any]?

    // MARK: - 事件发射

    /// 发射自定义事件
    ///
    /// 发射一个事件，其他订阅了该事件的插件会收到通知。
    /// 事件名称应遵循 `plugin.<pluginId>.<eventName>` 格式。
    ///
    /// - Parameters:
    ///   - eventName: 事件名称
    ///   - payload: 事件载荷
    func emit(eventName: String, payload: [String: Any])

    // MARK: - 底部停靠视图控制

    /// 显示底部停靠视图
    ///
    /// 需要 capability: `ui.bottomDock`
    ///
    /// - Parameter id: bottomDock 的 id（manifest.json 中定义）
    func showBottomDock(_ id: String)

    /// 隐藏底部停靠视图
    ///
    /// 需要 capability: `ui.bottomDock`
    ///
    /// - Parameter id: bottomDock 的 id
    func hideBottomDock(_ id: String)

    /// 切换底部停靠视图显示状态
    ///
    /// 需要 capability: `ui.bottomDock`
    ///
    /// - Parameter id: bottomDock 的 id
    func toggleBottomDock(_ id: String)

    // MARK: - 信息面板控制

    /// 显示信息面板内容
    ///
    /// 需要 capability: `ui.infoPanel`
    ///
    /// - Parameter id: infoPanelContent 的 id（manifest.json 中定义）
    func showInfoPanel(_ id: String)

    /// 隐藏信息面板内容
    ///
    /// 需要 capability: `ui.infoPanel`
    ///
    /// - Parameter id: infoPanelContent 的 id
    func hideInfoPanel(_ id: String)

    // MARK: - 选中气泡控制

    /// 显示选中气泡（hint 模式）
    ///
    /// 需要 capability: `ui.bubble`
    ///
    /// - Parameters:
    ///   - text: 选中的文本
    ///   - position: 屏幕坐标位置
    func showBubble(text: String, position: [String: Double])

    /// 展开气泡（从 hint 变为展开状态）
    ///
    /// 需要 capability: `ui.bubble`
    func expandBubble()

    /// 隐藏气泡
    ///
    /// 需要 capability: `ui.bubble`
    func hideBubble()
}
