//
//  TerminalPoolWrapper.swift
//  ETerm
//
//  新架构：多终端管理 + 统一渲染
//
//  使用方式：
//    pool.beginFrame()
//    for panel in visiblePanels {
//        pool.renderTerminal(id, x: panel.x, y: panel.y)
//    }
//    pool.endFrame()
//

import Foundation
import AppKit

// MARK: - Font Size Operation

/// 字体大小操作（原 SugarloafWrapper.FontSizeOperation）
enum FontSizeOperation: UInt8 {
    case reset = 0
    case decrease = 1
    case increase = 2
}

/// 终端事件类型
enum TerminalPoolSwiftEventType: UInt32 {
    case wakeup = 0
    case render = 1
    case cursorBlink = 2
    case bell = 3
    case titleChanged = 4
    case damaged = 5
}

/// 终端单词边界信息（网格坐标）
///
/// 与 WordBoundary 的区别：
/// - WordBoundary: NaturalLanguage 分词结果（字符串索引）
/// - TerminalWordBoundary: 终端网格单词（行列坐标）
struct TerminalWordBoundary {
    /// 单词起始列（屏幕坐标）
    let startCol: Int
    /// 单词结束列（屏幕坐标，包含）
    let endCol: Int
    /// 绝对行号
    let absoluteRow: Int64
    /// 单词文本
    let text: String
}

/// 终端池 Wrapper（新架构）
///
/// 职责分离：
/// - TerminalPool 管理多个终端实例（状态 + PTY）
/// - 渲染位置由调用方指定（Swift 控制布局）
/// - 统一提交：beginFrame → renderTerminal × N → endFrame
class TerminalPoolWrapper: TerminalPoolProtocol {

    // MARK: - Properties

    private var handle: TerminalPoolHandle?

    /// 暴露 handle 用于 RenderScheduler 绑定
    var poolHandle: TerminalPoolHandle? { handle }

    /// 渲染回调
    private var renderCallback: (() -> Void)?

    /// 终端关闭回调
    var onTerminalClose: ((Int) -> Void)?

    /// Bell 回调
    var onBell: ((Int) -> Void)?

    // MARK: - Initialization

    /// 创建终端池
    ///
    /// - Parameters:
    ///   - windowHandle: NSView 的原始指针
    ///   - displayHandle: NSWindow 的原始指针
    ///   - width: 窗口宽度（逻辑像素）
    ///   - height: 窗口高度（逻辑像素）
    ///   - scale: DPI 缩放因子
    ///   - fontSize: 字体大小
    init?(windowHandle: UnsafeMutableRawPointer,
          displayHandle: UnsafeMutableRawPointer,
          width: Float,
          height: Float,
          scale: Float,
          fontSize: Float = 14.0) {

        let config = TerminalPoolConfig(
            cols: 80,
            rows: 24,
            font_size: fontSize,
            line_height: 1.0,  // 行高因子：1.0 = 100%（调试用）
            scale: scale,
            window_handle: windowHandle,
            display_handle: displayHandle,
            window_width: width,
            window_height: height,
            history_size: 10000
        )

        handle = terminal_pool_create(config)

        guard handle != nil else {
            print("❌ [TerminalPoolWrapper] Failed to create pool")
            return nil
        }

        print("✅ [TerminalPoolWrapper] Pool created")
        setupEventCallback()
    }

    deinit {
        if let handle = handle {
            terminal_pool_destroy(handle)
            print("🗑️ [TerminalPoolWrapper] Pool destroyed")
        }
    }

    // MARK: - Event Callback

    private func setupEventCallback() {
        guard let handle = handle else { return }

        let contextPtr = Unmanaged.passUnretained(self).toOpaque()

        terminal_pool_set_event_callback(
            handle,
            { (context, event) in
                guard let context = context else { return }
                let wrapper = Unmanaged<TerminalPoolWrapper>.fromOpaque(context).takeUnretainedValue()
                wrapper.handleEvent(event)
            },
            contextPtr
        )
    }

    private func handleEvent(_ event: TerminalPoolEvent) {
        let terminalId = Int(event.data)

        switch event.event_type {
        case TerminalEventType_Wakeup, TerminalEventType_Render:
            DispatchQueue.main.async { [weak self] in
                self?.renderCallback?()
            }

        case TerminalEventType_Bell:
            DispatchQueue.main.async { [weak self] in
                self?.onBell?(terminalId)
            }

        case TerminalEventType_Damaged:
            DispatchQueue.main.async { [weak self] in
                self?.renderCallback?()
            }

        default:
            break
        }
    }

    // MARK: - TerminalPoolProtocol Implementation

    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int {
        guard let handle = handle else { return -1 }
        let id = terminal_pool_create_terminal(handle, cols, rows)
        print("🆕 [TerminalPoolWrapper] Created terminal \(id)")
        return Int(id)
    }

    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int {
        guard let handle = handle else { return -1 }
        print("🆕 [TerminalPoolWrapper] Creating terminal with CWD: \(cwd)")
        let id = terminal_pool_create_terminal_with_cwd(handle, cols, rows, cwd)
        print("🆕 [TerminalPoolWrapper] Created terminal \(id) with CWD")
        return Int(id)
    }

    /// 获取终端的当前工作目录
    func getCwd(terminalId: Int) -> String? {
        guard let handle = handle else { return nil }

        let cStr = terminal_pool_get_cwd(handle, terminalId)
        guard let cStr = cStr else { return nil }

        let result = String(cString: cStr)
        rio_free_string(cStr)
        return result
    }

    /// 获取终端的前台进程名称
    ///
    /// 返回当前前台进程的名称（如 "vim", "cargo", "python" 等）
    /// 如果前台进程就是 shell 本身，返回 shell 名称（如 "zsh", "bash"）
    func getForegroundProcessName(terminalId: Int) -> String? {
        guard let handle = handle else { return nil }

        let cStr = terminal_pool_get_foreground_process_name(handle, terminalId)
        guard let cStr = cStr else { return nil }

        let result = String(cString: cStr)
        rio_free_string(cStr)
        return result
    }

    /// 检查终端是否有正在运行的子进程（非 shell）
    ///
    /// 返回 true 如果前台进程不是 shell 本身（如正在运行 vim, cargo, python 等）
    func hasRunningProcess(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_has_running_process(handle, terminalId)
    }

    @discardableResult
    func closeTerminal(_ terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        let result = terminal_pool_close_terminal(handle, terminalId)
        print("🗑️ [TerminalPoolWrapper] Closed terminal \(terminalId): \(result)")
        return result
    }

    func getTerminalCount() -> Int {
        guard let handle = handle else { return 0 }
        return Int(terminal_pool_terminal_count(handle))
    }

    @discardableResult
    func writeInput(terminalId: Int, data: String) -> Bool {
        guard let handle = handle,
              let dataBytes = data.data(using: .utf8) else { return false }
        return dataBytes.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return false }
            return terminal_pool_input(handle, terminalId, baseAddress.assumingMemoryBound(to: UInt8.self), dataBytes.count)
        }
    }

    @discardableResult
    func scroll(terminalId: Int, deltaLines: Int32) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_scroll(handle, terminalId, deltaLines)
    }

    @discardableResult
    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }
        // 使用默认的像素尺寸（会在 Rust 侧计算）
        return terminal_pool_resize_terminal(handle, terminalId, cols, rows, 0, 0)
    }

    func setRenderCallback(_ callback: @escaping () -> Void) {
        renderCallback = callback
    }

    @discardableResult
    func render(terminalId: Int, x: Float, y: Float, width: Float, height: Float, cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }
        // 新架构：直接调用 renderTerminal（传递 width/height 用于自动 resize）
        return terminal_pool_render_terminal(handle, terminalId, x, y, width, height)
    }

    func flush() {
        // 新架构中 flush 在 endFrame 中完成
        endFrame()
    }

    func clear() {
        // 新架构中 clear 在 beginFrame 中完成
        beginFrame()
    }

    func getCursorPosition(terminalId: Int) -> CursorPosition? {
        guard let handle = handle else { return nil }

        let result = terminal_pool_get_cursor(handle, terminalId)
        guard result.valid else { return nil }

        return CursorPosition(col: result.col, row: result.row)
    }

    /// 获取指定位置的单词边界（终端网格）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - screenRow: 屏幕行号（相对于可见区域，从 0 开始）
    ///   - screenCol: 屏幕列号（从 0 开始）
    /// - Returns: 单词边界信息，失败返回 nil
    func getWordAt(terminalId: Int, screenRow: Int, screenCol: Int) -> TerminalWordBoundary? {
        guard let handle = handle else { return nil }
        guard screenRow >= 0 && screenCol >= 0 else { return nil }

        let result = terminal_pool_get_word_at(handle, Int32(terminalId), Int32(screenRow), Int32(screenCol))
        guard result.valid else { return nil }

        // 转换 C 字符串为 Swift String
        guard let textPtr = result.text_ptr else { return nil }
        let text = String(cString: textPtr)

        // 释放 Rust 分配的内存
        terminal_pool_free_word_boundary(result)

        return TerminalWordBoundary(
            startCol: Int(result.start_col),
            endCol: Int(result.end_col),
            absoluteRow: result.absolute_row,
            text: text
        )
    }

    @discardableResult
    func clearSelection(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_clear_selection(handle, terminalId)
    }

    /// 完成选区（mouseUp 时调用）
    ///
    /// 业务逻辑（在 Rust 端处理）：
    /// - 检查选区内容是否全为空白
    /// - 如果全是空白，自动清除选区，返回 nil
    /// - 如果有内容，保留选区，返回选中的文本
    ///
    /// - Returns: 选中的文本（非空白），或 nil（无选区/全空白已清除）
    func finalizeSelection(terminalId: Int) -> String? {
        guard let handle = handle else { return nil }
        let result = terminal_pool_finalize_selection(handle, terminalId)

        guard result.has_selection, let textPtr = result.text else {
            return nil
        }

        // 转换为 Swift String
        let text = String(cString: textPtr)

        // 释放 Rust 分配的内存
        terminal_pool_free_string(textPtr)

        return text
    }

    /// 获取选中的文本（不清除选区）
    ///
    /// 用于 Cmd+C 复制等场景
    ///
    /// - Returns: 选中的文本，或 nil（无选区）
    func getSelectionText(terminalId: Int) -> String? {
        guard let handle = handle else { return nil }
        let result = terminal_pool_get_selection_text(handle, terminalId)

        guard result.success, let textPtr = result.text else {
            return nil
        }

        // 转换为 Swift String
        let text = String(cString: textPtr)

        // 释放 Rust 分配的内存
        terminal_pool_free_string(textPtr)

        return text
    }

    /// 屏幕坐标转绝对坐标
    func screenToAbsolute(terminalId: Int, screenRow: Int, screenCol: Int) -> (absoluteRow: Int64, col: Int)? {
        guard let handle = handle else { return nil }
        let result = terminal_pool_screen_to_absolute(handle, terminalId, screenRow, screenCol)
        if result.success {
            return (result.absolute_row, Int(result.col))
        }
        return nil
    }

    /// 设置选区
    @discardableResult
    func setSelection(terminalId: Int, startAbsoluteRow: Int64, startCol: Int, endAbsoluteRow: Int64, endCol: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_set_selection(handle, terminalId, startAbsoluteRow, startCol, endAbsoluteRow, endCol)
    }

    func getInputRow(terminalId: Int) -> UInt16? {
        // TODO: 需要在 Rust 侧添加此 API
        return nil
    }

    func changeFontSize(operation: FontSizeOperation) {
        guard let handle = handle else { return }
        _ = terminal_pool_change_font_size(handle, operation.rawValue)
    }

    /// 获取字体度量（物理像素）
    ///
    /// 返回与渲染一致的字体度量
    func getFontMetrics() -> SugarloafFontMetrics? {
        guard let handle = handle else { return nil }
        var metrics = SugarloafFontMetrics()
        if terminal_pool_get_font_metrics(handle, &metrics) {
            return metrics
        }
        return nil
    }

    // MARK: - New Architecture Methods

    /// 调整终端大小（包含像素尺寸）
    func resizeTerminal(_ id: Int, cols: UInt16, rows: UInt16, width: Float, height: Float) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_resize_terminal(handle, id, cols, rows, width, height)
    }

    /// 开始新的一帧
    func beginFrame() {
        guard let handle = handle else { return }
        terminal_pool_begin_frame(handle)
    }

    /// 渲染终端到指定位置
    ///
    /// - Parameters:
    ///   - id: 终端 ID
    ///   - x, y: 渲染位置（逻辑坐标）
    ///   - width, height: 终端区域大小（逻辑坐标）
    ///     - 如果 > 0，自动计算 cols/rows 并 resize
    ///     - 如果 = 0，不执行 resize
    func renderTerminal(_ id: Int, x: Float, y: Float, width: Float = 0, height: Float = 0) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_render_terminal(handle, id, x, y, width, height)
    }

    /// 结束帧（统一提交渲染）
    func endFrame() {
        guard let handle = handle else { return }
        terminal_pool_end_frame(handle)
    }

    /// 调整渲染表面大小
    func resizeSugarloaf(width: Float, height: Float) {
        guard let handle = handle else { return }
        terminal_pool_resize_sugarloaf(handle, width, height)
    }

    /// 设置 DPI 缩放（窗口在不同 DPI 屏幕间移动时调用）
    ///
    /// 更新 Rust 端的 scale factor，确保：
    /// - 字体度量计算正确
    /// - 选区坐标转换正确
    /// - 渲染位置计算正确
    func setScale(_ scale: Float) {
        guard let handle = handle else { return }
        terminal_pool_set_scale(handle, scale)
    }

    // MARK: - Search Methods

    /// 搜索文本
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - query: 搜索关键词
    /// - Returns: 匹配数量（>= 0），失败返回 -1
    func search(terminalId: Int, query: String) -> Int {
        guard let handle = handle else { return -1 }
        return Int(terminal_pool_search(handle, terminalId, query))
    }

    /// 跳转到下一个匹配
    ///
    /// - Parameter terminalId: 终端 ID
    func searchNext(terminalId: Int) {
        guard let handle = handle else { return }
        terminal_pool_search_next(handle, terminalId)
    }

    /// 跳转到上一个匹配
    ///
    /// - Parameter terminalId: 终端 ID
    func searchPrev(terminalId: Int) {
        guard let handle = handle else { return }
        terminal_pool_search_prev(handle, terminalId)
    }

    /// 清除搜索
    ///
    /// - Parameter terminalId: 终端 ID
    func clearSearch(terminalId: Int) {
        guard let handle = handle else { return }
        terminal_pool_clear_search(handle, terminalId)
    }

    // MARK: - Terminal Mode

    /// 设置终端运行模式
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - mode: 运行模式
    ///
    /// 切换到 Active 时会自动触发一次渲染刷新
    func setMode(terminalId: Int, mode: TerminalMode) {
        guard let handle = handle else { return }
        terminal_pool_set_mode(handle, terminalId, mode.rawValue)
    }

    /// 获取终端运行模式
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 当前模式，终端不存在时返回 nil
    func getMode(terminalId: Int) -> TerminalMode? {
        guard let handle = handle else { return nil }
        let rawMode = terminal_pool_get_mode(handle, terminalId)
        return TerminalMode(rawValue: rawMode)
    }
}

// MARK: - Convenience Extensions

extension TerminalPoolWrapper {

    /// 渲染多个终端（便捷方法）
    ///
    /// 使用示例：
    /// ```swift
    /// pool.renderTerminals([
    ///     (id: 1, x: 0, y: 0),
    ///     (id: 2, x: 400, y: 0),
    /// ])
    /// ```
    func renderTerminals(_ terminals: [(id: Int, x: Float, y: Float)]) {
        beginFrame()
        for terminal in terminals {
            _ = renderTerminal(terminal.id, x: terminal.x, y: terminal.y)
        }
        endFrame()
    }

    // MARK: - New Architecture: Rust-side Rendering

    /// 设置渲染布局（新架构）
    ///
    /// Swift 侧在布局变化时调用（Tab 切换、窗口 resize 等）
    /// Rust 侧在 VSync 时使用此布局进行渲染
    ///
    /// - Parameters:
    ///   - layouts: 布局数组 (terminalId, x, y, width, height)
    ///   - containerHeight: 容器高度（用于坐标转换）
    ///
    /// - Note: 坐标应已转换为 Rust 坐标系（Y 从顶部开始）
    func setRenderLayout(_ layouts: [(terminalId: Int, x: Float, y: Float, width: Float, height: Float)], containerHeight: Float) {
        guard let handle = handle else { return }

        var cLayouts = layouts.map { layout in
            TerminalRenderLayout(
                terminal_id: layout.terminalId,
                x: layout.x,
                y: layout.y,
                width: layout.width,
                height: layout.height
            )
        }

        cLayouts.withUnsafeMutableBufferPointer { buffer in
            terminal_pool_set_render_layout(handle, buffer.baseAddress, buffer.count, containerHeight)
        }
    }

    /// 触发一次完整渲染（新架构）
    ///
    /// 通常不需要手动调用，RenderScheduler 会自动在 VSync 时调用
    /// 此接口用于特殊情况（如初始化、强制刷新）
    func renderAll() {
        guard let handle = handle else { return }
        terminal_pool_render_all(handle)
    }

    // MARK: - Lock-Free Cache API (Phase 1 Async FFI)

    /// 选区范围（无锁读取）
    struct TerminalSelectionRange {
        /// 起始行（绝对行号）
        let startRow: Int32
        /// 起始列
        let startCol: UInt32
        /// 结束行（绝对行号）
        let endRow: Int32
        /// 结束列
        let endCol: UInt32
    }

    /// 获取选区范围（无锁）
    ///
    /// 从原子缓存读取，无需获取 Terminal 锁
    /// 主线程可安全调用，永不阻塞
    ///
    /// - Note: 返回的是上次渲染时的快照，可能与实时状态有微小差异
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 选区范围，无选区时返回 nil
    func getSelectionRange(terminalId: Int) -> TerminalSelectionRange? {
        guard let handle = handle else { return nil }

        let result = terminal_pool_get_selection_range(handle, terminalId)
        guard result.has_selection else { return nil }

        return TerminalSelectionRange(
            startRow: result.start_row,
            startCol: result.start_col,
            endRow: result.end_row,
            endCol: result.end_col
        )
    }

    /// 滚动信息（无锁读取）
    struct TerminalScrollInfo {
        /// 当前滚动位置
        let displayOffset: UInt32
        /// 历史行数
        let historySize: UInt16
        /// 总行数
        let totalLines: UInt16
    }

    /// 获取滚动信息（无锁）
    ///
    /// 从原子缓存读取，无需获取 Terminal 锁
    /// 主线程可安全调用，永不阻塞
    ///
    /// - Note: 返回的是上次渲染时的快照，可能与实时状态有微小差异
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 滚动信息，终端不存在时返回 nil
    func getScrollInfo(terminalId: Int) -> TerminalScrollInfo? {
        guard let handle = handle else { return nil }

        let result = terminal_pool_get_scroll_info(handle, terminalId)
        guard result.valid else { return nil }

        return TerminalScrollInfo(
            displayOffset: result.display_offset,
            historySize: result.history_size,
            totalLines: result.total_lines
        )
    }

    /// 检查是否有选区（无锁）
    ///
    /// 比 getSelectionRange() 更轻量，只检查是否有选区
    func hasSelection(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        let result = terminal_pool_get_selection_range(handle, terminalId)
        return result.has_selection
    }

    /// 检查是否可滚动（无锁）
    ///
    /// 返回 true 如果有历史内容可以滚动
    func canScroll(terminalId: Int) -> Bool {
        guard let scrollInfo = getScrollInfo(terminalId: terminalId) else { return false }
        return scrollInfo.historySize > 0
    }

    /// 获取滚动进度（无锁）
    ///
    /// - Returns: 0.0 = 底部（最新），1.0 = 顶部（最旧历史）
    func getScrollProgress(terminalId: Int) -> Float {
        guard let scrollInfo = getScrollInfo(terminalId: terminalId),
              scrollInfo.historySize > 0 else { return 0.0 }
        return Float(scrollInfo.displayOffset) / Float(scrollInfo.historySize)
    }
}
