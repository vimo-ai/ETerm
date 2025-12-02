//
//  KeyBindingConflict.swift
//  ETerm
//
//  应用层 - 快捷键冲突信息

import Foundation

/// 快捷键冲突信息
///
/// 当多个命令尝试绑定同一个快捷键时产生
struct KeyBindingConflict {
    /// 冲突的快捷键
    let keyStroke: KeyStroke

    /// 已存在的命令列表
    let existingCommands: [CommandID]

    /// 新尝试绑定的命令
    let newCommand: CommandID

    /// 冲突描述
    var description: String {
        """
        快捷键冲突：\(keyStroke.displayString)
        已有绑定：\(existingCommands.joined(separator: ", "))
        新绑定：\(newCommand)（被拒绝）
        """
    }
}
