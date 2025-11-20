//
//  CursorPosition.swift
//  ETerm - 光标位置值对象
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation

/// 光标位置（终端网格坐标）
///
/// 值对象特性：
/// - 不可变（Immutable）
/// - 值语义（Value Semantics）
/// - 可比较（Equatable）
struct CursorPosition: Equatable, Hashable {
    /// 列号（从 0 开始）
    let col: UInt16

    /// 行号（从 0 开始）
    let row: UInt16

    /// 创建光标位置
    init(col: UInt16, row: UInt16) {
        self.col = col
        self.row = row
    }

    /// 零位置（原点）
    static let zero = CursorPosition(col: 0, row: 0)

    /// 移动到新位置（不可变，返回新实例）
    func moveTo(col: UInt16, row: UInt16) -> CursorPosition {
        CursorPosition(col: col, row: row)
    }

    /// 判断是否在指定行
    func isOnRow(_ row: UInt16) -> Bool {
        self.row == row
    }

    /// 判断是否在指定列
    func isOnCol(_ col: UInt16) -> Bool {
        self.col == col
    }
}

// MARK: - CustomStringConvertible
extension CursorPosition: CustomStringConvertible {
    var description: String {
        "CursorPosition(col: \(col), row: \(row))"
    }
}
