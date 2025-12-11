//
//  PageContent.swift
//  ETerm
//
//  领域值对象 - 页面内容类型
//
//  定义 Page 可以包含的内容类型：
//  - 终端页面（包含 Panel 布局）
//  - 插件页面（显示 SwiftUI View）
//

import Foundation
import SwiftUI

/// 页面内容类型
enum PageContent: Equatable {
    /// 终端页面（包含 Panel 布局）
    case terminal

    /// 插件页面（显示 SwiftUI View）
    case plugin(id: String, viewProvider: () -> AnyView)

    // MARK: - Equatable

    static func == (lhs: PageContent, rhs: PageContent) -> Bool {
        switch (lhs, rhs) {
        case (.terminal, .terminal):
            return true
        case (.plugin(let id1, _), .plugin(let id2, _)):
            return id1 == id2
        default:
            return false
        }
    }
}
