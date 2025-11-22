//
//  TerminalPoolWrapper.swift
//  ETerm
//
//  Terminal Pool 的 Swift 封装（简化架构）
//
//  职责：
//  - 管理终端池（创建、销毁终端）
//  - 读取所有终端的 PTY 输出
//  - 渲染指定终端到指定位置
//  - Swift 完全控制布局，Rust 只负责渲染
//

import Foundation

/// Terminal Pool 的 Swift 封装
class TerminalPoolWrapper: TerminalPoolProtocol {
    private(set) var handle: TerminalPoolHandle?

    // 保持对回调的强引用，防止被释放
    private var renderCallbackClosure: (() -> Void)?

    // MARK: - 初始化

    init?(sugarloaf: SugarloafWrapper) {
        guard let sugarloafHandle = sugarloaf.handle else { return nil }

        handle = terminal_pool_new(sugarloafHandle)

        guard handle != nil else { return nil }
    }

    deinit {
        if let handle = handle {
            terminal_pool_free(handle)
        }
    }

    // MARK: - 渲染回调

    /// 设置渲染回调
    /// - Parameter callback: 当 PTY 有新数据时会被调用（在 Rust 线程中）
    func setRenderCallback(_ callback: @escaping () -> Void) {
        guard let handle = handle else { return }

        // 保持对闭包的强引用
        self.renderCallbackClosure = callback

        // 将 self 作为 context 传递
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 设置 C 回调函数
        terminal_pool_set_render_callback(handle, { contextPtr in
            guard let contextPtr = contextPtr else { return }

            // 从 context 恢复 TerminalPoolWrapper 实例
            let wrapper = Unmanaged<TerminalPoolWrapper>.fromOpaque(contextPtr).takeUnretainedValue()

            // 在主线程调用 Swift 闭包
            DispatchQueue.main.async {
                wrapper.renderCallbackClosure?()
            }
        }, context)
    }

    // MARK: - 终端管理

    /// 创建新终端
    /// - Parameters:
    ///   - cols: 列数
    ///   - rows: 行数
    ///   - shell: Shell 程序路径
    /// - Returns: 终端 ID，失败返回 -1
    @discardableResult
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int {
        guard let handle = handle else { return -1 }

        return Int(shell.withCString { shellPtr in
            terminal_pool_create_terminal(handle, cols, rows, shellPtr)
        })
    }

    /// 关闭终端
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    func closeTerminal(_ terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_close_terminal(handle, terminalId) != 0
    }

    /// 获取终端数量
    /// - Returns: 终端数量
    func getTerminalCount() -> Int {
        guard let handle = handle else { return 0 }
        return Int(terminal_pool_count(handle))
    }

    // MARK: - PTY 输入输出

    /// 读取所有终端的 PTY 输出
    /// - Returns: 是否有更新
    @discardableResult
    func readAllOutputs() -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_read_all(handle) != 0
    }

    /// 写入输入到指定终端
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - data: 输入数据
    /// - Returns: 是否成功
    func writeInput(terminalId: Int, data: String) -> Bool {
        guard let handle = handle else { return false }

        return data.withCString { dataPtr in
            terminal_pool_write_input(handle, terminalId, dataPtr) != 0
        }
    }

    /// 滚动指定终端
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - deltaLines: 滚动行数（正数向上，负数向下）
    /// - Returns: 是否成功
    func scroll(terminalId: Int, deltaLines: Int32) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_scroll(handle, terminalId, deltaLines) != 0
    }

    /// 调整终端尺寸
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - cols: 新的列数
    ///   - rows: 新的行数
    /// - Returns: 是否成功
    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_resize(handle, terminalId, cols, rows) != 0
    }

    // MARK: - 光标上下文 API (Cursor Context)

    /// 设置选中范围（用于高亮渲染）
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - startRow: 起始行号
    ///   - startCol: 起始列号
    ///   - endRow: 结束行号
    ///   - endCol: 结束列号
    /// - Returns: 是否成功
    func setSelection(
        terminalId: Int,
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> Bool {
        guard let handle = handle else { return false }

        // 防御性检查：验证坐标有效性
        let maxRow: UInt16 = 10000
        let maxCol: UInt16 = 500

        guard startRow <= maxRow, endRow <= maxRow,
              startCol <= maxCol, endCol <= maxCol else {
            print("[TerminalPoolWrapper] ⚠️ setSelection: 坐标超出范围 - startRow:\(startRow) startCol:\(startCol) endRow:\(endRow) endCol:\(endCol)")
            return false
        }

        return terminal_pool_set_selection(
            handle,
            terminalId,
            startRow,
            startCol,
            endRow,
            endCol
        ) != 0
    }

    /// 清除选中高亮
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    func clearSelection(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_clear_selection(handle, terminalId) != 0
    }

    /// 获取选中范围的文本
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - startRow: 起始行号
    ///   - startCol: 起始列号
    ///   - endRow: 结束行号
    ///   - endCol: 结束列号
    /// - Returns: 选中的文本，失败返回 nil
    func getTextRange(
        terminalId: Int,
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> String? {
        guard let handle = handle else { return nil }

        // 防御性检查：验证坐标有效性
        // 行号和列号应该在合理范围内（假设最大 10000 行，500 列）
        let maxRow: UInt16 = 10000
        let maxCol: UInt16 = 500

        guard startRow <= maxRow, endRow <= maxRow,
              startCol <= maxCol, endCol <= maxCol else {
            print("[TerminalPoolWrapper] ⚠️ getTextRange: 坐标超出范围 - startRow:\(startRow) startCol:\(startCol) endRow:\(endRow) endCol:\(endCol)")
            return nil
        }

        // 分配足够大的缓冲区
        let maxChars = Int(abs(Int32(endRow) - Int32(startRow)) + 1) * 256
        let bufferSize = maxChars * 4 + 1  // UTF-8, +1 for null terminator

        var buffer = [CChar](repeating: 0, count: bufferSize)

        guard buffer.withUnsafeMutableBufferPointer({ bufferPtr in
            terminal_pool_get_text_range(
                handle,
                terminalId,
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

    /// 获取当前输入行号
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 输入行号，如果不在输入模式返回 nil
    func getInputRow(terminalId: Int) -> UInt16? {
        guard let handle = handle else { return nil }

        var row: UInt16 = 0

        guard terminal_pool_get_input_row(handle, terminalId, &row) != 0 else {
            return nil
        }

        return row
    }

    // MARK: - 渲染

    /// 渲染指定终端到指定位置
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - x: 左上角 X 坐标（Rust 坐标系，左上角为原点）
    ///   - y: 左上角 Y 坐标（Rust 坐标系）
    ///   - width: 宽度（像素）
    ///   - height: 高度（像素）
    ///   - cols: 终端列数
    ///   - rows: 终端行数
    /// - Returns: 是否成功
    func render(
        terminalId: Int,
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        cols: UInt16,
        rows: UInt16
    ) -> Bool {
        guard let handle = handle else { return false }

        return terminal_pool_render(
            handle,
            terminalId,
            x, y,
            width, height,
            cols, rows
        ) != 0
    }

    /// 统一提交所有累积的 objects
    ///
    /// 在所有 render() 调用完成后，调用此方法统一提交所有终端的渲染内容
    func flush() {
        guard let handle = handle else { return }
        terminal_pool_flush(handle)
    }
}
