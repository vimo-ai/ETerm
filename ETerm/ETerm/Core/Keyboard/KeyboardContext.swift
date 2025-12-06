//
//  KeyboardContext.swift
//  ETerm
//
//  应用层 - 键盘上下文

import Foundation

/// 键盘上下文
///
/// 提供处理器需要的上下文信息
struct KeyboardContext {
    /// 当前键盘模式
    let mode: KeyboardMode

    /// 当前激活的 Panel ID
    let activePanelId: UUID?

    /// 当前激活的 Tab ID
    let activeTabId: UUID?

    /// 是否有文本选中
    let hasSelection: Bool

    /// 终端 ID
    let terminalId: UInt32?
}
