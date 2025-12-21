//
//  TerminalWindowCoordinator+Selection.swift
//  ETerm
//
//  MARK: - Text Selection
//
//  职责：终端文本选中功能
//  - 设置/清除选区
//  - 获取选中文本
//  - 光标位置查询
//

import Foundation

// MARK: - 文本选中 API (Text Selection)

extension TerminalWindowCoordinator {

    /// 设置指定终端的选中范围（用于高亮渲染）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - selection: 选中范围（使用真实行号）
    /// - Returns: 是否成功
    func setSelection(terminalId: Int, selection: TextSelection) -> Bool {
        let (startRow, startCol, endRow, endCol) = selection.normalized()

        // 使用终端池设置选区
        guard let wrapper = terminalPool as? TerminalPoolWrapper else {
            return false
        }

        let success = wrapper.setSelection(
            terminalId: terminalId,
            startAbsoluteRow: startRow,
            startCol: Int(startCol),
            endAbsoluteRow: endRow,
            endCol: Int(endCol)
        )

        if success {
            // 触发渲染更新
            renderView?.requestRender()
        }

        return success
    }

    /// 清除指定终端的选中高亮
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    func clearSelection(terminalId: Int) -> Bool {
        let success = clearSelectionInternal(terminalId: terminalId)

        if success {
            renderView?.requestRender()
        }

        return success
    }

    /// 清除选区（统一入口）
    @discardableResult
    func clearSelectionInternal(terminalId: Int) -> Bool {
        return terminalPool.clearSelection(terminalId: terminalId)
    }

    /// 获取选中的文本（不清除选区）
    ///
    /// 用于 Cmd+C 复制等场景
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 选中的文本，或 nil（无选区）
    func getSelectionText(terminalId: Int) -> String? {
        return terminalPool.getSelectionText(terminalId: terminalId)
    }

    /// 获取指定终端的当前输入行号
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 输入行号，如果不在输入模式返回 nil
    func getInputRow(terminalId: Int) -> UInt16? {
        return terminalPool.getInputRow(terminalId: terminalId)
    }

    /// 获取指定终端的光标位置
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 光标位置，失败返回 nil
    func getCursorPosition(terminalId: Int) -> CursorPosition? {
        return getCursorPositionInternal(terminalId: terminalId)
    }

    /// 获取光标位置（统一入口）
    func getCursorPositionInternal(terminalId: Int) -> CursorPosition? {
        return terminalPool.getCursorPosition(terminalId: terminalId)
    }
}
