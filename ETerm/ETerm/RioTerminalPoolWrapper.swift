//
//  RioTerminalPoolWrapper.swift
//  ETerm
//
//  照抄 Rio 的事件系统实现
//

import Foundation
import AppKit
import Combine

/// Rio 事件类型
enum RioEventType: UInt32 {
    case wakeup = 0
    case render = 1
    case cursorBlinkingChange = 2
    case bell = 3
    case title = 4
    case ptyWrite = 5
    case clipboardStore = 6
    case clipboardLoad = 7
    case exit = 8
    case closeTerminal = 9
    case scroll = 10
    case mouseCursorDirty = 11
    case noop = 12
}

/// Swift 侧的事件封装
struct RioSwiftEvent {
    let type: RioEventType
    let terminalId: Int
    let scrollDelta: Int32
    let stringData: String?
}

/// 待渲染更新状态 - 照抄 Rio 的 PendingUpdate
class PendingUpdate {
    private var isDirty: Bool = false
    private let lock = NSLock()

    func setDirty() {
        lock.lock()
        defer { lock.unlock() }
        isDirty = true
    }

    func checkAndReset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasDirty = isDirty
        isDirty = false
        return wasDirty
    }
}

/// Rio Terminal Pool Wrapper
///
/// 照抄 Rio 的事件系统：
/// - Rust 侧通过 FFI 回调发送事件
/// - Swift 侧有事件队列消费事件
/// - 使用 PendingUpdate 标记脏状态
class RioTerminalPoolWrapper: TerminalPoolProtocol {

    // MARK: - Properties

    private var poolHandle: RioTerminalPoolHandle?
    private let sugarloafHandle: SugarloafHandle

    /// 事件队列
    private var eventQueue: [RioSwiftEvent] = []
    private let eventQueueLock = NSLock()

    /// 待渲染更新状态（每个终端一个）
    private var pendingUpdates: [Int: PendingUpdate] = [:]
    private let pendingUpdatesLock = NSLock()

    /// 渲染回调
    var onNeedsRender: (() -> Void)?

    /// 标题变更回调
    var onTitleChange: ((Int, String) -> Void)?

    /// 终端关闭回调
    var onTerminalClose: ((Int) -> Void)?

    /// Bell 回调
    var onBell: ((Int) -> Void)?

    // MARK: - Initialization

    init(sugarloafHandle: SugarloafHandle) {
        self.sugarloafHandle = sugarloafHandle
        self.poolHandle = rio_pool_new(sugarloafHandle)

        setupEventCallback()
    }

    deinit {
        if let pool = poolHandle {
            rio_pool_free(pool)
        }
    }

    // MARK: - Event Callback Setup

    private func setupEventCallback() {
        guard let pool = poolHandle else { return }

        // 保存 self 的弱引用给 C 回调使用
        let contextPtr = Unmanaged.passUnretained(self).toOpaque()

        rio_pool_set_event_callback(
            pool,
            { (context, event) in
                // 这是 C 回调，在 PTY 线程中调用
                guard let context = context else { return }
                let wrapper = Unmanaged<RioTerminalPoolWrapper>.fromOpaque(context).takeUnretainedValue()
                wrapper.handleFFIEvent(event)
            },
            { (context, eventType, cStr) in
                // 字符串事件回调
                guard let context = context else { return }
                let wrapper = Unmanaged<RioTerminalPoolWrapper>.fromOpaque(context).takeUnretainedValue()
                let str = cStr != nil ? String(cString: cStr!) : ""
                wrapper.handleStringEvent(eventType: eventType, string: str)
            },
            contextPtr
        )
    }

    /// 处理 FFI 事件（在 PTY 线程中调用）
    private func handleFFIEvent(_ ffiEvent: FFIEvent) {
        guard let eventType = RioEventType(rawValue: ffiEvent.event_type) else { return }

        let event = RioSwiftEvent(
            type: eventType,
            terminalId: Int(ffiEvent.route_id),
            scrollDelta: ffiEvent.scroll_delta,
            stringData: nil
        )

        // 入队事件
        eventQueueLock.lock()
        eventQueue.append(event)
        eventQueueLock.unlock()

        // 处理特定事件
        switch eventType {
        case .wakeup:
            // 标记该终端需要更新
            markDirty(terminalId: Int(ffiEvent.route_id))

            // 照抄 Rio: 通过主线程调度渲染
            // Rio 使用 winit 的 request_redraw，我们使用 GCD
            DispatchQueue.main.async { [weak self] in
                self?.onNeedsRender?()
            }

        case .render:
            DispatchQueue.main.async { [weak self] in
                self?.onNeedsRender?()
            }

        case .bell:
            DispatchQueue.main.async { [weak self] in
                self?.onBell?(Int(ffiEvent.route_id))
            }

        case .exit, .closeTerminal:
            DispatchQueue.main.async { [weak self] in
                self?.onTerminalClose?(Int(ffiEvent.route_id))
            }

        case .cursorBlinkingChange:
            // 光标闪烁状态改变，需要重新渲染
            markDirty(terminalId: Int(ffiEvent.route_id))

        default:
            break
        }
    }

    /// 处理字符串事件
    private func handleStringEvent(eventType: UInt32, string: String) {
        guard let type = RioEventType(rawValue: eventType) else { return }

        switch type {
        case .title:
            // 标题变更
            // 注意：这里我们没有 terminalId，需要改进 FFI 接口
            DispatchQueue.main.async { [weak self] in
                self?.onTitleChange?(0, string)
            }

        case .clipboardStore:
            // 复制到剪贴板
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }

        default:
            break
        }
    }

    /// 标记终端需要更新
    private func markDirty(terminalId: Int) {
        pendingUpdatesLock.lock()
        if pendingUpdates[terminalId] == nil {
            pendingUpdates[terminalId] = PendingUpdate()
        }
        pendingUpdates[terminalId]?.setDirty()
        pendingUpdatesLock.unlock()
    }

    /// 检查终端是否需要更新
    func checkDirty(terminalId: Int) -> Bool {
        pendingUpdatesLock.lock()
        defer { pendingUpdatesLock.unlock() }
        return pendingUpdates[terminalId]?.checkAndReset() ?? false
    }

    // MARK: - TerminalPoolProtocol

    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int {
        guard let pool = poolHandle else { return -1 }

        let terminalId = rio_pool_create_terminal(pool, cols, rows, shell)

        if terminalId >= 0 {
            // 为新终端创建 PendingUpdate
            pendingUpdatesLock.lock()
            pendingUpdates[Int(terminalId)] = PendingUpdate()
            pendingUpdatesLock.unlock()
        }

        return Int(terminalId)
    }

    func closeTerminal(_ terminalId: Int) -> Bool {
        guard let pool = poolHandle else { return false }

        let result = rio_pool_close_terminal(pool, terminalId)

        if result != 0 {
            pendingUpdatesLock.lock()
            pendingUpdates.removeValue(forKey: terminalId)
            pendingUpdatesLock.unlock()
        }

        return result != 0
    }

    func getTerminalCount() -> Int {
        guard let pool = poolHandle else { return 0 }
        return Int(rio_pool_count(pool))
    }

    func writeInput(terminalId: Int, data: String) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_write_input(pool, terminalId, data) != 0
    }

    func readAllOutputs() -> Bool {
        // 事件驱动模式下不需要轮询
        return false
    }

    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_resize(pool, terminalId, cols, rows) != 0
    }

    func scroll(terminalId: Int, deltaLines: Int32) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_scroll(pool, terminalId, deltaLines) != 0
    }

    func setRenderCallback(_ callback: @escaping () -> Void) {
        onNeedsRender = callback
    }

    func render(terminalId: Int, x: Float, y: Float, width: Float, height: Float, cols: UInt16, rows: UInt16) -> Bool {
        // 新版使用 snapshot + 手动渲染
        return true
    }

    func flush() {
        // 新版不需要 flush
    }

    func getCursorPosition(terminalId: Int) -> CursorPosition? {
        guard let pool = poolHandle else { return nil }

        var col: UInt16 = 0
        var row: UInt16 = 0
        let result = rio_pool_get_cursor(pool, terminalId, &col, &row)

        return result != 0 ? CursorPosition(col: col, row: row) : nil
    }

    func clearSelection(terminalId: Int) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_clear_selection(pool, terminalId) != 0
    }

    func getInputRow(terminalId: Int) -> UInt16? {
        // TODO: 实现获取输入行
        return nil
    }

    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {
        // TODO: 实现字体大小调整
    }

    // MARK: - Snapshot API

    /// 获取终端快照
    func getSnapshot(terminalId: Int) -> TerminalSnapshot? {
        guard let pool = poolHandle else { return nil }

        var snapshot = TerminalSnapshot()
        let result = rio_pool_get_snapshot(pool, terminalId, &snapshot)

        return result != 0 ? snapshot : nil
    }

    /// 获取光标位置（元组版本）
    func getCursor(terminalId: Int) -> (col: UInt16, row: UInt16)? {
        guard let pool = poolHandle else { return nil }

        var col: UInt16 = 0
        var row: UInt16 = 0
        let result = rio_pool_get_cursor(pool, terminalId, &col, &row)

        return result != 0 ? (col, row) : nil
    }

    /// 获取终端当前工作目录（CWD）
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 当前工作目录路径，失败返回 nil
    func getCwd(terminalId: Int) -> String? {
        guard let pool = poolHandle else { return nil }

        let cStr = rio_pool_get_cwd(pool, terminalId)
        guard let cStr = cStr else { return nil }

        let result = String(cString: cStr)
        rio_free_string(cStr)
        return result
    }

    /// 使用指定 CWD 创建终端
    ///
    /// - Parameters:
    ///   - cols: 列数
    ///   - rows: 行数
    ///   - shell: Shell 路径
    ///   - cwd: 工作目录路径
    /// - Returns: 终端 ID，失败返回 -1
    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String) -> Int {
        guard let pool = poolHandle else { return -1 }

        print("🔧 [RioTerminalPoolWrapper] Calling FFI: rio_pool_create_terminal_with_cwd(cwd: \(cwd))")
        let terminalId = rio_pool_create_terminal_with_cwd(pool, cols, rows, shell, cwd)
        print("🔧 [RioTerminalPoolWrapper] FFI returned terminal ID: \(terminalId)")

        if terminalId >= 0 {
            // 为新终端创建 PendingUpdate
            pendingUpdatesLock.lock()
            pendingUpdates[Int(terminalId)] = PendingUpdate()
            pendingUpdatesLock.unlock()
        }

        return Int(terminalId)
    }
}
