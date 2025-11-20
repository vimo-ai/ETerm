//
//  TextSelection.swift
//  ETerm - 文本选中值对象
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation

/// 文本选中（不可变）
///
/// 核心业务逻辑：
/// - 支持正向和反向选中（anchor 可能在 active 之前或之后）
/// - 判断选中是否在当前输入行
/// - 支持空选中（isEmpty）
struct TextSelection: Equatable {
    /// 起点（固定，mouseDown 位置或 Shift + 方向键开始位置）
    let anchor: CursorPosition

    /// 终点（移动，当前光标/鼠标位置）
    let active: CursorPosition

    /// 是否高亮显示（Tab 切换时变灰）
    let isActive: Bool

    /// 创建文本选中
    init(anchor: CursorPosition, active: CursorPosition, isActive: Bool = true) {
        self.anchor = anchor
        self.active = active
        self.isActive = isActive
    }

    /// 创建单点选中（起点和终点相同）
    static func single(at position: CursorPosition) -> TextSelection {
        TextSelection(anchor: position, active: position, isActive: true)
    }

    // MARK: - 计算属性

    /// 是否为空选中（起点和终点相同）
    var isEmpty: Bool {
        anchor == active
    }

    /// 归一化的起点和终点（确保 start <= end）
    /// 返回：(start, end)
    func normalized() -> (start: CursorPosition, end: CursorPosition) {
        // 比较行号，如果同行则比较列号
        if anchor.row < active.row {
            return (start: anchor, end: active)
        } else if anchor.row > active.row {
            return (start: active, end: anchor)
        } else {
            // 同一行，比较列号
            if anchor.col <= active.col {
                return (start: anchor, end: active)
            } else {
                return (start: active, end: anchor)
            }
        }
    }

    // MARK: - 业务方法

    /// 判断选中是否在当前输入行
    ///
    /// 业务规则：
    /// - 选中的起点和终点必须都在 inputRow 上
    /// - 用于决定输入时是否替换选中
    ///
    /// - Parameter inputRow: 当前输入行号
    /// - Returns: 是否在输入行
    func isInCurrentInputLine(inputRow: UInt16) -> Bool {
        let (start, end) = normalized()
        return start.row == inputRow && end.row == inputRow
    }

    /// 判断指定位置是否在选中范围内
    ///
    /// - Parameter position: 要判断的位置
    /// - Returns: 是否在选中范围内
    func contains(_ position: CursorPosition) -> Bool {
        let (start, end) = normalized()

        // 检查行号
        if position.row < start.row || position.row > end.row {
            return false
        }

        // 同一行
        if position.row == start.row && position.row == end.row {
            return position.col >= start.col && position.col <= end.col
        }

        // 起始行
        if position.row == start.row {
            return position.col >= start.col
        }

        // 结束行
        if position.row == end.row {
            return position.col <= end.col
        }

        // 中间行
        return true
    }

    /// 判断是否跨多行
    var isMultiLine: Bool {
        anchor.row != active.row
    }

    // MARK: - 不可变转换方法

    /// 更新终点（拖拽选中时使用）
    func updateActive(to newActive: CursorPosition) -> TextSelection {
        TextSelection(anchor: anchor, active: newActive, isActive: isActive)
    }

    /// 设置激活状态（Tab 切换时使用）
    func setActive(_ active: Bool) -> TextSelection {
        TextSelection(anchor: anchor, active: self.active, isActive: active)
    }

    /// 反转选中（交换起点和终点）
    func reversed() -> TextSelection {
        TextSelection(anchor: active, active: anchor, isActive: isActive)
    }
}

// MARK: - CustomStringConvertible
extension TextSelection: CustomStringConvertible {
    var description: String {
        let (start, end) = normalized()
        return "TextSelection(start: \(start), end: \(end), active: \(isActive))"
    }
}
