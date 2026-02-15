//
//  PluginContext.swift
//  ETerm
//
//  插件层 - 服务协议定义

import Foundation
import SwiftUI
import AppKit
import ETermKit

// MARK: - Tab 装饰（从 ETermKit 重导出，保持兼容）

// 使用 ETermKit 的 TabDecoration、DecorationPriority 和 .tabDecorationChanged 通知
// 这些类型已移动到 ETermKit，此处通过 import 使其在 ETerm 模块中可用

/// 插件信息（给 UI 用）
struct PluginInfo: Identifiable {
    let id: String
    let name: String
    let version: String
    let dependencies: [String]
    let isLoaded: Bool
    let isEnabled: Bool
    /// 依赖此插件的其他插件
    let dependents: [String]
}

// MARK: - 终端服务协议

/// 终端服务协议 - 提供终端操作能力
protocol TerminalService: AnyObject {
    /// 向终端写入数据
    ///
    /// - Parameters:
    ///   - terminalId: 目标终端 ID
    ///   - data: 要写入的数据
    /// - Returns: 是否成功
    @discardableResult
    func write(terminalId: Int, data: String) -> Bool

    /// 根据 terminalId 查找 tabId
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: Tab 的 UUID string，找不到返回 nil
    func getTabId(for terminalId: Int) -> String?
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
    ///   - skipIfActive: 如果为 true，且该 terminal 是当前 active 的，则不设置装饰
    func setTabDecoration(terminalId: Int, decoration: TabDecoration?, skipIfActive: Bool)

    /// 清除 Tab 装饰
    ///
    /// 等同于 setTabDecoration(terminalId:, decoration: nil)
    ///
    /// - Parameter terminalId: 目标终端 ID
    func clearTabDecoration(terminalId: Int)

    /// 检查指定终端是否是当前 active 的
    ///
    /// - Parameter terminalId: 目标终端 ID
    /// - Returns: 如果是当前 active 的返回 true
    func isTerminalActive(terminalId: Int) -> Bool

    // MARK: - Tab Slot API

    /// 注册 Tab Slot
    ///
    /// 在 Tab 的 title 和 close 按钮之间注入自定义视图。
    /// 插件可以用这个显示状态图标、徽章等。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID（唯一标识）
    ///   - priority: 优先级（数字大 = 靠左/优先显示）
    ///   - viewProvider: 视图提供者，接收 Tab，返回 nil 表示该 Tab 不显示此 slot
    func registerTabSlot(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Tab) -> AnyView?
    )

    /// 注销插件的所有 Tab Slot
    /// - Parameter pluginId: 插件 ID
    func unregisterTabSlots(for pluginId: String)

    // MARK: - Page Slot API

    /// 注册 Page Slot
    ///
    /// 在 Page 的 title 和 close 按钮之间注入自定义视图。
    /// 插件可以用这个显示状态统计（如思考中的 tab 数量、已完成的 tab 数量等）。
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - slotId: Slot ID（唯一标识）
    ///   - priority: 优先级（数字大 = 靠左/优先显示）
    ///   - viewProvider: 视图提供者，接收 Page，返回 nil 表示该 Page 不显示此 slot
    func registerPageSlot(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Page) -> AnyView?
    )

    /// 注销插件的所有 Page Slot
    /// - Parameter pluginId: 插件 ID
    func unregisterPageSlots(for pluginId: String)

    // MARK: - Tab 标题 API

    /// 设置 Tab 标题（插件覆盖）
    ///
    /// 插件可以通过此 API 覆盖 Tab 的系统标题（目录名/进程名）。
    /// 覆盖后的标题优先显示，直到被清除或进程退出时自动恢复。
    ///
    /// - Parameters:
    ///   - terminalId: 目标终端 ID
    ///   - title: 插件标题
    func setTabTitle(terminalId: Int, title: String)

    /// 清除 Tab 标题（恢复系统标题）
    ///
    /// 清除插件设置的标题，恢复显示系统标题（目录名/进程名）。
    ///
    /// - Parameter terminalId: 目标终端 ID
    func clearTabTitle(terminalId: Int)
}
