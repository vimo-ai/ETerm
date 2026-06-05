//
//  TextSelection.swift
//  ETerm - 文本选中值对象
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation

/// 选区锚点所在的半格（half-cell）side。
///
/// 决定边界格是否被包含：作为选区末端时，`.left` 不含该格、`.right` 含该格，
/// 起端则相反。对应 Rust 侧 `Side::Left = 0 / Right = 1`，`rawValue` 直接传 FFI。
enum CellSide: UInt8 {
    case left = 0
    case right = 1
}

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

    /// 起点/终点的半格 side（决定边界格是否包含，传给 Rust 解析）。
    /// 非像素来源（语义选词、键盘选区）用默认 start=.left / end=.right（整格闭区间）。
    let startSide: CellSide
    let endSide: CellSide

    /// 是否高亮显示（Tab 切换时变灰）
    let isActive: Bool

    /// 创建文本选中
    init(
        startAbsoluteRow: Int64,
        startCol: UInt16,
        endAbsoluteRow: Int64,
        endCol: UInt16,
        startSide: CellSide = .left,
        endSide: CellSide = .right,
        isActive: Bool = true
    ) {
        self.startAbsoluteRow = startAbsoluteRow
        self.startCol = startCol
        self.endAbsoluteRow = endAbsoluteRow
        self.endCol = endCol
        self.startSide = startSide
        self.endSide = endSide
        self.isActive = isActive
    }

    /// 创建单点选中（起点和终点相同）。
    /// 两端取 .left/.right → 解析为一整格：单击（未拖拽）即选中该格，保持既有行为。
    static func single(absoluteRow: Int64, col: UInt16) -> TextSelection {
        TextSelection(
            startAbsoluteRow: absoluteRow,
            startCol: col,
            endAbsoluteRow: absoluteRow,
            endCol: col,
            startSide: .left,
            endSide: .right,
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

    /// 更新终点（拖拽选中时使用）。
    ///
    /// 锚点（起点）始终包含按下的那一格：按拖拽方向取包含侧（锚点在前→`.left`，在后→`.right`），
    /// 与旧行为一致、不论拖拽方向。活动端（终点）跟随光标半格（`side`）以获得精确边界。
    /// 拖回锚点同格时按整格显示，避免选区瞬间变空。
    func updateEnd(absoluteRow: Int64, col: UInt16, side: CellSide = .right) -> TextSelection {
        let samePoint = (absoluteRow == startAbsoluteRow && col == startCol)
        let anchorLeading = startAbsoluteRow < absoluteRow
            || (startAbsoluteRow == absoluteRow && startCol <= col)
        let newStartSide: CellSide = samePoint ? .left : (anchorLeading ? .left : .right)
        let newEndSide: CellSide = samePoint ? .right : side
        return TextSelection(
            startAbsoluteRow: startAbsoluteRow,
            startCol: startCol,
            endAbsoluteRow: absoluteRow,
            endCol: col,
            startSide: newStartSide,
            endSide: newEndSide,
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
            startSide: startSide,
            endSide: endSide,
            isActive: active
        )
    }

    /// 反转选中（交换起点和终点，side 一并交换）
    func reversed() -> TextSelection {
        TextSelection(
            startAbsoluteRow: endAbsoluteRow,
            startCol: endCol,
            endAbsoluteRow: startAbsoluteRow,
            endCol: startCol,
            startSide: endSide,
            endSide: startSide,
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
