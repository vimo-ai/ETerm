//
//  TerminalSession.swift
//  ETerm
//
//  基础设施层 - Terminal Session FFI 封装
//
//  职责：
//  - 封装 Terminal 相关的所有 FFI 调用
//  - 提供类型安全的 Swift 接口
//  - 处理 C 字符串/指针的转换
//  - 隐藏 FFI 实现细节
//

import Foundation

/// Terminal Session FFI 封装
///
/// 提供类型安全的终端操作接口
final class TerminalSession {
    private let handle: TerminalHandle

    // MARK: - Initialization

    init?(cols: UInt16, rows: UInt16, shell: String = "/bin/zsh") {
        guard let terminalHandle = shell.withCString({ shellPtr in
            terminal_create(cols, rows, shellPtr)
        }) else {
            return nil
        }

        self.handle = terminalHandle
    }

    deinit {
        terminal_free(handle)
    }

    // MARK: - PTY Input/Output

    /// 读取 PTY 输出（非阻塞）
    /// - Returns: 是否有新数据
    func readOutput() -> Bool {
        return terminal_read_output(handle) != 0
    }

    /// 写入输入到 PTY
    /// - Parameter data: 输入数据
    /// - Returns: 是否成功
    func writeInput(_ data: String) -> Bool {
        return data.withCString { dataPtr in
            terminal_write_input(handle, dataPtr) != 0
        }
    }

    // MARK: - Cursor Position

    /// 获取光标位置
    /// - Returns: 光标位置，失败返回 nil
    func getCursorPosition() -> CursorPosition? {
        var row: UInt16 = 0
        var col: UInt16 = 0

        guard terminal_get_cursor(handle, &row, &col) != 0 else {
            return nil
        }

        return CursorPosition(col: col, row: row)
    }

    // MARK: - Text Selection

    /// 获取指定范围的文本
    ///
    /// - Parameters:
    ///   - startRow: 起始行号
    ///   - startCol: 起始列号
    ///   - endRow: 结束行号
    ///   - endCol: 结束列号
    /// - Returns: 选中的文本，失败返回 nil
    func getTextRange(
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> String? {
        // 分配足够大的缓冲区（假设每个字符最多 4 字节 UTF-8）
        let maxChars = Int(abs(Int32(endRow) - Int32(startRow)) + 1) * 256
        let bufferSize = maxChars * 4 + 1  // +1 for null terminator

        var buffer = [CChar](repeating: 0, count: bufferSize)

        guard buffer.withUnsafeMutableBufferPointer({ bufferPtr in
            terminal_get_text_range(
                handle,
                startRow,
                startCol,
                endRow,
                endCol,
                bufferPtr.baseAddress,
                bufferSize
            ) != 0
        }) else {
            return nil
        }

        return String(cString: buffer)
    }

    /// 删除指定范围的文本（仅对当前输入行有效）
    ///
    /// - Parameters:
    ///   - startRow: 起始行号
    ///   - startCol: 起始列号
    ///   - endRow: 结束行号
    ///   - endCol: 结束列号
    /// - Returns: 是否成功
    func deleteRange(
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> Bool {
        return terminal_delete_range(
            handle,
            startRow,
            startCol,
            endRow,
            endCol
        ) != 0
    }

    /// 获取当前输入行号
    /// - Returns: 输入行号，如果不在输入模式返回 nil
    func getInputRow() -> UInt16? {
        var row: UInt16 = 0

        guard terminal_get_input_row(handle, &row) != 0 else {
            return nil
        }

        return row
    }

    /// 设置选中范围（用于高亮渲染）
    ///
    /// - Parameters:
    ///   - startRow: 起始行号
    ///   - startCol: 起始列号
    ///   - endRow: 结束行号
    ///   - endCol: 结束列号
    /// - Returns: 是否成功
    func setSelection(
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> Bool {
        return terminal_set_selection(
            handle,
            startRow,
            startCol,
            endRow,
            endCol
        ) != 0
    }

    /// 清除选中高亮
    /// - Returns: 是否成功
    func clearSelection() -> Bool {
        return terminal_clear_selection_highlight(handle) != 0
    }

    // MARK: - Terminal Control

    /// 滚动终端
    /// - Parameter deltaLines: 滚动行数（正数向上，负数向下）
    /// - Returns: 是否成功
    func scroll(deltaLines: Int32) -> Bool {
        return terminal_scroll(handle, deltaLines) != 0
    }

    /// 调整终端尺寸
    /// - Parameters:
    ///   - cols: 新的列数
    ///   - rows: 新的行数
    /// - Returns: 是否成功
    func resize(cols: UInt16, rows: UInt16) -> Bool {
        return terminal_resize(handle, cols, rows) != 0
    }

    // MARK: - Terminal Content

    /// 获取终端内容（纯文本）
    /// - Returns: 终端内容字符串
    func getContent() -> String? {
        let bufferSize = 1024 * 1024  // 1MB buffer
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let written = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            terminal_get_content(
                handle,
                bufferPtr.baseAddress,
                bufferSize
            )
        }

        guard written > 0 else {
            return nil
        }

        return String(cString: buffer)
    }

    /// 获取历史缓冲区大小
    /// - Returns: 历史行数
    func getHistorySize() -> Int {
        return terminal_get_history_size(handle)
    }

    /// 获取指定位置的单元格数据
    ///
    /// - Parameters:
    ///   - row: 行号
    ///   - col: 列号
    /// - Returns: 单元格数据，失败返回 nil
    func getCell(row: UInt16, col: UInt16) -> TerminalCell? {
        var cell = TerminalCell()

        guard terminal_get_cell(handle, row, col, &cell) != 0 else {
            return nil
        }

        return cell
    }

    /// 获取指定位置的单元格数据（支持历史缓冲区）
    ///
    /// - Parameters:
    ///   - row: 行号（可以为负数，表示历史缓冲区）
    ///   - col: 列号
    /// - Returns: 单元格数据，失败返回 nil
    func getCellWithScroll(row: Int32, col: UInt16) -> TerminalCell? {
        var cell = TerminalCell()

        guard terminal_get_cell_with_scroll(handle, row, col, &cell) != 0 else {
            return nil
        }

        return cell
    }

    // MARK: - Rendering

    /// 渲染终端到 Sugarloaf
    ///
    /// - Parameters:
    ///   - sugarloaf: Sugarloaf 句柄
    ///   - richTextId: Rich Text ID
    /// - Returns: 是否成功
    func renderToSugarloaf(sugarloaf: SugarloafHandle?, richTextId: Int) -> Bool {
        guard let sugarloaf = sugarloaf else {
            return false
        }

        return terminal_render_to_sugarloaf(handle, sugarloaf, richTextId) != 0
    }
}

// MARK: - Convenience Extensions

extension TerminalSession {
    /// 获取选中的文本（使用 TextSelection 值对象）
    ///
    /// - Parameter selection: 选中范围
    /// - Returns: 选中的文本，失败返回 nil
    func getSelectedText(selection: TextSelection) -> String? {
        let (start, end) = selection.normalized()

        return getTextRange(
            startRow: start.row,
            startCol: start.col,
            endRow: end.row,
            endCol: end.col
        )
    }

    /// 删除选中范围（使用 TextSelection 值对象）
    ///
    /// - Parameter selection: 选中范围
    /// - Returns: 是否成功
    func deleteSelection(_ selection: TextSelection) -> Bool {
        let (start, end) = selection.normalized()

        return deleteRange(
            startRow: start.row,
            startCol: start.col,
            endRow: end.row,
            endCol: end.col
        )
    }

    /// 设置选中高亮（使用 TextSelection 值对象）
    ///
    /// - Parameter selection: 选中范围
    /// - Returns: 是否成功
    func setSelection(_ selection: TextSelection) -> Bool {
        let (start, end) = selection.normalized()

        return setSelection(
            startRow: start.row,
            startCol: start.col,
            endRow: end.row,
            endCol: end.col
        )
    }
}
