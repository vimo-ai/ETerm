//
//  TerminalWrapper.swift
//  ETerm
//
//  Terminal wrapper for FFI
//

import Foundation

/// Swift wrapper for TerminalCell
struct TerminalCellData {
    let char: Character
    let fgColor: (r: UInt8, g: UInt8, b: UInt8)
    let bgColor: (r: UInt8, g: UInt8, b: UInt8)
}

class TerminalWrapper {
    private var handle: TerminalHandle?
    let cols: UInt16
    let rows: UInt16

    init?(cols: UInt16, rows: UInt16, shell: String = "/bin/zsh") {
        let cShell = shell.cString(using: .utf8)
        guard let cShell = cShell else {
            return nil
        }

        let termHandle = terminal_create(cols, rows, cShell)
        guard termHandle != nil else {
            return nil
        }

        self.handle = termHandle
        self.cols = cols
        self.rows = rows
    }

    /// 读取 PTY 输出（非阻塞）
    /// - Returns: true 如果读取到数据
    func readOutput() -> Bool {
        guard let handle = handle else { return false }
        let result = terminal_read_output(handle)
        return result != 0
    }

    /// 写入输入到 PTY
    func writeInput(_ text: String) -> Bool {
        guard let handle = handle else { return false }
        guard let cText = text.cString(using: .utf8) else { return false }

        let result = terminal_write_input(handle, cText)
        return result != 0
    }

    /// 获取终端内容
    func getContent() -> String {
        guard let handle = handle else { return "" }

        // 分配足够大的缓冲区
        let bufferSize = Int(cols) * Int(rows) + Int(rows) + 1 // 每行 + 换行符 + null terminator
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let length = terminal_get_content(handle, &buffer, bufferSize)

        if length > 0 {
            return String(cString: buffer)
        }

        return ""
    }

    /// 获取光标位置
    func getCursorPosition() -> (row: UInt16, col: UInt16)? {
        guard let handle = handle else { return nil }

        var row: UInt16 = 0
        var col: UInt16 = 0

        let result = terminal_get_cursor(handle, &row, &col)
        if result != 0 {
            return (row, col)
        }

        return nil
    }

    /// 获取历史行数
    func getHistorySize() -> Int {
        guard let handle = handle else { return 0 }
        return terminal_get_history_size(handle)
    }

    /// 获取指定位置的单元格数据（带颜色）
    func getCell(row: UInt16, col: UInt16) -> TerminalCellData? {
        guard let handle = handle else { return nil }

        var cell = TerminalCell()
        let result = terminal_get_cell(handle, row, col, &cell)

        guard result != 0 else { return nil }

        // 将 UTF-32 转换为 Character
        let scalar = UnicodeScalar(cell.c) ?? UnicodeScalar(" ")
        let char = Character(scalar)

        return TerminalCellData(
            char: char,
            fgColor: (r: cell.fg_r, g: cell.fg_g, b: cell.fg_b),
            bgColor: (r: cell.bg_r, g: cell.bg_g, b: cell.bg_b)
        )
    }

    /// 获取指定位置的单元格（支持负数行号访问历史）
    func getCellWithScroll(row: Int32, col: UInt16) -> TerminalCellData? {
        guard let handle = handle else { return nil }

        var cell = TerminalCell()
        let result = terminal_get_cell_with_scroll(handle, row, col, &cell)

        guard result != 0 else { return nil }

        // 将 UTF-32 转换为 Character
        let scalar = UnicodeScalar(cell.c) ?? UnicodeScalar(" ")
        let char = Character(scalar)

        return TerminalCellData(
            char: char,
            fgColor: (r: cell.fg_r, g: cell.fg_g, b: cell.fg_b),
            bgColor: (r: cell.bg_r, g: cell.bg_g, b: cell.bg_b)
        )
    }

    /// 调整终端大小
    func resize(cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }

        let result = terminal_resize(handle, cols, rows)
        return result != 0
    }

    /// 滚动终端视图
    /// - Parameter deltaLines: 滚动行数（正数=向上滚动查看历史，负数=向下滚动）
    func scroll(_ deltaLines: Int32) -> Bool {
        guard let handle = handle else { return false }

        let result = terminal_scroll(handle, deltaLines)
        return result != 0
    }

    /// 渲染终端到 Sugarloaf
    func renderToSugarloaf(sugarloaf: SugarloafWrapper, richTextId: Int) -> Bool {
        guard let handle = handle else { return false }

        let result = terminal_render_to_sugarloaf(handle, sugarloaf.handle, richTextId)
        return result != 0
    }

    deinit {
        if let handle = handle {
            terminal_free(handle)
        }
    }
}
