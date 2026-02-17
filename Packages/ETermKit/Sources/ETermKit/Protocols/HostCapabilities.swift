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
///     // 稳定 id → 支持去重 + session 恢复
///     tabHost.createViewTab(id: "preview:\(url.path)", title: "Preview", placement: .tab) { AnyView(MyView()) }
///     // 不传 id → 临时 tab，不持久化
///     tabHost.createViewTab(title: "Temp", placement: .tab) { AnyView(MyView()) }
/// }
/// ```
public protocol ViewTabHostBridge: AnyObject {

    /// 创建 View Tab
    ///
    /// 插件通过此方法向 ETerm 提供视图并指示放置意图，ETerm 负责实际放置。
    /// 如果已存在相同 id 的 Tab，会切换到该 Tab 而不是创建新的。
    ///
    /// - Parameters:
    ///   - id: 稳定标识符，用于去重和 session 恢复。传 nil 则生成临时 id（不持久化）
    ///   - title: Tab 标题
    ///   - placement: 放置方式（.tab 在当前 Panel 新增，.page 创建独立 Page）
    ///   - viewProvider: 视图提供闭包
    func createViewTab(id: String?, title: String, placement: ViewTabPlacement, viewProvider: @escaping @MainActor () -> AnyView)
}

/// 向后兼容：不传 id 时自动生成临时 id
public extension ViewTabHostBridge {
    func createViewTab(title: String, placement: ViewTabPlacement, viewProvider: @escaping @MainActor () -> AnyView) {
        createViewTab(id: nil, title: title, placement: placement, viewProvider: viewProvider)
    }
}

// MARK: - View Tab Restore

/// View Tab 恢复能力
///
/// 插件实现此协议以支持 View Tab 的 session 恢复。
/// ETerm 在窗口恢复后会调用 `restoreViewTab`，插件根据 viewId 和 parameters 重建视图。
///
/// 使用方式：
/// ```swift
/// extension MyPlugin: ViewTabRestorable {
///     public func restoreViewTab(viewId: String, parameters: [String: String]) -> AnyView? {
///         if viewId.hasPrefix("preview:") {
///             let path = String(viewId.dropFirst("preview:".count))
///             return AnyView(PreviewView(path: path))
///         }
///         return nil
///     }
/// }
/// ```
public protocol ViewTabRestorable {
    /// 恢复 View Tab 视图
    ///
    /// - Parameters:
    ///   - viewId: 插件创建时传入的 id（不含 pluginId 前缀）
    ///   - parameters: 保存时附带的参数
    /// - Returns: 恢复的视图，返回 nil 表示无法恢复（tab 会被移除）
    @MainActor
    func restoreViewTab(viewId: String, parameters: [String: String]) -> AnyView?
}
