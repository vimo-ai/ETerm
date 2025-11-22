//
//  KeyboardMode.swift
//  ETerm
//
//  领域层 - 键盘模式值对象

/// 键盘模式 - 值对象
///
/// 决定按键如何被解释
enum KeyboardMode: Equatable {
    /// 普通模式：按键发送到终端或匹配快捷键
    case normal

    /// 选中模式：鼠标拖拽选中文本时
    case selection

    /// 复制模式：Vim 风格的键盘浏览（未来扩展）
    case copyMode
}
