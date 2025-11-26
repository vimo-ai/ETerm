//
//  EventPayloads.swift
//  ETerm
//
//  应用层 - 事件数据结构定义

import AppKit

/// 终端事件常量定义
enum TerminalEvent {
    /// 选区结束事件 - 当用户完成文本选择时触发
    static let selectionEnd = "terminal.selectionEnd"

    /// 输出事件 - 当终端输出新内容时触发
    static let output = "terminal.output"
}

/// 选区结束事件的载荷数据
///
/// 当用户在终端中完成文本选择时发布
struct SelectionEndPayload {
    /// 被选中的文本内容
    let text: String

    /// 选区在屏幕上的矩形位置（用于定位弹窗）
    let screenRect: NSRect

    /// 触发选择的源视图（弱引用，避免循环引用）
    weak var sourceView: NSView?

    // MARK: - 初始化

    init(
        text: String,
        screenRect: NSRect,
        sourceView: NSView? = nil
    ) {
        self.text = text
        self.screenRect = screenRect
        self.sourceView = sourceView
    }
}
