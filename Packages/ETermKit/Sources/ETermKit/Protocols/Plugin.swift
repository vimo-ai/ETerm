// Plugin.swift
// ETermKit
//
// 插件协议 - 主进程模式使用

import Foundation
import SwiftUI

/// 插件协议（主进程模式）
///
/// 当 manifest.json 中 `runMode` 为 `main` 时使用此协议。
/// 插件的业务逻辑和 UI 全部在主进程运行，可直接交互。
///
/// 实现要求：
/// - 必须提供无参初始化器
/// - 必须使用 `@objc(ClassName)` 导出类名，与 manifest 中的 `principalClass` 一致
/// - 所有方法都在 MainActor 上调用
///
/// 示例：
/// ```swift
/// @objc(MyPlugin)
/// public final class MyPlugin: NSObject, Plugin {
///     public static var id = "com.example.my-plugin"
///
///     @Published private var data: [Item] = []
///
///     public func activate(host: HostBridge) {
///         // 初始化
///     }
///
///     public func sidebarView(for tabId: String) -> AnyView? {
///         return AnyView(MyView(data: $data))
///     }
/// }
/// ```
@MainActor
public protocol Plugin: AnyObject {

    /// 插件唯一标识符
    ///
    /// 必须与 manifest.json 中的 `id` 字段一致，采用反向域名格式。
    static var id: String { get }

    /// 无参初始化器
    ///
    /// 主进程通过此初始化器创建插件实例。
    /// 不应在初始化器中执行耗时操作或访问 HostBridge。
    init()

    // MARK: - 生命周期

    /// 激活插件
    ///
    /// 在插件被加载并准备就绪后调用。此时可以：
    /// - 初始化内部状态
    /// - 注册服务
    /// - 准备 UI 数据
    ///
    /// - Parameter host: 主应用桥接接口
    func activate(host: HostBridge)

    /// 停用插件
    ///
    /// 在插件被卸载前调用，应当：
    /// - 清理所有资源
    /// - 取消正在进行的操作
    /// - 保存需要持久化的状态
    func deactivate()

    // MARK: - 事件处理

    /// 处理事件
    ///
    /// 接收来自主应用的事件通知。
    ///
    /// - Parameters:
    ///   - eventName: 事件名称，参见 `CoreEventNames`
    ///   - payload: 事件载荷，键值对格式
    func handleEvent(_ eventName: String, payload: [String: Any])

    /// 处理命令
    ///
    /// 接收用户触发的命令（如快捷键、菜单项）。
    ///
    /// - Parameter commandId: 命令标识符
    func handleCommand(_ commandId: String)

    // MARK: - UI 提供

    /// 侧边栏视图
    ///
    /// 根据 tabId 返回对应的侧边栏视图。
    ///
    /// - Parameter tabId: sidebarTab 的 id（manifest.json 中定义）
    /// - Returns: 对应的 SwiftUI 视图；返回 nil 表示不提供该 tab
    func sidebarView(for tabId: String) -> AnyView?

    /// 底部停靠视图
    ///
    /// - Parameter id: bottomDock 的 id（manifest.json 中定义）
    /// - Returns: 底部停靠视图；返回 nil 表示不提供
    func bottomDockView(for id: String) -> AnyView?

    /// 信息面板视图
    ///
    /// - Parameter id: infoPanelContent 的 id（manifest.json 中定义）
    /// - Returns: 信息面板内容视图；返回 nil 表示不提供
    func infoPanelView(for id: String) -> AnyView?

    /// 气泡内容视图
    ///
    /// - Parameter id: bubble 的 id（manifest.json 中定义）
    /// - Returns: 气泡内容视图；返回 nil 表示不提供
    func bubbleView(for id: String) -> AnyView?

    /// MenuBar 视图
    ///
    /// - Returns: MenuBar 视图；返回 nil 表示不提供
    func menuBarView() -> AnyView?

    /// PageBar 组件视图
    ///
    /// 根据 itemId 返回对应的 PageBar 组件视图。
    /// PageBar 组件显示在 PageBar 右侧区域。
    ///
    /// - Parameter itemId: pageBarItem 的 id（manifest.json 中定义）
    /// - Returns: PageBar 组件视图；返回 nil 表示不提供
    func pageBarView(for itemId: String) -> AnyView?

    /// 窗口底部 Overlay 视图
    ///
    /// 返回显示在终端窗口底部的 Overlay 视图。
    /// 用于 Composer、搜索等需要覆盖在终端上方的 UI。
    ///
    /// - Parameter id: overlay 的 id（manifest.json 中定义）
    /// - Returns: Overlay 视图；返回 nil 表示不提供
    func windowBottomOverlayView(for id: String) -> AnyView?

    // MARK: - Slot 视图

    /// Tab Slot 视图
    ///
    /// 在 Tab 标题旁边注入自定义视图（如状态图标、徽章）。
    /// 每个 Tab 渲染时都会调用此方法，返回 nil 表示该 Tab 不显示此 Slot。
    ///
    /// - Parameters:
    ///   - slotId: Slot 的 id（manifest.json 中定义）
    ///   - tab: Tab 上下文，包含 id、terminalId、decoration 等信息
    /// - Returns: Slot 视图；返回 nil 表示不显示
    func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView?

    /// Page Slot 视图
    ///
    /// 在 Page 标题旁边注入自定义视图（如统计信息）。
    /// 每个 Page 渲染时都会调用此方法，返回 nil 表示该 Page 不显示此 Slot。
    ///
    /// - Parameters:
    ///   - slotId: Slot 的 id（manifest.json 中定义）
    ///   - page: Page 上下文，包含 id、allTabs 等信息
    /// - Returns: Slot 视图；返回 nil 表示不显示
    func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView?
}

// MARK: - Default Implementation

public extension Plugin {

    func deactivate() {
        // 默认空实现
    }

    func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 默认空实现
    }

    func handleCommand(_ commandId: String) {
        // 默认空实现
    }

    func sidebarView(for tabId: String) -> AnyView? {
        return nil
    }

    func bottomDockView(for id: String) -> AnyView? {
        return nil
    }

    func infoPanelView(for id: String) -> AnyView? {
        return nil
    }

    func bubbleView(for id: String) -> AnyView? {
        return nil
    }

    func menuBarView() -> AnyView? {
        return nil
    }

    func pageBarView(for itemId: String) -> AnyView? {
        return nil
    }

    func windowBottomOverlayView(for id: String) -> AnyView? {
        return nil
    }

    func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
        return nil
    }

    func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        return nil
    }
}
