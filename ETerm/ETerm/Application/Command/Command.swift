//
//  Command.swift
//  ETerm
//
//  应用层 - 命令定义

import Foundation

/// 命令唯一标识符
typealias CommandID = String

/// 命令 - 表示应用中可执行的操作
///
/// 命令是插件系统的核心概念，它将用户操作（如快捷键）与具体功能解耦。
/// 每个命令都有唯一的 ID，可以被快捷键、菜单或其他方式触发。
struct Command {
    /// 唯一标识符（如 "terminal.copy"）
    let id: CommandID

    /// 显示名称（如 "复制"）
    let title: String

    /// 图标名称（可选，SF Symbols）
    let icon: String?

    /// 命令处理器 - 执行具体操作
    let handler: (CommandContext) -> Void

    // MARK: - 初始化

    init(
        id: CommandID,
        title: String,
        icon: String? = nil,
        handler: @escaping (CommandContext) -> Void
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.handler = handler
    }
}
