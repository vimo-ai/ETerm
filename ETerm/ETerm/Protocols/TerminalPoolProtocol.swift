//
//  TerminalPoolProtocol.swift
//  ETerm
//
//  终端池协议
//
//  定义终端池的基本接口，支持多种实现：
//  - MockTerminalPool: 测试环境的模拟实现
//  - TerminalPoolWrapper: 生产环境的真实实现
//

import Foundation

/// 终端池协议
///
/// 定义终端池的核心功能：创建、销毁、查询终端实例。
/// 支持两种实现：
/// - TerminalPoolWrapper: 轮询模式（CVDisplayLink 每帧读取 PTY）
/// - EventDrivenTerminalPoolWrapper: 事件驱动模式（PTY 有数据时回调）
protocol TerminalPoolProtocol: AnyObject {

    // MARK: - 终端生命周期

    /// 创建新终端
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int

    /// 创建新终端（指定工作目录）
    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int

    /// 关闭终端
    @discardableResult
    func closeTerminal(_ terminalId: Int) -> Bool

    /// 获取终端数量
    func getTerminalCount() -> Int

    // MARK: - PTY 输入输出

    /// 写入输入到指定终端
    @discardableResult
    func writeInput(terminalId: Int, data: String) -> Bool

    /// 读取所有终端的 PTY 输出（轮询模式使用）
    /// 事件驱动模式下返回 false（PTY 线程自动读取）
    @discardableResult
    func readAllOutputs() -> Bool

    /// 滚动指定终端
    @discardableResult
    func scroll(terminalId: Int, deltaLines: Int32) -> Bool

    /// 调整终端尺寸
    @discardableResult
    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool

    // MARK: - 渲染

    /// 设置渲染回调
    /// - Parameter callback: 当 PTY 有新数据时调用
    func setRenderCallback(_ callback: @escaping () -> Void)

    /// 渲染指定终端到指定位置
    @discardableResult
    func render(
        terminalId: Int,
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        cols: UInt16,
        rows: UInt16
    ) -> Bool

    /// 提交所有累积的渲染内容
    func flush()

    /// 清除所有渲染对象（切换 Page 时使用）
    func clear()

    // MARK: - 光标和选区

    /// 获取光标位置
    func getCursorPosition(terminalId: Int) -> CursorPosition?

    /// 清除选区
    @discardableResult
    func clearSelection(terminalId: Int) -> Bool

    /// 获取当前输入行号
    func getInputRow(terminalId: Int) -> UInt16?

    // MARK: - 字体

    /// 调整字体大小
    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation)

    /// 获取字体度量（物理像素）
    ///
    /// 返回与渲染一致的字体度量：
    /// - cell_width: 单元格宽度
    /// - cell_height: 基础单元格高度（不含 line_height_factor）
    /// - line_height: 实际行高（= cell_height * line_height_factor）
    ///
    /// 鼠标坐标转换应使用 line_height（而非 cell_height）
    func getFontMetrics() -> SugarloafFontMetrics?
}

// MARK: - Mock Implementation

/// Mock 终端池（用于测试或初始化时的占位）
final class MockTerminalPool: TerminalPoolProtocol {
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int { -1 }
    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int { -1 }
    func closeTerminal(_ terminalId: Int) -> Bool { false }
    func getTerminalCount() -> Int { 0 }
    func writeInput(terminalId: Int, data: String) -> Bool { false }
    func readAllOutputs() -> Bool { false }
    func scroll(terminalId: Int, deltaLines: Int32) -> Bool { false }
    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool { false }
    func setRenderCallback(_ callback: @escaping () -> Void) {}
    func render(terminalId: Int, x: Float, y: Float, width: Float, height: Float, cols: UInt16, rows: UInt16) -> Bool { false }
    func flush() {}
    func clear() {}
    func getCursorPosition(terminalId: Int) -> CursorPosition? { nil }
    func clearSelection(terminalId: Int) -> Bool { false }
    func getInputRow(terminalId: Int) -> UInt16? { nil }
    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {}
    func getFontMetrics() -> SugarloafFontMetrics? { nil }
}
