//
//  TabMetadata.swift
//  ETerm
//
//  领域值对象 - Tab 元数据

import Foundation

/// Tab 的元数据
///
/// 包含 Tab 的显示信息和创建时间
struct TabMetadata: Equatable {
    let title: String
    let createdAt: Date

    /// 创建一个新的元数据，只修改标题
    func withTitle(_ title: String) -> TabMetadata {
        TabMetadata(title: title, createdAt: createdAt)
    }

    /// 创建默认的终端 Tab 元数据
    static func defaultTerminal() -> TabMetadata {
        TabMetadata(title: "Terminal", createdAt: Date())
    }
}
