//
//  EventDrivenTerminalPoolWrapper.swift
//  ETerm
//
//  事件驱动终端池的 Swift 封装
//
//  核心架构（参考 Rio）：
//  - 每个终端一个独立的 PTY 事件线程
//  - PTY 有数据时才读取，不用定时器轮询
//  - 数据处理完成后通过回调通知 Swift 渲染
//  - Swift 删除 CVDisplayLink 轮询，改为事件驱动渲染
//

import Foundation

/// 事件驱动终端池的 Swift 封装
///
/// 与 `TerminalPoolWrapper` 不同，这个类使用事件驱动架构：
/// - PTY 有数据时自动读取，不需要轮询
/// - 回调触发渲染，不需要 CVDisplayLink
class EventDrivenTerminalPoolWrapper: TerminalPoolProtocol {
    private(set) var handle: EventDrivenPoolHandle?

    /// 保持对回调的强引用
    private var wakeupCallbackClosure: (() -> Void)?

    // MARK: - 初始化

    init?(sugarloaf: SugarloafWrapper) {
        guard let sugarloafHandle = sugarloaf.handle else { return nil }

        handle = event_driven_pool_new(sugarloafHandle)

        guard handle != nil else { return nil }

        print("[EventDrivenPoolWrapper] Created event-driven terminal pool")
    }

    deinit {
        if let handle = handle {
            event_driven_pool_free(handle)
        }
        print("[EventDrivenPoolWrapper] Freed event-driven terminal pool")
    }

    // MARK: - 渲染回调

    /// 设置 wakeup 回调
    ///
    /// 当 PTY 有数据时会被调用（在 Rust PTY 线程中）
    ///
    /// ## 架构说明（参考 Rio）
    ///
    /// Rio 的事件循环流程：
    /// 1. PTY 线程读取数据 → `event_proxy.send_event(RioEvent::Wakeup)`
    /// 2. 主线程事件循环收到 Wakeup → 同步标记需要渲染 → 同一事件循环周期内渲染
    ///
    /// ETerm 的实现：
    /// 1. PTY 线程读取数据 → C 回调
    /// 2. **同步**调度到主线程 → 直接执行渲染（不等 CVDisplayLink）
    ///
    /// 关键：使用 `DispatchQueue.main.sync` 而不是 `async`
    /// 这确保 PTY 线程等待渲染完成，避免数据和渲染不同步
    func setRenderCallback(_ callback: @escaping () -> Void) {
        guard let handle = handle else { return }

        // 保持对闭包的强引用
        self.wakeupCallbackClosure = callback

        // 将 self 作为 context 传递
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 设置 C 回调函数
        event_driven_pool_set_wakeup_callback(handle, { contextPtr in
            guard let contextPtr = contextPtr else { return }

            // 从 context 恢复实例
            let wrapper = Unmanaged<EventDrivenTerminalPoolWrapper>.fromOpaque(contextPtr).takeUnretainedValue()

            // 🎯 关键修改：同步调度到主线程执行渲染
            // 参考 Rio：Wakeup 事件在同一事件循环周期内同步处理
            //
            // 为什么用 sync 而不是 async？
            // - async: PTY 线程继续运行，可能读取更多数据，导致渲染时数据不一致
            // - sync: PTY 线程等待渲染完成，确保"读取-渲染"的原子性
            //
            // 注意：如果已经在主线程，直接调用避免死锁
            if Thread.isMainThread {
                wrapper.wakeupCallbackClosure?()
            } else {
                DispatchQueue.main.sync {
                    wrapper.wakeupCallbackClosure?()
                }
            }
        }, context)
    }

    // MARK: - 终端管理

    @discardableResult
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int {
        guard let handle = handle else { return -1 }

        let result = Int(shell.withCString { shellPtr in
            event_driven_pool_create_terminal(handle, cols, rows, shellPtr)
        })

        if result >= 0 {
            print("[EventDrivenPoolWrapper] Created terminal \(result) with event loop")
        }

        return result
    }

    func closeTerminal(_ terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return event_driven_pool_close_terminal(handle, terminalId) != 0
    }

    func getTerminalCount() -> Int {
        guard let handle = handle else { return 0 }
        return Int(event_driven_pool_count(handle))
    }

    // MARK: - PTY 输入

    /// 事件驱动模式不需要手动读取
    @discardableResult
    func readAllOutputs() -> Bool {
        // 事件驱动模式：PTY 线程自动读取，不需要手动调用
        // 返回 false 表示没有新数据（由回调处理）
        return false
    }

    func writeInput(terminalId: Int, data: String) -> Bool {
        guard let handle = handle else { return false }

        return data.withCString { dataPtr in
            event_driven_pool_write_input(handle, terminalId, dataPtr) != 0
        }
    }

    func scroll(terminalId: Int, deltaLines: Int32) -> Bool {
        guard let handle = handle else { return false }
        return event_driven_pool_scroll(handle, terminalId, deltaLines) != 0
    }

    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }
        return event_driven_pool_resize(handle, terminalId, cols, rows) != 0
    }

    // MARK: - 光标上下文 API

    func setSelection(
        terminalId: Int,
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> Bool {
        guard let handle = handle else { return false }

        return event_driven_pool_set_selection(
            handle,
            terminalId,
            startRow,
            startCol,
            endRow,
            endCol
        ) != 0
    }

    func clearSelection(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return event_driven_pool_clear_selection(handle, terminalId) != 0
    }

    func getTextRange(
        terminalId: Int,
        startRow: UInt16,
        startCol: UInt16,
        endRow: UInt16,
        endCol: UInt16
    ) -> String? {
        // 事件驱动池暂不支持此 API
        // 可以后续添加
        return nil
    }

    func getInputRow(terminalId: Int) -> UInt16? {
        // 事件驱动池暂不支持此 API
        return nil
    }

    func getCursorPosition(terminalId: Int) -> CursorPosition? {
        guard let handle = handle else { return nil }

        var col: UInt16 = 0
        var row: UInt16 = 0

        guard event_driven_pool_get_cursor(handle, terminalId, &col, &row) != 0 else {
            return nil
        }

        return CursorPosition(col: col, row: row)
    }

    // MARK: - 渲染

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

        // 事件驱动版本的 render 不需要 width 和 height
        return event_driven_pool_render(
            handle,
            terminalId,
            x, y,
            cols, rows
        ) != 0
    }

    func flush() {
        guard let handle = handle else { return }
        event_driven_pool_flush(handle)
    }

    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {
        guard let handle = handle else { return }
        event_driven_pool_change_font_size(handle, operation.rawValue)
    }

    // MARK: - Focus Reporting API (DECSET 1004)

    /// 检查指定终端是否启用了 Focus In/Out Reporting 模式
    ///
    /// 应用（如 Claude CLI）通过 DECSET 1004 启用此模式
    func isFocusModeEnabled(terminalId: Int) -> Bool {
        guard let handle = handle else { return false }
        return event_driven_pool_is_focus_mode_enabled(handle, terminalId) != 0
    }

    /// 发送 Focus 事件到指定终端
    ///
    /// 当窗口获得/失去焦点时调用此方法
    /// - 获得焦点: 发送 "\x1b[I"
    /// - 失去焦点: 发送 "\x1b[O"
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - isFocused: true = 获得焦点, false = 失去焦点
    /// - Returns: 是否成功发送
    @discardableResult
    func sendFocusEvent(terminalId: Int, isFocused: Bool) -> Bool {
        guard let handle = handle else { return false }
        return event_driven_pool_send_focus_event(handle, terminalId, isFocused) != 0
    }

    /// 向所有启用了 Focus Reporting 的终端发送 Focus 事件
    ///
    /// 便捷方法，在窗口获得/失去焦点时调用
    /// - Parameter isFocused: true = 获得焦点, false = 失去焦点
    /// - Returns: 成功发送的终端数量
    @discardableResult
    func sendFocusEventToAll(isFocused: Bool) -> Int {
        guard let handle = handle else { return 0 }
        return Int(event_driven_pool_send_focus_event_to_all(handle, isFocused))
    }
}
