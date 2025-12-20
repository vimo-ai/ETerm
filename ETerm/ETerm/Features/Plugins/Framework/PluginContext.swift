//
//  PluginContext.swift
//  ETerm
//
//  插件层 - 插件上下文

import Foundation
import SwiftUI
import AppKit

// MARK: - Tab 装饰（通用机制，核心层定义）

/// Tab 装饰状态
///
/// 插件可以通过 UIService.setTabDecoration() 设置 Tab 的视觉装饰。
/// 核心层只负责渲染，不知道具体业务含义。
///
/// 示例：
/// - Claude 运行中：橙色脉冲
/// - AI 助手思考中：蓝色呼吸
/// - 任务完成：绿色静态
public struct TabDecoration: Equatable {
    /// 装饰颜色
    public let color: NSColor

    /// 动画样式
    public let style: Style

    /// 动画样式
    public enum Style: Equatable {
        /// 静态颜色（无动画）
        case solid
        /// 脉冲动画（透明度周期变化）
        case pulse
        /// 呼吸动画（颜色渐变）
        case breathing
    }

    public init(color: NSColor, style: Style = .solid) {
        self.color = color
        self.style = style
    }
}

/// Tab 装饰变化通知
///
/// userInfo:
/// - "terminal_id": Int - 目标终端 ID
/// - "decoration": TabDecoration? - 装饰状态，nil 表示清除
extension Notification.Name {
    public static let tabDecorationChanged = Notification.Name("tabDecorationChanged")
}

/// 插件上下文 - 聚合插件所需的系统能力
///
/// 提供插件与核心系统交互的统一接口：
/// - 命令服务：注册和执行命令
/// - 事件服务：发布和订阅事件
/// - 键盘服务：绑定快捷键
/// - UI 服务：注册侧边栏 Tab
/// - 服务注册表：插件间能力共享
protocol PluginContext: AnyObject {
    /// 命令服务
    var commands: CommandService { get }

    /// 事件服务
    var events: EventService { get }

    /// 键盘服务
    var keyboard: KeyboardService { get }

    /// UI 服务
    var ui: UIService { get }

    /// 服务注册表 - 插件间能力共享
    var services: ServiceRegistry { get }
}

/// View Tab 的放置方式
enum ViewTabPlacement {
    /// 分栏创建新 Panel（默认，类似 Ctrl+D）
    case split(SplitDirection)
    /// 在当前 Panel 新增 Tab（类似 Ctrl+T）
    case tab
    /// 创建独立 Page
    case page
}

/// UI 服务协议 - 提供 UI 扩展能力
protocol UIService: AnyObject {
    /// 注册侧边栏 Tab
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - pluginName: 插件名称
    ///   - tab: Tab 定义
    func registerSidebarTab(for pluginId: String, pluginName: String, tab: SidebarTab)

    /// 注销插件的所有侧边栏 Tab
    /// - Parameter pluginId: 插件 ID
    func unregisterSidebarTabs(for pluginId: String)

    /// 注册信息窗口内容
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 内容 ID（唯一标识）
    ///   - title: 内容标题
    ///   - viewProvider: 视图提供者
    func registerInfoContent(for pluginId: String, id: String, title: String, viewProvider: @escaping () -> AnyView)

    /// 注册 PageBar 组件（显示在 PageBar 右侧，翻译模式左边）
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - id: 组件 ID（唯一标识）
    ///   - viewProvider: 视图提供者
    func registerPageBarItem(
        for pluginId: String,
        id: String,
        viewProvider: @escaping () -> AnyView
    )

    /// 创建 View Tab
    ///
    /// 在当前窗口中创建一个显示自定义视图的 Tab。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - viewId: 视图标识符（用于 Session 恢复）
    ///   - title: Tab 标题
    ///   - placement: 放置方式，默认分栏
    ///   - viewProvider: SwiftUI 视图提供者
    /// - Returns: 创建的 Tab，失败返回 nil
    @discardableResult
    func createViewTab(
        for pluginId: String,
        viewId: String,
        title: String,
        placement: ViewTabPlacement,
        viewProvider: @escaping () -> AnyView
    ) -> Tab?

    /// 预注册视图 Provider（用于 Session 恢复）
    ///
    /// 插件应在 activate() 时调用此方法预注册视图，
    /// 这样 Session 恢复时能正确显示插件视图而非占位符。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - viewId: 视图标识符
    ///   - title: Tab 标题
    ///   - viewProvider: SwiftUI 视图提供者
    func registerViewProvider(
        for pluginId: String,
        viewId: String,
        title: String,
        viewProvider: @escaping () -> AnyView
    )

    // MARK: - Tab 装饰 API

    /// 设置 Tab 装饰
    ///
    /// 用于在 Tab 上显示视觉反馈（如运行状态、完成提醒等）。
    /// 核心层只负责渲染，不知道具体业务含义。
    ///
    /// - Parameters:
    ///   - terminalId: 目标终端 ID
    ///   - decoration: 装饰状态，nil 表示清除
    func setTabDecoration(terminalId: Int, decoration: TabDecoration?)

    /// 清除 Tab 装饰
    ///
    /// 等同于 setTabDecoration(terminalId:, decoration: nil)
    ///
    /// - Parameter terminalId: 目标终端 ID
    func clearTabDecoration(terminalId: Int)
}
