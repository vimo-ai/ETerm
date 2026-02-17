// HostCapabilities.swift
// ETermKit
//
// Capability-specific protocols for host bridge extensions.
//
// 设计说明：
// HostBridge 协议已冻结，不再添加新的 requirement。
// 新能力通过独立 protocol 提供，插件通过 `as?` 转换检查能力可用性。
// 这避免了非 resilient 动态库的 witness table ABI 不兼容问题。

import Foundation
import SwiftUI

// MARK: - Plugin Page

/// 插件 Page 能力
///
/// 需要 capability: `ui.pluginPage`
///
/// 使用方式：
/// ```swift
/// if let pageHost = host as? PluginPageHostBridge {
///     pageHost.createPluginPage(title: "My Page") { AnyView(MyView()) }
/// }
/// ```
public protocol PluginPageHostBridge: AnyObject {

    /// 创建插件 Page（支持多实例）
    ///
    /// 每次调用都会创建一个新的 Page，不会复用已有的同类 Page。
    /// 适用于需要多开的插件页面（如文件浏览器）。
    ///
    /// - Parameters:
    ///   - title: Page 标题
    ///   - viewProvider: 视图提供闭包
    func createPluginPage(title: String, viewProvider: @escaping @MainActor () -> AnyView)
}

// MARK: - View Tab

/// View Tab 能力
///
/// 需要 capability: `ui.viewTab`
///
/// 使用方式：
/// ```swift
/// if let tabHost = host as? ViewTabHostBridge {
///     tabHost.createViewTab(title: "Preview", placement: .tab) { AnyView(MyView()) }
/// }
/// ```
public protocol ViewTabHostBridge: AnyObject {

    /// 创建 View Tab
    ///
    /// 插件通过此方法向 ETerm 提供视图并指示放置意图，ETerm 负责实际放置。
    ///
    /// - Parameters:
    ///   - title: Tab 标题
    ///   - placement: 放置方式（.tab 在当前 Panel 新增，.page 创建独立 Page）
    ///   - viewProvider: 视图提供闭包
    func createViewTab(title: String, placement: ViewTabPlacement, viewProvider: @escaping @MainActor () -> AnyView)
}
