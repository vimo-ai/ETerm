// PluginViewProvider.swift
// ETermKit
//
// 插件视图提供者协议 - 在主进程中运行

import Foundation
import SwiftUI

/// 插件视图提供者协议
///
/// 为 SDK 插件提供 UI 视图的入口点。实现此协议可以为插件提供：
/// - 侧边栏 Tab 视图
/// - MenuBar 状态栏视图
///
/// 此协议的实现运行在主进程中，由主应用调用以获取插件的 UI 组件。
public protocol PluginViewProvider: AnyObject {

    /// 无参初始化器
    ///
    /// 主进程通过此初始化器创建 ViewProvider 实例。
    init()

    /// 根据 tabId 返回对应的侧边栏视图
    ///
    /// - Parameter tabId: sidebarTab 的 id（manifest.json 中定义）
    /// - Returns: 对应的 SwiftUI 视图，包装为 AnyView
    func view(for tabId: String) -> AnyView

    /// 创建 MenuBar 状态栏视图
    ///
    /// 返回一个将被嵌入到 NSStatusItem 的视图。
    /// 默认实现返回 nil，表示插件不提供 MenuBar 视图。
    ///
    /// - Returns: MenuBar 视图，包装为 AnyView；返回 nil 表示不使用 MenuBar
    func createMenuBarView() -> AnyView?
}

// MARK: - Default Implementation

public extension PluginViewProvider {

    /// 默认实现：不提供 MenuBar 视图
    func createMenuBarView() -> AnyView? {
        return nil
    }
}
