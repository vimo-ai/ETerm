//
//  KeyboardEvent.swift
//  ETerm
//
//  领域层 - 键盘领域事件

/// 键盘领域事件
///
/// 表示用户通过键盘触发的领域操作
enum KeyboardEvent: Equatable {
    // ─────────────────────────────────────────
    // Window 级别 (Page 管理)
    // ─────────────────────────────────────────
    case switchToPage(index: Int)
    case nextPage
    case previousPage
    case createPage
    case closePage

    // ─────────────────────────────────────────
    // Panel 级别 (Tab 管理)
    // ─────────────────────────────────────────
    case switchToTab(index: Int)
    case nextTab
    case previousTab
    case createTab
    case closeTab
    case splitHorizontal
    case splitVertical

    // ─────────────────────────────────────────
    // Panel 焦点
    // ─────────────────────────────────────────
    case focusNextPanel
    case focusPreviousPanel

    // ─────────────────────────────────────────
    // 编辑操作
    // ─────────────────────────────────────────
    case copy
    case paste
    case selectAll
    case clearSelection

    // ─────────────────────────────────────────
    // 字体大小
    // ─────────────────────────────────────────
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize

    // ─────────────────────────────────────────
    // 辅助功能
    // ─────────────────────────────────────────
    case toggleTranslationMode

    // ─────────────────────────────────────────
    // 终端输入
    // ─────────────────────────────────────────
    case terminalInput(String)

    // ─────────────────────────────────────────
    // IME 相关
    // ─────────────────────────────────────────
    case imeCommit(String)
}
