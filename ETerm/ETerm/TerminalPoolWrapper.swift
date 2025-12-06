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
    func readAllOutputs() -> Bool {
        // 事件驱动模式，不需要轮询
        return false
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

    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {
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
}
