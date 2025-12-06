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
/// - 使用真实行号（绝对坐标系统）存储选区位置
/// - 支持正向和反向选中（anchor 可能在 active 之前或之后）
/// - 判断选中是否在当前输入行
/// - 支持空选中（isEmpty）
struct TextSelection: Equatable {
    /// 起始真实行号
    let startAbsoluteRow: Int64
    let startCol: UInt16

    /// 结束真实行号
    let endAbsoluteRow: Int64
    let endCol: UInt16

    /// 是否高亮显示（Tab 切换时变灰）
    let isActive: Bool

    /// 创建文本选中
    init(
        startAbsoluteRow: Int64,
        startCol: UInt16,
        endAbsoluteRow: Int64,
        endCol: UInt16,
        isActive: Bool = true
    ) {
        self.startAbsoluteRow = startAbsoluteRow
        self.startCol = startCol
        self.endAbsoluteRow = endAbsoluteRow
        self.endCol = endCol
        self.isActive = isActive
    }

    /// 创建单点选中（起点和终点相同）
    static func single(absoluteRow: Int64, col: UInt16) -> TextSelection {
        TextSelection(
            startAbsoluteRow: absoluteRow,
            startCol: col,
            endAbsoluteRow: absoluteRow,
            endCol: col,
            isActive: true
        )
    }

    // MARK: - 计算属性

    /// 是否为空选中（起点和终点相同）
    var isEmpty: Bool {
        startAbsoluteRow == endAbsoluteRow && startCol == endCol
    }

    /// 归一化的起点和终点（确保 start <= end）
    /// 返回：(startRow, startCol, endRow, endCol)
    func normalized() -> (startRow: Int64, startCol: UInt16, endRow: Int64, endCol: UInt16) {
        // 比较行号，如果同行则比较列号
        if startAbsoluteRow < endAbsoluteRow {
            return (startAbsoluteRow, startCol, endAbsoluteRow, endCol)
        } else if startAbsoluteRow > endAbsoluteRow {
            return (endAbsoluteRow, endCol, startAbsoluteRow, startCol)
        } else {
            // 同一行，比较列号
            if startCol <= endCol {
                return (startAbsoluteRow, startCol, endAbsoluteRow, endCol)
            } else {
                return (endAbsoluteRow, endCol, startAbsoluteRow, startCol)
            }
        }
    }

    // MARK: - 业务方法

    /// 判断选中是否在当前输入行（需要转换为真实行号）
    ///
    /// 注意：此方法已废弃，因为 inputRow 是 Screen 坐标，需要外部转换为真实行号后调用
    ///
    /// - Parameter inputAbsoluteRow: 当前输入行的真实行号
    /// - Returns: 是否在输入行
    func isInCurrentInputLine(inputAbsoluteRow: Int64) -> Bool {
        let (sRow, _, eRow, _) = normalized()
        return sRow == inputAbsoluteRow && eRow == inputAbsoluteRow
    }

    /// 判断指定位置是否在选中范围内（使用真实行号）
    ///
    /// - Parameters:
    ///   - absoluteRow: 真实行号
    ///   - col: 列号
    /// - Returns: 是否在选中范围内
    func contains(absoluteRow: Int64, col: UInt16) -> Bool {
        let (sRow, sCol, eRow, eCol) = normalized()

        // 检查行号
        if absoluteRow < sRow || absoluteRow > eRow {
            return false
        }

        // 同一行
        if absoluteRow == sRow && absoluteRow == eRow {
            return col >= sCol && col <= eCol
        }

        // 起始行
        if absoluteRow == sRow {
            return col >= sCol
        }

        // 结束行
        if absoluteRow == eRow {
            return col <= eCol
        }

        // 中间行
        return true
    }

    /// 判断是否跨多行
    var isMultiLine: Bool {
        startAbsoluteRow != endAbsoluteRow
    }

    // MARK: - 不可变转换方法

    /// 更新终点（拖拽选中时使用）
    func updateEnd(absoluteRow: Int64, col: UInt16) -> TextSelection {
        TextSelection(
            startAbsoluteRow: startAbsoluteRow,
            startCol: startCol,
            endAbsoluteRow: absoluteRow,
            endCol: col,
            isActive: isActive
        )
    }

    /// 设置激活状态（Tab 切换时使用）
    func setActive(_ active: Bool) -> TextSelection {
        TextSelection(
            startAbsoluteRow: startAbsoluteRow,
            startCol: startCol,
            endAbsoluteRow: endAbsoluteRow,
            endCol: endCol,
            isActive: active
        )
    }

    /// 反转选中（交换起点和终点）
    func reversed() -> TextSelection {
        TextSelection(
            startAbsoluteRow: endAbsoluteRow,
            startCol: endCol,
            endAbsoluteRow: startAbsoluteRow,
            endCol: startCol,
            isActive: isActive
        )
    }
}

// MARK: - CustomStringConvertible
extension TextSelection: CustomStringConvertible {
    var description: String {
        let (sRow, sCol, eRow, eCol) = normalized()
        return "TextSelection(start: (\(sRow), \(sCol)), end: (\(eRow), \(eCol)), active: \(isActive))"
    }
}
