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

/// 终端运行模式
///
/// 用于优化后台终端的性能
enum TerminalMode: UInt8 {
    /// 活跃模式（可见）
    /// - 完整 VTE 解析
    /// - 触发渲染回调
    /// - 所有事件上报
    case active = 0

    /// 后台模式（不可见）
    /// - 完整 VTE 解析（保证状态正确）
    /// - 不触发渲染回调（节省 CPU/GPU）
    /// - 仅上报关键事件（bell、exit）
    case background = 1
}

/// 终端池协议
///
/// 定义终端池的核心功能：创建、销毁、查询终端实例。
/// 实现：
/// - TerminalPoolWrapper: 生产环境实现（事件驱动 + CVDisplayLink 渲染）
/// - MockTerminalPool: 测试环境的模拟实现
protocol TerminalPoolProtocol: AnyObject {

    // MARK: - 终端生命周期

    /// 创建新终端
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int

    /// 创建新终端（指定工作目录）
    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int

    /// 创建终端（使用指定的 ID）
    ///
    /// 用于 Session 恢复，确保 ID 在重启后保持一致
    func createTerminalWithId(_ id: Int, cols: UInt16, rows: UInt16) -> Int

    /// 创建终端（使用指定的 ID + 工作目录）
    ///
    /// 用于 Session 恢复，确保 ID 在重启后保持一致
    func createTerminalWithIdAndCwd(_ id: Int, cols: UInt16, rows: UInt16, cwd: String?) -> Int

    /// 关闭终端
    @discardableResult
    func closeTerminal(_ terminalId: Int) -> Bool

    /// 获取终端数量
    func getTerminalCount() -> Int

    // MARK: - 终端迁移（跨窗口移动）

    /// 分离终端（用于跨窗口迁移）
    ///
    /// 将终端从当前池中移除，返回句柄。PTY 连接保持活跃。
    func detachTerminal(_ terminalId: Int) -> DetachedTerminalHandle?

    /// 接收分离的终端（用于跨窗口迁移）
    ///
    /// 将分离的终端添加到当前池。
    func attachTerminal(_ detached: DetachedTerminalHandle) -> Int

    // MARK: - PTY 输入输出

    /// 写入输入到指定终端
    @discardableResult
    func writeInput(terminalId: Int, data: String) -> Bool

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

    // MARK: - 工作目录

    /// 获取终端的当前工作目录（通过 proc_pidinfo 系统调用）
    ///
    /// 注意：此方法获取的是前台进程的 CWD，如果有子进程运行（如 vim、claude），
    /// 可能返回子进程的 CWD 而非 shell 的 CWD。
    /// 推荐使用 `getCachedCwd` 获取 OSC 7 缓存的 CWD。
    func getCwd(terminalId: Int) -> String?

    /// 获取终端的缓存工作目录（通过 OSC 7）
    ///
    /// Shell 通过 OSC 7 转义序列主动上报 CWD。此方法比 `getCwd` 更可靠：
    /// - 不受子进程（如 vim、claude）干扰
    /// - Shell 自己最清楚当前目录
    /// - 每次 cd 后立即更新
    ///
    /// 如果 OSC 7 缓存为空（shell 未配置或刚启动），返回 nil。
    func getCachedCwd(terminalId: Int) -> String?

    // MARK: - 进程检测

    /// 获取终端的前台进程名称
    ///
    /// 返回当前前台进程的名称（如 "vim", "cargo", "python" 等）
    /// 如果前台进程就是 shell 本身，返回 shell 名称（如 "zsh", "bash"）
    func getForegroundProcessName(terminalId: Int) -> String?

    /// 检查终端是否有正在运行的子进程（非 shell）
    ///
    /// 返回 true 如果前台进程不是 shell 本身（如正在运行 vim, cargo, python 等）
    func hasRunningProcess(terminalId: Int) -> Bool

    /// 检查终端是否启用了 Bracketed Paste Mode
    ///
    /// 当启用时（应用程序发送了 \x1b[?2004h），粘贴时应该用转义序列包裹内容。
    /// 当未启用时，直接发送原始文本。
    func isBracketedPasteEnabled(terminalId: Int) -> Bool

    /// 检查终端是否启用了 Kitty 键盘协议
    ///
    /// 应用程序通过发送 `CSI > flags u` 启用 Kitty 键盘模式。
    /// 启用后，终端应使用 Kitty 协议编码按键（如 Shift+Enter → `\x1b[13;2u`）。
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: true 表示使用 Kitty 协议，false 表示使用传统 Xterm 编码
    func isKittyKeyboardEnabled(terminalId: Int) -> Bool

    // MARK: - 光标和选区

    /// 获取光标位置
    func getCursorPosition(terminalId: Int) -> CursorPosition?

    /// 获取指定位置的单词边界（终端网格）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - screenRow: 屏幕行号（相对于可见区域，从 0 开始）
    ///   - screenCol: 屏幕列号（从 0 开始）
    /// - Returns: 单词边界信息，失败返回 nil
    func getWordAt(terminalId: Int, screenRow: Int, screenCol: Int) -> TerminalWordBoundary?

    /// 清除选区
    @discardableResult
    func clearSelection(terminalId: Int) -> Bool

    /// 获取选中的文本（不清除选区）
    ///
    /// 用于 Cmd+C 复制等场景
    func getSelectionText(terminalId: Int) -> String?

    /// 获取当前输入行号
    func getInputRow(terminalId: Int) -> UInt16?

    // MARK: - 字体

    /// 调整字体大小
    func changeFontSize(operation: FontSizeOperation)

    /// 获取字体度量（物理像素）
    ///
    /// 返回与渲染一致的字体度量：
    /// - cell_width: 单元格宽度
    /// - cell_height: 基础单元格高度（不含 line_height_factor）
    /// - line_height: 实际行高（= cell_height * line_height_factor）
    ///
    /// 鼠标坐标转换应使用 line_height（而非 cell_height）
    func getFontMetrics() -> SugarloafFontMetrics?

    // MARK: - 终端模式

    /// 设置终端运行模式
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - mode: 运行模式
    ///
    /// 切换到 Active 时会自动触发一次渲染刷新
    func setMode(terminalId: Int, mode: TerminalMode)

    /// 获取终端运行模式
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 当前模式，终端不存在时返回 nil
    func getMode(terminalId: Int) -> TerminalMode?
}

// MARK: - Mock Implementation

/// Mock 终端池（用于测试或初始化时的占位）
final class MockTerminalPool: TerminalPoolProtocol {
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int { -1 }
    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int { -1 }
    func createTerminalWithId(_ id: Int, cols: UInt16, rows: UInt16) -> Int { -1 }
    func createTerminalWithIdAndCwd(_ id: Int, cols: UInt16, rows: UInt16, cwd: String?) -> Int { -1 }
    func closeTerminal(_ terminalId: Int) -> Bool { false }
    func getTerminalCount() -> Int { 0 }
    func detachTerminal(_ terminalId: Int) -> DetachedTerminalHandle? { nil }
    func attachTerminal(_ detached: DetachedTerminalHandle) -> Int { -1 }
    func writeInput(terminalId: Int, data: String) -> Bool { false }
    func scroll(terminalId: Int, deltaLines: Int32) -> Bool { false }
    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool { false }
    func setRenderCallback(_ callback: @escaping () -> Void) {}
    func render(terminalId: Int, x: Float, y: Float, width: Float, height: Float, cols: UInt16, rows: UInt16) -> Bool { false }
    func flush() {}
    func clear() {}
    func getCwd(terminalId: Int) -> String? { nil }
    func getCachedCwd(terminalId: Int) -> String? { nil }
    func getForegroundProcessName(terminalId: Int) -> String? { nil }
    func hasRunningProcess(terminalId: Int) -> Bool { false }
    func isBracketedPasteEnabled(terminalId: Int) -> Bool { false }
    func isKittyKeyboardEnabled(terminalId: Int) -> Bool { false }
    func getCursorPosition(terminalId: Int) -> CursorPosition? { nil }
    func getWordAt(terminalId: Int, screenRow: Int, screenCol: Int) -> TerminalWordBoundary? { nil }
    func clearSelection(terminalId: Int) -> Bool { false }
    func getSelectionText(terminalId: Int) -> String? { nil }
    func getInputRow(terminalId: Int) -> UInt16? { nil }
    func changeFontSize(operation: FontSizeOperation) {}
    func getFontMetrics() -> SugarloafFontMetrics? { nil }
    func setMode(terminalId: Int, mode: TerminalMode) {}
    func getMode(terminalId: Int) -> TerminalMode? { nil }
}
