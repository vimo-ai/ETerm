//
//  TerminalTab.swift
//  ETerm - 终端 Tab 聚合根（Aggregate Root）
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation
import PanelLayoutKit

/// 方向枚举
enum Direction {
    case up
    case down
    case left
    case right
}

/// 终端 Tab（聚合根）
///
/// 职责：
/// - 封装光标/选中/输入的所有业务规则
/// - 保证状态一致性
/// - 发布领域事件（未来扩展）
///
/// 设计原则：
/// - 不可变状态（通过 private(set) 控制）
/// - 方法改变状态时，确保一致性
/// - 所有外部访问通过公开方法
final class TerminalTab {
    // MARK: - 基本属性

    /// Tab ID（唯一标识）
    let tabId: UUID

    /// Tab 标题
    private(set) var title: String

    /// Tab 状态（激活/未激活）
    private(set) var isActive: Bool

    // MARK: - 光标上下文的状态

    /// 光标状态
    private(set) var cursorState: CursorState

    /// 文本选中（nil 表示无选中）
    private(set) var textSelection: TextSelection?

    /// IME 输入状态
    private(set) var inputState: InputState

    /// 当前输入行号（从 Rust 同步，nil 表示不在输入模式）
    private(set) var currentInputRow: UInt16?

    /// Rust 终端 ID（用于渲染）
    /// 使用 Int 以支持 UUID 低 64 位作为稳定 ID
    private(set) var rustTerminalId: Int?

    /// 滚动偏移量（用于选区跟随）
    private(set) var displayOffset: Int = 0

    /// 待恢复的 CWD（用于 Session 恢复）
    private(set) var pendingCwd: String?

    /// 搜索信息（Tab 级别）
    private(set) var searchInfo: TabSearchInfo?

    // MARK: - 初始化

    init(tabId: UUID, title: String = "Terminal", rustTerminalId: Int? = nil) {
        self.tabId = tabId
        self.title = title
        self.isActive = false
        self.cursorState = .initial()
        self.textSelection = nil
        self.inputState = .empty()
        self.currentInputRow = nil
        self.rustTerminalId = rustTerminalId
    }

    /// 设置 Rust 终端 ID
    func setRustTerminalId(_ terminalId: Int?) {
        self.rustTerminalId = terminalId
    }

    /// 设置待恢复的 CWD（用于 Session 恢复）
    func setPendingCwd(_ cwd: String) {
        self.pendingCwd = cwd
    }

    /// 获取并清除待恢复的 CWD
    func takePendingCwd() -> String? {
        let cwd = pendingCwd
        pendingCwd = nil
        return cwd
    }

    // MARK: - Tab 管理

    /// 激活 Tab
    func activate() {
        isActive = true
        // 激活时，选中变为高亮
        if let selection = textSelection {
            textSelection = selection.setActive(true)
        }
    }

    /// 失活 Tab
    func deactivate() {
        isActive = false
        // 失活时，选中变灰
        if let selection = textSelection {
            textSelection = selection.setActive(false)
        }
    }

    /// 设置标题
    func setTitle(_ newTitle: String) {
        title = newTitle
    }

    // MARK: - 光标管理

    /// 移动光标到指定位置
    ///
    /// 业务规则：
    /// - 纯方向键移动会清除选中
    /// - 更新光标状态
    ///
    /// - Parameters:
    ///   - col: 目标列
    ///   - row: 目标行
    ///   - clearSelection: 是否清除选中（默认 true）
    func moveCursorTo(col: UInt16, row: UInt16, clearSelection: Bool = true) {
        cursorState = cursorState.moveTo(col: col, row: row)

        if clearSelection {
            self.textSelection = nil
        }
    }

    /// 更新光标位置（从 Rust 同步，不清除选中）
    func updateCursorPosition(col: UInt16, row: UInt16) {
        cursorState = cursorState.moveTo(col: col, row: row)
    }

    /// 隐藏光标
    func hideCursor() {
        cursorState = cursorState.hide()
    }

    /// 显示光标
    func showCursor() {
        cursorState = cursorState.show()
    }

    /// 改变光标样式
    func changeCursorStyle(to style: CursorStyle) {
        cursorState = cursorState.changeStyle(to: style)
    }

    /// 移动光标（方向键）
    ///
    /// 业务规则：
    /// - 纯方向键移动会清除选中
    /// - Shift + 方向键不清除选中（由外部协调器处理）
    ///
    /// - Parameter direction: 移动方向
    /// - Returns: 新的光标位置
    @discardableResult
    func moveCursor(direction: Direction) -> CursorPosition {
        let current = cursorState.position
        var newCol = current.col
        var newRow = current.row

        switch direction {
        case .up:
            newRow = newRow > 0 ? newRow - 1 : 0
        case .down:
            newRow = newRow + 1
        case .left:
            newCol = newCol > 0 ? newCol - 1 : 0
        case .right:
            newCol = newCol + 1
        }

        let newPosition = CursorPosition(col: newCol, row: newRow)
        cursorState = cursorState.moveTo(col: newCol, row: newRow)
        return newPosition
    }

    // MARK: - 文本选中管理

    /// 开始选中（鼠标按下 或 Shift + 方向键第一次）
    ///
    /// 业务规则：
    /// - 创建新的选中，起点和终点都是当前位置
    /// - 清除旧的选中
    ///
    /// - Parameters:
    ///   - absoluteRow: 起点真实行号
    ///   - col: 起点列号
    func startSelection(absoluteRow: Int64, col: UInt16) {
        textSelection = .single(absoluteRow: absoluteRow, col: col)
    }

    /// 更新选中（鼠标拖拽 或 Shift + 方向键继续）
    ///
    /// 业务规则：
    /// - 如果没有选中，先创建选中
    /// - 更新选中的终点
    ///
    /// - Parameters:
    ///   - absoluteRow: 终点真实行号
    ///   - col: 终点列号
    func updateSelection(absoluteRow: Int64, col: UInt16) {
        if let selection = textSelection {
            textSelection = selection.updateEnd(absoluteRow: absoluteRow, col: col)
        } else {
            // 如果没有选中，先创建起点，再更新终点
            // 注意：这种情况理论上不应该发生，因为应该先调用 startSelection
            textSelection = .single(absoluteRow: absoluteRow, col: col)
        }
    }

    /// 清除选中
    func clearSelection() {
        textSelection = nil
    }

    /// 更新滚动偏移量
    ///
    /// 当终端滚动时调用，记录当前的滚动位置
    /// 注意：Rust 侧的 set_selection 已经处理了 display_offset 转换，
    ///      Swift 侧不应该再次调整选区坐标
    ///
    /// - Parameter newOffset: 新的 display_offset 值
    func updateDisplayOffset(_ newOffset: Int) {
        displayOffset = newOffset
    }

    /// 是否有选中
    func hasSelection() -> Bool {
        textSelection != nil && !(textSelection?.isEmpty ?? true)
    }

    /// 判断选中是否在当前输入行
    ///
    /// 业务规则：
    /// - 用于决定输入时是否替换选中
    /// - 选中在输入行 → 输入替换
    /// - 选中在历史区 → 输入不影响
    ///
    /// 注意：需要外部传入 inputAbsoluteRow，因为 currentInputRow 是 Screen 坐标
    ///
    /// - Parameter inputAbsoluteRow: 当前输入行的真实行号
    /// - Returns: 是否在输入行
    func isSelectionInInputLine(inputAbsoluteRow: Int64) -> Bool {
        guard let selection = textSelection else {
            return false
        }
        return selection.isInCurrentInputLine(inputAbsoluteRow: inputAbsoluteRow)
    }

    // MARK: - 输入管理

    /// 插入文本（核心业务逻辑）
    ///
    /// 业务规则：
    /// 1. 如果有选中且在输入行 → 删除选中，然后插入
    /// 2. 如果有选中但在历史区 → 直接插入，不删除选中
    /// 3. 没有选中 → 直接插入
    ///
    /// 注意：
    /// - 实际的文本写入现在由 TerminalPoolProtocol 处理
    /// - 需要外部传入 inputAbsoluteRow
    ///
    /// - Parameters:
    ///   - text: 要插入的文本
    ///   - inputAbsoluteRow: 当前输入行的真实行号
    func insertText(_ text: String, inputAbsoluteRow: Int64) {
        // 规则1：检查选中
        if hasSelection() && isSelectionInInputLine(inputAbsoluteRow: inputAbsoluteRow) {
            // 删除选中（如果在输入行）
            // 实际删除由外部 TerminalPoolProtocol 处理
        }

        // 文本写入现在由 TerminalPoolProtocol 处理
        // 此方法只处理选中状态

        // 清除选中（如果在输入行）
        if isSelectionInInputLine(inputAbsoluteRow: inputAbsoluteRow) {
            clearSelection()
        }
    }

    /// 删除选中的文本
    ///
    /// 业务规则：
    /// - 只能删除输入行的选中
    /// - 历史区的选中不能删除
    ///
    /// 注意：
    /// - 实际的删除操作现在由 TerminalPoolProtocol 处理
    /// - 需要外部传入 inputAbsoluteRow
    ///
    /// - Parameter inputAbsoluteRow: 当前输入行的真实行号
    /// - Returns: 是否应该删除
    @discardableResult
    func deleteSelection(inputAbsoluteRow: Int64) -> Bool {
        guard textSelection != nil else {
            return false
        }

        // 只删除输入行的选中
        guard isSelectionInInputLine(inputAbsoluteRow: inputAbsoluteRow) else {
            return false
        }

        // 实际删除由 TerminalPoolProtocol 处理
        // 此方法只返回是否应该删除
        return true
    }

    // MARK: - IME 管理

    /// 更新预编辑文本（Preedit）
    ///
    /// - Parameters:
    ///   - text: 预编辑文本（拼音）
    ///   - cursor: 光标位置
    func updatePreedit(text: String, cursor: Int) {
        inputState = inputState.withPreedit(text: text, cursor: cursor)
    }

    /// 确认输入（Commit）
    ///
    /// 业务规则：
    /// - 内部调用 insertText（会自动处理选中替换）
    /// - 清除 preedit
    ///
    /// - Parameters:
    ///   - text: 确认的文本
    ///   - inputAbsoluteRow: 当前输入行的真实行号
    func commitInput(text: String, inputAbsoluteRow: Int64) {
        insertText(text, inputAbsoluteRow: inputAbsoluteRow)
        clearPreedit()
    }

    /// 取消预编辑
    func cancelPreedit() {
        inputState = inputState.clearPreedit()
    }

    /// 清除预编辑
    private func clearPreedit() {
        inputState = inputState.clearPreedit()
    }

    // MARK: - 状态同步（从 Rust）

    /// 从 Rust 同步状态
    ///
    /// - Parameters:
    ///   - cursorPos: 光标位置
    ///   - inputRow: 输入行号（nil 表示不在输入模式）
    func syncFromRust(cursorPos: CursorPosition, inputRow: UInt16?) {
        updateCursorPosition(col: cursorPos.col, row: cursorPos.row)
        currentInputRow = inputRow
    }

    /// 同步输入行号
    func syncInputRow(_ row: UInt16?) {
        currentInputRow = row
    }

    // MARK: - Search Management

    /// 设置搜索信息
    func setSearchInfo(_ info: TabSearchInfo?) {
        searchInfo = info
    }

    /// 更新搜索索引（保持 pattern 不变）
    func updateSearchIndex(currentIndex: Int, totalCount: Int) {
        guard let info = searchInfo else { return }
        searchInfo = TabSearchInfo(
            pattern: info.pattern,
            totalCount: totalCount,
            currentIndex: currentIndex
        )
    }
}

// MARK: - CustomStringConvertible
extension TerminalTab: CustomStringConvertible {
    var description: String {
        """
        TerminalTab(
          id: \(tabId),
          title: "\(title)",
          active: \(isActive),
          cursor: \(cursorState),
          selection: \(textSelection?.description ?? "nil"),
          input: \(inputState)
        )
        """
    }
}

// MARK: - Identifiable (SwiftUI 支持)
extension TerminalTab: Identifiable {
    var id: UUID { tabId }
}

// MARK: - UUID Stable ID Extension
extension UUID {
    /// 从 UUID 生成稳定的 Int ID（用于传递给 Rust）
    ///
    /// 使用 UUID 的低 31 位作为稳定 ID（确保正数且在 Int32 范围内）
    /// 这确保了同一个 UUID 在重启后仍然映射到相同的数字 ID
    /// 冲突概率：约 21 亿个唯一值，对终端数量绝对足够
    var stableId: Int {
        let (_, _, _, _, _, _, _, _, _, _, _, _, b12, b13, b14, b15) = uuid
        // 使用 UUID 的低 32 位（后 4 个字节）
        let low32: UInt32 =
            UInt32(b12) << 24 |
            UInt32(b13) << 16 |
            UInt32(b14) << 8 |
            UInt32(b15)
        // 取低 31 位，确保是正数且在 Int32 范围内
        return Int(low32 & 0x7FFFFFFF)
    }
}
