// DevHelperViewProvider.swift
// DevHelperKit
//
// 视图提供者 - 根据 tabId 返回对应的视图

import SwiftUI
import ETermKit

/// DevHelper 视图提供者
///
/// 负责根据 sidebarTab 的 id 返回对应的 SwiftUI 视图。
/// 这是 SDK 架构中 View 层的入口点。
public final class DevHelperViewProvider {

    public init() {}

    /// 根据 tabId 返回对应的视图
    ///
    /// - Parameter tabId: sidebarTab 的 id（manifest.json 中定义）
    /// - Returns: 对应的 SwiftUI 视图，包装为 AnyView
    public func view(for tabId: String) -> AnyView {
        switch tabId {
        case "dev-helper-entry":
            return AnyView(DevHelperView())
        default:
            // 未知的 tabId，返回空视图
            return AnyView(EmptyView())
        }
    }
}
