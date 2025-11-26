//
//  GlobalTerminalManager.swift
//  ETerm
//
//  全局终端管理器
//
//  职责：
//  - 管理全局唯一的终端池
//  - 维护 terminalId → Coordinator 的路由表
//  - 处理事件分发
//  - 支持跨窗口终端迁移
//

import AppKit
import Foundation

/// 全局终端管理器（单例）
///
/// 所有窗口共享同一个终端池，通过 terminalId 路由事件到正确的窗口
final class GlobalTerminalManager {
    static let shared = GlobalTerminalManager()

    // MARK: - Properties

    /// 终端池句柄
    private var poolHandle: RioTerminalPoolHandle?

    /// Sugarloaf 句柄（用于初始化池，实际渲染由各窗口自己的 Sugarloaf 处理）
    private var sugarloafHandle: SugarloafHandle?

    /// 终端 ID → Coordinator 的路由表
    private var terminalRoutes: [Int: WeakCoordinatorRef] = [:]
    private let routesLock = NSLock()

    /// 待渲染更新状态（每个终端一个）
    private var pendingUpdates: [Int: PendingUpdate] = [:]
    private let pendingUpdatesLock = NSLock()

    /// 渲染回调（按窗口）
    private var renderCallbacks: [Int: () -> Void] = [:]  // windowNumber → callback
    private let callbacksLock = NSLock()

    /// 终端关闭回调
    var onTerminalClose: ((Int) -> Void)?

    /// Bell 回调
    var onBell: ((Int) -> Void)?

    /// 标题变更回调
    var onTitleChange: ((Int, String) -> Void)?

    /// 是否已初始化
    private(set) var isInitialized: Bool = false

    // MARK: - Initialization

    private init() {}

    /// 初始化终端池
    ///
    /// 必须在第一个窗口创建时调用，传入一个 SugarloafHandle
    /// 注意：虽然需要 SugarloafHandle 来创建池，但实际渲染由各窗口自己的 Sugarloaf 处理
    func initialize(with sugarloafHandle: SugarloafHandle) {
        guard !isInitialized else { return }

        self.sugarloafHandle = sugarloafHandle
        self.poolHandle = rio_pool_new(sugarloafHandle)

        setupEventCallback()
        isInitialized = true
    }

    // MARK: - Event Callback

    private func setupEventCallback() {
        guard let pool = poolHandle else { return }

        let contextPtr = Unmanaged.passUnretained(self).toOpaque()

        rio_pool_set_event_callback(
            pool,
            { (context, event) in
                guard let context = context else { return }
                let manager = Unmanaged<GlobalTerminalManager>.fromOpaque(context).takeUnretainedValue()
                manager.handleFFIEvent(event)
            },
            { (context, eventType, cStr) in
                guard let context = context else { return }
                let manager = Unmanaged<GlobalTerminalManager>.fromOpaque(context).takeUnretainedValue()
                let str = cStr != nil ? String(cString: cStr!) : ""
                manager.handleStringEvent(eventType: eventType, string: str)
            },
            contextPtr
        )
    }

    /// 处理 FFI 事件
    private func handleFFIEvent(_ ffiEvent: FFIEvent) {
        guard let eventType = RioEventType(rawValue: ffiEvent.event_type) else { return }

        let terminalId = Int(ffiEvent.route_id)

        switch eventType {
        case .wakeup:
            markDirty(terminalId: terminalId)
            // 通知对应窗口渲染
            notifyRender(for: terminalId)

        case .render:
            notifyRender(for: terminalId)

        case .bell:
            // 通过路由表通知对应的 Coordinator
            notifyBell(for: terminalId)

        case .exit, .closeTerminal:
            // 通过路由表通知对应的 Coordinator
            notifyTerminalClose(for: terminalId)

        case .cursorBlinkingChange:
            markDirty(terminalId: terminalId)

        default:
            break
        }
    }

    /// 处理字符串事件
    private func handleStringEvent(eventType: UInt32, string: String) {
        guard let type = RioEventType(rawValue: eventType) else { return }

        switch type {
        case .title:
            DispatchQueue.main.async { [weak self] in
                self?.onTitleChange?(0, string)
            }

        case .clipboardStore:
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }

        default:
            break
        }
    }

    /// 通知对应窗口需要渲染
    private func notifyRender(for terminalId: Int) {
        routesLock.lock()
        let coordinator = terminalRoutes[terminalId]?.value
        routesLock.unlock()

        if let coordinator = coordinator {
            DispatchQueue.main.async {
                coordinator.scheduleRender()
            }
        }
    }

    /// 通知对应窗口终端关闭
    private func notifyTerminalClose(for terminalId: Int) {
        routesLock.lock()
        let coordinator = terminalRoutes[terminalId]?.value
        routesLock.unlock()

        if let coordinator = coordinator {
            DispatchQueue.main.async {
                coordinator.handleTerminalClosed(terminalId: terminalId)
            }
        }
    }

    /// 通知对应窗口 Bell 事件
    private func notifyBell(for terminalId: Int) {
        routesLock.lock()
        let coordinator = terminalRoutes[terminalId]?.value
        routesLock.unlock()

        if let coordinator = coordinator {
            DispatchQueue.main.async {
                coordinator.handleBell(terminalId: terminalId)
            }
        }
    }

    /// 通知对应窗口标题变更
    private func notifyTitleChange(for terminalId: Int, title: String) {
        routesLock.lock()
        let coordinator = terminalRoutes[terminalId]?.value
        routesLock.unlock()

        if let coordinator = coordinator {
            DispatchQueue.main.async {
                coordinator.handleTitleChange(terminalId: terminalId, title: title)
            }
        }
    }

    // MARK: - Dirty State

    private func markDirty(terminalId: Int) {
        pendingUpdatesLock.lock()
        if pendingUpdates[terminalId] == nil {
            pendingUpdates[terminalId] = PendingUpdate()
        }
        pendingUpdates[terminalId]?.setDirty()
        pendingUpdatesLock.unlock()
    }

    func checkDirty(terminalId: Int) -> Bool {
        pendingUpdatesLock.lock()
        defer { pendingUpdatesLock.unlock() }
        return pendingUpdates[terminalId]?.checkAndReset() ?? false
    }

    // MARK: - Terminal Management

    /// 创建终端
    ///
    /// - Parameters:
    ///   - cols: 列数
    ///   - rows: 行数
    ///   - shell: Shell 路径
    ///   - coordinator: 所属的 Coordinator
    /// - Returns: 终端 ID，失败返回 -1
    func createTerminal(cols: UInt16, rows: UInt16, shell: String, for coordinator: TerminalWindowCoordinator) -> Int {
        guard let pool = poolHandle else { return -1 }

        let terminalId = rio_pool_create_terminal(pool, cols, rows, shell)

        if terminalId >= 0 {
            // 注册路由
            registerTerminal(Int(terminalId), for: coordinator)

            // 创建 PendingUpdate
            pendingUpdatesLock.lock()
            pendingUpdates[Int(terminalId)] = PendingUpdate()
            pendingUpdatesLock.unlock()
        }

        return Int(terminalId)
    }

    /// 使用指定 CWD 创建终端
    ///
    /// - Parameters:
    ///   - cols: 列数
    ///   - rows: 行数
    ///   - shell: Shell 路径
    ///   - cwd: 工作目录
    ///   - coordinator: 所属的 Coordinator
    /// - Returns: 终端 ID，失败返回 -1
    func createTerminalWithCwd(cols: UInt16, rows: UInt16, shell: String, cwd: String, for coordinator: TerminalWindowCoordinator) -> Int {
        guard let pool = poolHandle else { return -1 }

        print("🔧 [GlobalTerminalManager] Creating terminal with CWD: \(cwd)")
        let terminalId = rio_pool_create_terminal_with_cwd(pool, cols, rows, shell, cwd)

        if terminalId >= 0 {
            // 注册路由
            registerTerminal(Int(terminalId), for: coordinator)

            // 创建 PendingUpdate
            pendingUpdatesLock.lock()
            pendingUpdates[Int(terminalId)] = PendingUpdate()
            pendingUpdatesLock.unlock()
        }

        return Int(terminalId)
    }

    /// 关闭终端
    func closeTerminal(_ terminalId: Int) -> Bool {
        guard let pool = poolHandle else { return false }

        let result = rio_pool_close_terminal(pool, terminalId)

        if result != 0 {
            // 移除路由
            unregisterTerminal(terminalId)

            // 移除 PendingUpdate
            pendingUpdatesLock.lock()
            pendingUpdates.removeValue(forKey: terminalId)
            pendingUpdatesLock.unlock()
        }

        return result != 0
    }

    /// 获取终端数量
    func getTerminalCount() -> Int {
        guard let pool = poolHandle else { return 0 }
        return Int(rio_pool_count(pool))
    }

    // MARK: - Terminal Operations

    func writeInput(terminalId: Int, data: String) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_write_input(pool, terminalId, data) != 0
    }

    func resize(terminalId: Int, cols: UInt16, rows: UInt16) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_resize(pool, terminalId, cols, rows) != 0
    }

    func scroll(terminalId: Int, deltaLines: Int32) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_scroll(pool, terminalId, deltaLines) != 0
    }

    func getSnapshot(terminalId: Int) -> TerminalSnapshot? {
        guard let pool = poolHandle else { return nil }

        var snapshot = TerminalSnapshot()
        let result = rio_pool_get_snapshot(pool, terminalId, &snapshot)

        return result != 0 ? snapshot : nil
    }

    func getRowCells(terminalId: Int, rowIndex: Int, maxCells: Int) -> [FFICell] {
        guard let pool = poolHandle else { return [] }

        let cellsPtr = UnsafeMutablePointer<FFICell>.allocate(capacity: maxCells)
        defer { cellsPtr.deallocate() }

        cellsPtr.initialize(repeating: FFICell(), count: maxCells)
        defer { cellsPtr.deinitialize(count: maxCells) }

        let count = rio_pool_get_row_cells(pool, terminalId, rowIndex, cellsPtr, maxCells)

        return Array(UnsafeBufferPointer(start: cellsPtr, count: Int(count)))
    }

    func getCursor(terminalId: Int) -> (col: UInt16, row: UInt16)? {
        guard let pool = poolHandle else { return nil }

        var col: UInt16 = 0
        var row: UInt16 = 0
        let result = rio_pool_get_cursor(pool, terminalId, &col, &row)

        return result != 0 ? (col, row) : nil
    }

    func setSelection(terminalId: Int, startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_set_selection(
            pool,
            terminalId,
            Int(startCol),
            Int32(startRow),
            Int(endCol),
            Int32(endRow)
        ) != 0
    }

    func clearSelection(terminalId: Int) -> Bool {
        guard let pool = poolHandle else { return false }
        return rio_pool_clear_selection(pool, terminalId) != 0
    }

    func getTextRange(terminalId: Int, startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16) -> String? {
        guard let pool = poolHandle else { return nil }

        let cStr = rio_pool_get_selected_text(
            pool,
            terminalId,
            Int(startCol),
            Int32(startRow),
            Int(endCol),
            Int32(endRow)
        )

        guard let cStr = cStr else { return nil }

        let result = String(cString: cStr)
        rio_free_string(cStr)
        return result
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

    // MARK: - Routing

    /// 注册终端到 Coordinator
    func registerTerminal(_ terminalId: Int, for coordinator: TerminalWindowCoordinator) {
        routesLock.lock()
        terminalRoutes[terminalId] = WeakCoordinatorRef(coordinator)
        routesLock.unlock()
    }

    /// 注销终端
    func unregisterTerminal(_ terminalId: Int) {
        routesLock.lock()
        terminalRoutes.removeValue(forKey: terminalId)
        routesLock.unlock()
    }

    /// 获取终端所属的 Coordinator
    func getCoordinator(for terminalId: Int) -> TerminalWindowCoordinator? {
        routesLock.lock()
        defer { routesLock.unlock() }
        return terminalRoutes[terminalId]?.value
    }

    // MARK: - Cross-Window Migration

    /// 迁移终端到另一个 Coordinator
    ///
    /// 这是跨窗口拖动的核心方法：只需要更新路由表，终端本身不移动
    ///
    /// - Parameters:
    ///   - terminalId: 要迁移的终端 ID
    ///   - targetCoordinator: 目标 Coordinator
    func migrateTerminal(_ terminalId: Int, to targetCoordinator: TerminalWindowCoordinator) {
        routesLock.lock()
        terminalRoutes[terminalId] = WeakCoordinatorRef(targetCoordinator)
        routesLock.unlock()
    }

    /// 批量迁移终端（用于 Page 拖动）
    func migrateTerminals(_ terminalIds: [Int], to targetCoordinator: TerminalWindowCoordinator) {
        routesLock.lock()
        for terminalId in terminalIds {
            terminalRoutes[terminalId] = WeakCoordinatorRef(targetCoordinator)
        }
        routesLock.unlock()
    }

    // MARK: - Cleanup

    /// 清理已释放的 Coordinator 引用
    func cleanupStaleRoutes() {
        routesLock.lock()
        terminalRoutes = terminalRoutes.filter { $0.value.value != nil }
        routesLock.unlock()
    }
}

// MARK: - Helper Types

/// 弱引用包装器
private class WeakCoordinatorRef {
    weak var value: TerminalWindowCoordinator?

    init(_ value: TerminalWindowCoordinator) {
        self.value = value
    }
}
