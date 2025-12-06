//
//  KeyboardService.swift
//  ETerm
//
//  应用层 - 键盘服务协议

import Foundation

/// 键盘服务 - 快捷键绑定管理
///
/// 提供快捷键与命令的绑定机制，支持上下文条件（when 子句）
protocol KeyboardService: AnyObject {
    /// 绑定快捷键到命令
    /// - Parameters:
    ///   - keyStroke: 按键组合
    ///   - commandId: 目标命令 ID
    ///   - when: 触发条件（可选，如 "editorFocus"）
    func bind(_ keyStroke: KeyStroke, to commandId: CommandID, when: String?)

    /// 解除快捷键绑定
    /// - Parameter keyStroke: 按键组合
    func unbind(_ keyStroke: KeyStroke)
}
