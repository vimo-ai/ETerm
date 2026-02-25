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
import ETermKit

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

/// 终端超链接信息
struct TerminalHyperlink {
    /// 起始行（绝对坐标）
    let startRow: Int64
    /// 起始列
    let startCol: Int
    /// 结束行（绝对坐标）
    let endRow: Int64
    /// 结束列
    let endCol: Int
    /// 超链接 URI
    let uri: String
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

    /// 当前工作目录变化回调（OSC 7）
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - cwd: 新的工作目录路径
    var onCurrentDirectoryChanged: ((Int, String) -> Void)?

    /// Shell 命令执行回调（OSC 133;C）
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - command: 执行的命令
    var onCommandExecuted: ((Int, String) -> Void)?

    /// 调试：上次 Event 时间（用于计算间隔）
    private var lastEventTime: Date?
    private var eventCounter: Int = 0

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
            history_size: 10000,
            log_buffer_size: 0  // ETerm 不需要日志捕获
        )

        handle = terminal_pool_create(config)

        guard handle != nil else {
            return nil
        }

        setupEventCallback()
    }

    deinit {
        if let handle = handle {
            terminal_pool_destroy(handle)
        }
    }

    // MARK: - Event Callback

    private func setupEventCallback() {
        guard let handle = handle else { return }

        let contextPtr = Unmanaged.passUnretained(self).toOpaque()

        // 设置常规事件回调
        terminal_pool_set_event_callback(
            handle,
            { (context, event) in
                guard let context = context else { return }
                let wrapper = Unmanaged<TerminalPoolWrapper>.fromOpaque(context).takeUnretainedValue()
                wrapper.handleEvent(event)
            },
            contextPtr
        )

        // 设置字符串事件回调（用于 CWD、Command 等）
        terminal_pool_set_string_event_callback(
            handle,
            { (context, eventType, terminalId, dataPtr) in
                guard let context = context,
                      let dataPtr = dataPtr else { return }
                let wrapper = Unmanaged<TerminalPoolWrapper>.fromOpaque(context).takeUnretainedValue()
                let data = String(cString: dataPtr)
                wrapper.handleStringEvent(eventType: eventType.rawValue, terminalId: Int(terminalId), data: data)
            },
            contextPtr
        )
    }

    private func handleEvent(_ event: TerminalPoolEvent) {
        // 使用位模式转换，避免 UInt64 超过 Int.max 时崩溃
        let terminalId = Int(bitPattern: UInt(event.data))

        switch event.event_type {
        case TerminalEventType_Wakeup, TerminalEventType_Render:
            // 不再调用 Swift renderCallback
            // 原因：Rust 侧的 route_wakeup_event() 已经设置了 needs_render = true
            //       CVDisplayLink 每帧会自动检查 needs_render 并渲染
            //       Swift 侧的 renderCallback 是多余的，会导致大量 DispatchQueue.main.async 调用
            //
            // 调试日志（仅在 debug 模式下记录）
            if LogManager.shared.debugEnabled {
                let now = Date()
                let interval = lastEventTime.map { now.timeIntervalSince($0) } ?? 0
                lastEventTime = now
                eventCounter += 1
                let eventType = event.event_type == TerminalEventType_Wakeup ? "Wakeup" : "Render"
                logDebug("[TerminalPool] 📥 Event #\(eventCounter): \(eventType) from terminal \(terminalId), interval=\(String(format: "%.3f", interval))s (no Swift callback)")
            }

        case TerminalEventType_Bell:
            DispatchQueue.main.async { [weak self] in
                self?.onBell?(terminalId)
            }

        case TerminalEventType_Damaged:
            // Damaged 事件保留用于兼容，Rust 侧实际不会发送
            // 同样不需要调用 renderCallback，CVDisplayLink 会自动处理
            break

        default:
            break
        }
    }

    /// 处理字符串事件（CWD、Command 等）
    ///
    /// - Parameters:
    ///   - eventType: 事件类型（对应 SugarloafBridge.h 中的 TerminalEventType）
    ///   - terminalId: 终端 ID
    ///   - data: 字符串数据
    private func handleStringEvent(eventType: UInt32, terminalId: Int, data: String) {
        switch eventType {
        case TerminalEventType_CurrentDirectoryChanged.rawValue:
            DispatchQueue.main.async { [weak self] in
                self?.onCurrentDirectoryChanged?(terminalId, data)
            }

        case TerminalEventType_CommandExecuted.rawValue:
            DispatchQueue.main.async { [weak self] in
                self?.onCommandExecuted?(terminalId, data)
            }

        default:
            break
        }
    }

    // MARK: - TerminalPoolProtocol Implementation

    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int {
        guard let handle = handle else { return -1 }
        let id = terminal_pool_create_terminal(handle, cols, rows)
        return Int(id)
    }

    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int {
        guard let handle = handle else { return -1 }
        let id = terminal_pool_create_terminal_with_cwd(handle, cols, rows, cwd)
        return Int(id)
    }

    /// 创建终端（使用指定的 ID）
    ///
    /// 用于 Session 恢复，确保 ID 在重启后保持一致
    func createTerminalWithId(_ id: Int, cols: UInt16, rows: UInt16) -> Int {
        guard let handle = handle else { return -1 }
        let result = terminal_pool_create_terminal_with_id(handle, Int64(id), cols, rows)
        return Int(result)
    }

    /// 创建终端（使用指定的 ID + 工作目录）
    ///
    /// 用于 Session 恢复，确保 ID 在重启后保持一致
    func createTerminalWithIdAndCwd(_ id: Int, cols: UInt16, rows: UInt16, cwd: String?) -> Int {
        guard let handle = handle else { return -1 }
        let result: Int64
        if let cwd = cwd {
            result = terminal_pool_create_terminal_with_id_and_cwd(handle, Int64(id), cols, rows, cwd)
        } else {
            result = terminal_pool_create_terminal_with_id(handle, Int64(id), cols, rows)
        }
        return Int(result)
    }

    /// 用外部 PTY fd 创建终端（dev-runner 等外部进程管理器集成）
    ///
    /// 调用方已通过 openpty() + fork() 启动进程，传入 master fd 和子进程 PID。
    /// terminal_pool 复用该 fd 进行终端渲染，不启动新 shell。
    func createTerminalWithFd(_ fd: Int32, childPid: UInt32, cols: UInt16, rows: UInt16) -> Int {
        guard let handle = handle else { return -1 }
        let result = terminal_pool_create_terminal_with_fd(handle, fd, childPid, cols, rows)
        return Int(result)
    }

    /// 获取终端的当前工作目录（通过 proc_pidinfo 系统调用）
    ///
    /// 注意：此方法获取的是前台进程的 CWD，如果有子进程运行（如 vim、claude），
    /// 可能返回子进程的 CWD 而非 shell 的 CWD。
    /// 推荐使用 `getCachedCwd` 获取 OSC 7 缓存的 CWD。
    func getCwd(terminalId: Int) -> String? {
        guard let handle = handle else { return nil }

        let cStr = terminal_pool_get_cwd(handle, terminalId)
        guard let cStr = cStr else { return nil }

        let result = String(cString: cStr)
        rio_free_string(cStr)
        return result
    }

    /// 获取终端的缓存工作目录（通过 OSC 7）
    ///
    /// Shell 通过 OSC 7 转义序列主动上报 CWD。此方法比 `getCwd` 更可靠：
    /// - 不受子进程（如 vim、claude）干扰
    /// - Shell 自己最清楚当前目录
    /// - 每次 cd 后立即更新
    ///
    /// 如果 OSC 7 缓存为空（shell 未配置或刚启动），返回 nil。
    func getCachedCwd(terminalId: Int) -> String? {
        guard let handle = handle else { return nil }

        let cStr = terminal_pool_get_cached_cwd(handle, terminalId)
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

    /// 检查终端是否启用了 Bracketed Paste Mode
    ///
    /// 当启用时（应用程序发送了 \x1b[?2004h），粘贴时应该用转义序列包裹内容。
    /// 当未启用时，直接发送原始文本。
    func isBracketedPasteEnabled(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_is_bracketed_paste_enabled(handle, terminalId)
    }

    /// 检查终端是否启用了 Kitty 键盘协议
    ///
    /// 应用程序通过发送 `CSI > flags u` 启用 Kitty 键盘模式。
    /// 启用后，终端应使用 Kitty 协议编码按键（如 Shift+Enter → `\x1b[13;2u`）。
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: true 表示使用 Kitty 协议，false 表示使用传统 Xterm 编码
    func isKittyKeyboardEnabled(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_is_kitty_keyboard_enabled(handle, terminalId)
    }


    /// 检查是否启用了鼠标追踪模式（SGR 1006, X11 1000 等）
    ///
    /// 应用程序通过 DECSET 序列（如 `\x1b[?1006h`）启用鼠标追踪。
    /// 启用后，终端应将鼠标事件转换为 SGR 格式发送到 PTY。
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: true 表示鼠标追踪已启用，false 表示终端处理自己的鼠标交互
    func hasMouseTrackingMode(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_has_mouse_tracking_mode(handle, terminalId)
    }

    /// 发送 SGR 格式的鼠标报告到 PTY
    ///
    /// SGR 鼠标报告格式：`\x1b[<button;col;rowM` 或 `\x1b[<button;col;rowm`
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - button: 按钮编码（0=左键, 1=中键, 2=右键, 64=滚轮上, 65=滚轮下）
    ///   - col: 网格列号（1-based）
    ///   - row: 网格行号（1-based）
    ///   - pressed: 是否按下（M/m）
    /// - Returns: true 表示发送成功，false 表示失败
    @discardableResult
    func sendMouseSGR(terminalId: Int, button: UInt8, col: UInt16, row: UInt16, pressed: Bool) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_send_mouse_sgr(handle, terminalId, button, col, row, pressed)
    }

    @discardableResult
    func closeTerminal(_ terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        let result = terminal_pool_close_terminal(handle, terminalId)
        return result
    }

    /// 标记终端为 keepAlive
    ///
    /// 调用后，closeTerminal 会 detach daemon session 而非 kill，
    /// daemon session 保留，后续可通过 reattach 恢复。
    func markKeepAlive(_ terminalId: Int) {
        guard let handle = handle else { return }
        terminal_pool_mark_keep_alive(handle, terminalId)
    }

    /// 强制关闭终端（无视 keepAlive 标记，直接 kill daemon session）
    ///
    /// 供插件主动清理时使用，确保彻底终止 daemon session。
    @discardableResult
    func closeTerminalForce(_ terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_close_terminal_force(handle, terminalId)
    }

    // MARK: - Terminal Migration (Cross-window move)

    /// 分离终端（用于跨窗口迁移）
    ///
    /// 将终端从当前池中移除，返回 DetachedTerminalHandle。
    /// PTY 连接保持活跃，终端状态完整保留。
    ///
    /// - Parameter terminalId: 要分离的终端 ID
    /// - Returns: DetachedTerminalHandle，失败返回 nil
    func detachTerminal(_ terminalId: Int) -> DetachedTerminalHandle? {
        guard let handle = handle else { return nil }
        let detached = terminal_pool_detach_terminal(handle, terminalId)
        return detached
    }

    /// 接收分离的终端（用于跨窗口迁移）
    ///
    /// 将 DetachedTerminalHandle 添加到当前池。
    ///
    /// - Parameter detached: 分离的终端句柄
    /// - Returns: 终端在当前池中的 ID，失败返回 -1
    func attachTerminal(_ detached: DetachedTerminalHandle) -> Int {
        guard let handle = handle else { return -1 }
        let id = terminal_pool_attach_terminal(handle, detached)
        return Int(id)
    }

    /// 销毁分离的终端（不迁移，直接关闭 PTY）
    ///
    /// - Parameter detached: 分离的终端句柄
    static func destroyDetachedTerminal(_ detached: DetachedTerminalHandle) {
        detached_terminal_destroy(detached)
    }

    /// 获取分离终端的原始 ID
    ///
    /// - Parameter detached: 分离的终端句柄
    /// - Returns: 终端的原始 ID，失败返回 -1
    static func getDetachedTerminalId(_ detached: DetachedTerminalHandle) -> Int {
        let id = detached_terminal_get_id(detached)
        return Int(id)
    }

    func getTerminalCount() -> Int {
        guard let handle = handle else { return 0 }
        return Int(terminal_pool_terminal_count(handle))
    }

    @discardableResult
    func writeInput(terminalId: Int, data: String) -> Bool {
        guard let handle = handle else { return false }

        // 只处理 \r\n (Windows 换行符) 转换为 \n
        // 保留独立的 \r（回车键需要它）
        let normalizedData = data.replacingOccurrences(of: "\r\n", with: "\n")

        guard let dataBytes = normalizedData.data(using: .utf8) else { return false }
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

    // MARK: - Hyperlink API

    /// 获取指定位置的超链接
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - screenRow: 屏幕行号（相对于可见区域，从 0 开始）
    ///   - screenCol: 屏幕列号（从 0 开始）
    /// - Returns: 超链接信息，无超链接返回 nil
    func getHyperlinkAt(terminalId: Int, screenRow: Int, screenCol: Int) -> TerminalHyperlink? {
        guard let handle = handle else { return nil }
        guard screenRow >= 0 && screenCol >= 0 else { return nil }

        let result = terminal_pool_get_hyperlink_at(handle, Int32(terminalId), Int32(screenRow), Int32(screenCol))
        guard result.valid else { return nil }

        // 转换 C 字符串为 Swift String
        guard let uriPtr = result.uri_ptr else { return nil }
        let uri = String(cString: uriPtr)

        // 释放 Rust 分配的内存
        terminal_pool_free_hyperlink(result)

        return TerminalHyperlink(
            startRow: result.start_row,
            startCol: Int(result.start_col),
            endRow: result.end_row,
            endCol: Int(result.end_col),
            uri: uri
        )
    }

    /// 设置超链接悬停状态（触发高亮渲染）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - hyperlink: 超链接信息
    /// - Returns: 是否成功
    @discardableResult
    func setHyperlinkHover(terminalId: Int, hyperlink: TerminalHyperlink) -> Bool {
        guard let handle = handle else { return false }
        return hyperlink.uri.withCString { uriPtr in
            terminal_pool_set_hyperlink_hover(
                handle,
                Int32(terminalId),
                hyperlink.startRow,
                UInt16(hyperlink.startCol),
                hyperlink.endRow,
                UInt16(hyperlink.endCol),
                uriPtr
            )
        }
    }

    /// 清除超链接悬停状态
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    @discardableResult
    func clearHyperlinkHover(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_clear_hyperlink_hover(handle, Int32(terminalId))
    }

    /// 获取指定位置的自动检测 URL
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - screenRow: 屏幕行号（相对于可见区域，从 0 开始）
    ///   - screenCol: 屏幕列号（从 0 开始）
    /// - Returns: URL 信息，无 URL 返回 nil
    func getUrlAt(terminalId: Int, screenRow: Int, screenCol: Int) -> TerminalHyperlink? {
        guard let handle = handle else { return nil }
        guard screenRow >= 0 && screenCol >= 0 else { return nil }

        let result = terminal_pool_get_url_at(handle, Int32(terminalId), Int32(screenRow), Int32(screenCol))
        guard result.valid else { return nil }

        // 转换 C 字符串为 Swift String
        guard let uriPtr = result.uri_ptr else { return nil }
        let uri = String(cString: uriPtr)

        // 释放 Rust 分配的内存
        terminal_pool_free_hyperlink(result)

        return TerminalHyperlink(
            startRow: result.start_row,
            startCol: Int(result.start_col),
            endRow: result.end_row,
            endCol: Int(result.end_col),
            uri: uri
        )
    }

    // MARK: - IME Preedit

    /// 设置 IME 预编辑状态
    ///
    /// 在当前光标位置显示预编辑文本（如拼音 "nihao"）。
    /// Rust 侧会从 Terminal 获取当前光标的绝对坐标。
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - text: 预编辑文本
    ///   - cursorOffset: 预编辑内的光标位置（字符索引）
    /// - Returns: 是否成功
    @discardableResult
    func setImePreedit(terminalId: Int, text: String, cursorOffset: UInt32 = 0) -> Bool {
        guard let handle = handle else { return false }
        return text.withCString { cString in
            terminal_pool_set_ime_preedit(handle, Int32(terminalId), cString, cursorOffset)
        }
    }

    /// 清除 IME 预编辑状态
    ///
    /// 应在以下情况调用：
    /// - 用户确认输入（commitText）
    /// - 用户取消输入（cancelComposition）
    /// - 终端切换
    /// - 终端失去焦点
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    @discardableResult
    func clearImePreedit(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return terminal_pool_clear_ime_preedit(handle, Int32(terminalId))
    }

    // MARK: - Selection

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
        // 预留接口，需要 Rust 侧支持
        return nil
    }

    func changeFontSize(operation: FontSizeOperation) {
        guard let handle = handle else { return }
        _ = terminal_pool_change_font_size(handle, operation.rawValue)
    }

    /// 获取当前字体大小
    func getFontSize() -> Float {
        guard let handle = handle else { return 14.0 }
        return terminal_pool_get_font_size(handle)
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

    // MARK: - Daemon Session

    /// 设置 reattach hint
    ///
    /// 下次 createTerminalWithCwd 时，优先 attach 到此 daemon session。
    /// hint 是一次性的：被消费后自动清空。
    func setReattachHint(_ sessionId: String) {
        guard let handle = handle else { return }
        sessionId.withCString { ptr in
            terminal_pool_set_reattach_hint(handle, ptr)
        }
    }

    /// 查询终端关联的 daemon session ID
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: daemon session ID，终端不存在或未使用 daemon 时返回 nil
    func getDaemonSessionId(_ terminalId: Int) -> String? {
        guard let handle = handle else { return nil }
        let cStr = terminal_pool_get_daemon_session_id(handle, terminalId)
        guard let cStr = cStr else { return nil }
        let result = String(cString: cStr)
        rio_free_string(cStr)
        return result
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

    // MARK: - Terminal Snapshot (for Session Recording)

    /// 获取Terminal可见区域的文本内容（用于快照录制）
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 可见区域的文本行数组，失败返回 nil
    func getVisibleLines(terminalId: Int) -> [String]? {
        guard let handle = handle else { return nil }

        var linesPtr: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        var count: Int = 0

        let success = terminal_pool_get_visible_lines(
            handle,
            Int64(terminalId),
            &linesPtr,
            &count
        )

        guard success, let lines = linesPtr, count > 0 else {
            return nil
        }

        // 转换为Swift字符串数组
        var result: [String] = []
        for i in 0..<count {
            if let cString = lines[i] {
                result.append(String(cString: cString))
            } else {
                result.append("")
            }
        }

        // 释放Rust分配的内存
        terminal_pool_free_string_array(lines, count)

        return result
    }

    /// 获取Terminal光标位置（用于快照录制，简化版）
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 光标位置 (row, col)，失败返回 nil
    func getSimpleCursorPosition(terminalId: Int) -> (row: Int, col: Int)? {
        guard let handle = handle else { return nil }

        var row: Int32 = 0
        var col: Int32 = 0

        let success = terminal_pool_get_cursor_position(
            handle,
            Int64(terminalId),
            &row,
            &col
        )

        return success ? (Int(row), Int(col)) : nil
    }

    /// 获取Terminal回滚缓冲区行数（用于快照录制）
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 回滚行数，失败返回 nil
    func getScrollbackLines(terminalId: Int) -> Int? {
        guard let handle = handle else { return nil }

        let lines = terminal_pool_get_scrollback_lines(
            handle,
            Int64(terminalId)
        )

        return lines >= 0 ? Int(lines) : nil
    }
}
