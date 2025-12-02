//
//  WhenClauseContext.swift
//  ETerm
//
//  应用层 - When 子句上下文

import Foundation

/// When 子句求值上下文
///
/// 提供快捷键条件判断所需的环境信息
struct WhenClauseContext {
    /// 当前键盘模式
    let mode: KeyboardMode

    /// 是否有文本选中
    let hasSelection: Bool

    /// IME 是否激活（预编辑状态）
    let imeActive: Bool

    // MARK: - 初始化

    init(
        mode: KeyboardMode = .normal,
        hasSelection: Bool = false,
        imeActive: Bool = false
    ) {
        self.mode = mode
        self.hasSelection = hasSelection
        self.imeActive = imeActive
    }
}
