//
//  CursorState.swift
//  ETerm - 光标状态值对象
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation

/// 光标样式
enum CursorStyle: Equatable {
    case block      // 方块（默认）
    case underline  // 下划线（IME 时常用）
    case beam       // 竖线（类似 VSCode）
}

/// 光标状态（不可变）
///
/// 封装光标的完整状态，包括位置、样式、可见性、闪烁状态
struct CursorState: Equatable {
    /// 光标位置
    let position: CursorPosition

    /// 光标样式
    let style: CursorStyle

    /// 是否可见
    let isVisible: Bool

    /// 是否闪烁
    let isBlinking: Bool

    /// 创建光标状态
    init(
        position: CursorPosition,
        style: CursorStyle = .block,
        isVisible: Bool = true,
        isBlinking: Bool = true
    ) {
        self.position = position
        self.style = style
        self.isVisible = isVisible
        self.isBlinking = isBlinking
    }

    /// 初始状态（位于原点，方块样式，可见且闪烁）
    static func initial() -> CursorState {
        CursorState(
            position: .zero,
            style: .block,
            isVisible: true,
            isBlinking: true
        )
    }

    // MARK: - 不可变转换方法（返回新实例）

    /// 移动到新位置
    func moveTo(col: UInt16, row: UInt16) -> CursorState {
        CursorState(
            position: CursorPosition(col: col, row: row),
            style: style,
            isVisible: isVisible,
            isBlinking: isBlinking
        )
    }

    /// 移动到新位置（使用 CursorPosition）
    func moveTo(position: CursorPosition) -> CursorState {
        CursorState(
            position: position,
            style: style,
            isVisible: isVisible,
            isBlinking: isBlinking
        )
    }

    /// 隐藏光标
    func hide() -> CursorState {
        CursorState(
            position: position,
            style: style,
            isVisible: false,
            isBlinking: isBlinking
        )
    }

    /// 显示光标
    func show() -> CursorState {
        CursorState(
            position: position,
            style: style,
            isVisible: true,
            isBlinking: isBlinking
        )
    }

    /// 改变样式
    func changeStyle(to newStyle: CursorStyle) -> CursorState {
        CursorState(
            position: position,
            style: newStyle,
            isVisible: isVisible,
            isBlinking: isBlinking
        )
    }

    /// 启用/禁用闪烁
    func setBlinking(_ blinking: Bool) -> CursorState {
        CursorState(
            position: position,
            style: style,
            isVisible: isVisible,
            isBlinking: blinking
        )
    }
}

// MARK: - CustomStringConvertible
extension CursorState: CustomStringConvertible {
    var description: String {
        "CursorState(pos: \(position), style: \(style), visible: \(isVisible), blinking: \(isBlinking))"
    }
}
