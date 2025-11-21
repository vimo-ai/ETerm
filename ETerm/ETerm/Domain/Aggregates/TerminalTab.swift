//
//  TerminalTab.swift
//  ETerm - 终端 Tab 聚合根（Aggregate Root）
//
//  Created by ETerm Team on 2025/11/20.
//

import Foundation

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

    /// 终端会话（基础设施层，用于调用 Rust FFI）
    var terminalSession: TerminalSession?

    /// Rust 终端 ID（用于渲染）
    private(set) var rustTerminalId: UInt32?

    // MARK: - 初始化

    init(tabId: UUID, title: String = "Terminal", rustTerminalId: UInt32? = nil) {
        self.tabId = tabId
        self.title = title
        self.isActive = false
        self.cursorState = .initial()
        self.textSelection = nil
        self.inputState = .empty()
        self.currentInputRow = nil
        self.terminalSession = nil
        self.rustTerminalId = rustTerminalId
    }

    /// 设置 Rust 终端 ID
    func setRustTerminalId(_ terminalId: UInt32?) {
        self.rustTerminalId = terminalId
    }

    /// 设置终端会话（依赖注入）
    func setTerminalSession(_ session: TerminalSession) {
        self.terminalSession = session
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
    /// - Parameter at: 起点位置
    func startSelection(at position: CursorPosition) {
        textSelection = .single(at: position)
    }

    /// 更新选中（鼠标拖拽 或 Shift + 方向键继续）
    ///
    /// 业务规则：
    /// - 如果没有选中，先创建选中
    /// - 更新选中的终点
    ///
    /// - Parameter to: 终点位置
    func updateSelection(to position: CursorPosition) {
        if let selection = textSelection {
            textSelection = selection.updateActive(to: position)
        } else {
            // 如果没有选中，创建一个从当前光标到 position 的选中
            startSelection(at: cursorState.position)
            textSelection = textSelection?.updateActive(to: position)
        }
    }

    /// 清除选中
    func clearSelection() {
        textSelection = nil
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
    /// - Returns: 是否在输入行
    func isSelectionInInputLine() -> Bool {
        guard let selection = textSelection,
              let inputRow = currentInputRow else {
            return false
        }
        return selection.isInCurrentInputLine(inputRow: inputRow)
    }

    /// 获取选中的文本
    ///
    /// 注意：这个方法会调用基础设施层（Rust FFI）
    ///
    /// - Returns: 选中的文本，如果没有选中则返回 nil
    func getSelectedText() -> String? {
        guard let selection = textSelection,
              !selection.isEmpty,
              let session = terminalSession else {
            return nil
        }

        return session.getSelectedText(selection: selection)
    }

    // MARK: - 输入管理

    /// 插入文本（核心业务逻辑）
    ///
    /// 业务规则：
    /// 1. 如果有选中且在输入行 → 删除选中，然后插入
    /// 2. 如果有选中但在历史区 → 直接插入，不删除选中
    /// 3. 没有选中 → 直接插入
    ///
    /// - Parameter text: 要插入的文本
    func insertText(_ text: String) {
        // 规则1：检查选中
        if hasSelection() && isSelectionInInputLine() {
            // 删除选中（如果在输入行）
            deleteSelection()
        }

        // 插入文本（调用基础设施层）
        terminalSession?.writeInput(text)

        // 清除选中（如果在输入行）
        if isSelectionInInputLine() {
            clearSelection()
        }
    }

    /// 删除选中的文本（直接删除，调用 Rust FFI）
    ///
    /// 业务规则：
    /// - 只能删除输入行的选中
    /// - 历史区的选中不能删除
    func deleteSelection() {
        guard let selection = textSelection,
              let session = terminalSession else {
            return
        }

        // 只删除输入行的选中
        guard isSelectionInInputLine() else {
            return
        }

        // 调用基础设施层删除
        session.deleteSelection(selection)
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
    /// - Parameter text: 确认的文本
    func commitInput(text: String) {
        insertText(text)
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
