//
//  ViewTabPlacement.swift
//  ETermKit
//
//  View Tab 放置方式 - 插件通过此枚举指示 ETerm 如何放置视图

import Foundation

/// View Tab 放置方式
///
/// 插件通过此枚举向 ETerm 表达放置意图，ETerm 负责实际执行放置操作。
///
/// - `tab`: 在当前 Panel 新增 Tab（类似 Ctrl+T）
/// - `page`: 创建独立 Page
public enum ViewTabPlacement: Sendable {
    /// 在当前 Panel 新增 Tab
    ///
    /// 如果当前处于 Plugin Page（无 Panel），ETerm 会自动切到最近的 Terminal Page 添加。
    case tab

    /// 创建独立 Page
    case page
}
