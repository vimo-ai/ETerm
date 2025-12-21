//
//  TerminalWorkingDirectoryRegistry.swift
//  ETerm
//
//  终端工作目录注册表（领域服务）
//
//  职责：
//  - 管理所有终端的 CWD 状态（Single Source of Truth）
//  - 提供统一的查询接口
//  - 协调不同来源的 CWD 获取策略
//  - 支持终端生命周期的状态迁移
//
//  设计原则：
//  - Single Source of Truth: 所有 CWD 状态集中管理
//  - 非破坏性查询: 查询操作不改变状态
//  - 幂等性: 多次查询返回一致结果
//  - 状态机: 明确的 Pending → Active → Detached 状态转换
//
//  状态生命周期：
//  ┌─────────────────────────────────────────────────────┐
//  │  Session 恢复                                        │
//  │  registerPendingTerminal() → [Pending State]        │
//  └─────────────────────────────────────────────────────┘
//                            │
//          ┌─────────────────┴─────────────────┐
//          │                                   │
//          ▼ 创建成功                           ▼ 创建失败
//    promotePendingTerminal()            retainPendingTerminal()
//          │                                   │
//          ▼                                   │
//    [Active State]                            └──► 重试（状态保留）
//          │
//          │ Pool 切换 / 跨窗口迁移
//          ▼
//    captureBeforePoolTransition()
//          │
//          ▼
//    [Detached State] ──► 重新附加 ──► [Active State]
//

import Foundation

/// 终端工作目录注册表
///
/// 集中管理所有终端的工作目录状态，提供统一的查询和状态迁移接口。
/// 解决了原有架构中 `takePendingCwd()` 一次性消费导致的状态丢失问题。
final class TerminalWorkingDirectoryRegistry {

    // MARK: - State

    /// 已创建终端的 CWD 状态
    /// Key: rustTerminalId
    private var activeTerminals: [Int: WorkingDirectory] = [:]

    /// 待创建终端的 CWD 状态
    /// Key: tabId
    private var pendingTerminals: [UUID: WorkingDirectory] = [:]

    /// 分离终端的 CWD 状态（用于 Pool 切换、跨窗口迁移）
    /// Key: tabId
    private var detachedTerminals: [UUID: WorkingDirectory] = [:]

    /// terminalId → tabId 的反向映射（用于快速查找）
    private var terminalToTabMapping: [Int: UUID] = [:]

    /// 终端池引用（用于查询运行时 CWD）
    private weak var terminalPool: TerminalPoolProtocol?

    /// 线程安全锁
    private let lock = NSLock()

    // MARK: - Initialization

    init() {}

    // MARK: - Terminal Pool

    /// 设置终端池（用于查询运行时 CWD）
    ///
    /// - Parameter pool: 终端池实例
    func setTerminalPool(_ pool: TerminalPoolProtocol?) {
        lock.lock()
        defer { lock.unlock() }
        self.terminalPool = pool
    }

    // MARK: - Registration (Pending State)

    /// 注册待创建终端的 CWD
    ///
    /// 在 Session 恢复时调用，将恢复的 CWD 注册到 pending 状态。
    /// 终端创建成功后通过 `promotePendingTerminal()` 迁移到 active 状态。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - workingDirectory: 工作目录
    func registerPendingTerminal(tabId: UUID, workingDirectory: WorkingDirectory) {
        lock.lock()
        defer { lock.unlock() }
        pendingTerminals[tabId] = workingDirectory
        logDebug("[CWD Registry] Registered pending: tabId=\(tabId.uuidString.prefix(8)), cwd=\(workingDirectory.path)")
    }

    /// 获取待创建终端的 CWD（非破坏性）
    ///
    /// 与原有的 `takePendingCwd()` 不同，此方法不会消费状态。
    ///
    /// - Parameter tabId: Tab ID
    /// - Returns: 工作目录（如果存在）
    func getPendingCwd(tabId: UUID) -> WorkingDirectory? {
        lock.lock()
        defer { lock.unlock() }
        return pendingTerminals[tabId]
    }

    // MARK: - Promotion (Pending → Active)

    /// 终端创建成功后，迁移状态
    ///
    /// 将 pending 状态迁移到 active 状态，并建立 terminalId → tabId 的映射。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - terminalId: Rust 终端 ID
    func promotePendingTerminal(tabId: UUID, terminalId: Int) {
        lock.lock()
        defer { lock.unlock() }

        // 从 pending 迁移到 active
        if let pending = pendingTerminals.removeValue(forKey: tabId) {
            activeTerminals[terminalId] = pending
            terminalToTabMapping[terminalId] = tabId
            logDebug("[CWD Registry] Promoted: tabId=\(tabId.uuidString.prefix(8)) → terminalId=\(terminalId)")
        }
    }

    /// 终端创建失败，保留 pending 状态（支持重试）
    ///
    /// 与原有的 `takePendingCwd()` 不同，此方法在创建失败时不会消费状态，
    /// 确保后续重试时仍能获取到正确的 CWD。
    ///
    /// - Parameter tabId: Tab ID
    /// - Returns: 保留的工作目录（用于日志或下次重试）
    @discardableResult
    func retainPendingTerminal(tabId: UUID) -> WorkingDirectory? {
        lock.lock()
        defer { lock.unlock() }

        let cwd = pendingTerminals[tabId]
        if let cwd = cwd {
            logDebug("[CWD Registry] Retained pending for retry: tabId=\(tabId.uuidString.prefix(8)), cwd=\(cwd.path)")
        }
        return cwd
    }

    // MARK: - Active State Management

    /// 更新已创建终端的 CWD
    ///
    /// 当收到 OSC 7 更新时调用，更新 active 终端的 CWD。
    ///
    /// - Parameters:
    ///   - terminalId: Rust 终端 ID
    ///   - workingDirectory: 新的工作目录
    func updateActiveTerminal(terminalId: Int, workingDirectory: WorkingDirectory) {
        lock.lock()
        defer { lock.unlock() }

        // 只有当新值优先级更高时才更新
        if let existing = activeTerminals[terminalId] {
            activeTerminals[terminalId] = existing.preferring(workingDirectory)
        } else {
            activeTerminals[terminalId] = workingDirectory
        }
    }

    /// 直接注册 active 终端（跳过 pending 阶段）
    ///
    /// 用于新建 Tab 等场景，终端创建时直接指定 CWD。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - terminalId: Rust 终端 ID
    ///   - workingDirectory: 工作目录
    func registerActiveTerminal(tabId: UUID, terminalId: Int, workingDirectory: WorkingDirectory) {
        lock.lock()
        defer { lock.unlock() }

        activeTerminals[terminalId] = workingDirectory
        terminalToTabMapping[terminalId] = tabId
        logDebug("[CWD Registry] Registered active: tabId=\(tabId.uuidString.prefix(8)), terminalId=\(terminalId)")
    }

    // MARK: - Detach/Reattach (Pool Transition)

    /// 分离终端（Pool 切换、跨窗口迁移）
    ///
    /// 在终端被关闭或分离前调用，捕获当前的 CWD 到 detached 状态。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - terminalId: Rust 终端 ID
    func detachTerminal(tabId: UUID, terminalId: Int) {
        lock.lock()
        defer { lock.unlock() }

        // 先尝试获取最新的运行时 CWD
        let cwd = queryActiveTerminalInternal(terminalId: terminalId)

        // 从 active 移除
        activeTerminals.removeValue(forKey: terminalId)
        terminalToTabMapping.removeValue(forKey: terminalId)

        // 保存到 detached
        detachedTerminals[tabId] = cwd
        logDebug("[CWD Registry] Detached: tabId=\(tabId.uuidString.prefix(8)), terminalId=\(terminalId), cwd=\(cwd.path)")
    }

    /// 重新附加终端（Pool 切换完成、跨窗口迁移完成）
    ///
    /// 在终端被重新创建后调用，将 detached 状态迁移到 active。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - newTerminalId: 新的 Rust 终端 ID
    func reattachTerminal(tabId: UUID, newTerminalId: Int) {
        lock.lock()
        defer { lock.unlock() }

        // 从 detached 迁移到 active
        if let detached = detachedTerminals.removeValue(forKey: tabId) {
            activeTerminals[newTerminalId] = detached
            terminalToTabMapping[newTerminalId] = tabId
            logDebug("[CWD Registry] Reattached: tabId=\(tabId.uuidString.prefix(8)) → terminalId=\(newTerminalId)")
        }
    }

    // MARK: - Removal

    /// 移除终端（关闭时调用）
    ///
    /// - Parameter terminalId: Rust 终端 ID
    func removeTerminal(terminalId: Int) {
        lock.lock()
        defer { lock.unlock() }

        activeTerminals.removeValue(forKey: terminalId)
        terminalToTabMapping.removeValue(forKey: terminalId)
        logDebug("[CWD Registry] Removed terminal: terminalId=\(terminalId)")
    }

    /// 清除 Tab 的所有状态（Tab 被删除时调用）
    ///
    /// - Parameter tabId: Tab ID
    func clearTab(tabId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        pendingTerminals.removeValue(forKey: tabId)
        detachedTerminals.removeValue(forKey: tabId)

        // 清除对应的 active 映射
        if let terminalId = terminalToTabMapping.first(where: { $0.value == tabId })?.key {
            activeTerminals.removeValue(forKey: terminalId)
            terminalToTabMapping.removeValue(forKey: terminalId)
        }

        logDebug("[CWD Registry] Cleared tab: tabId=\(tabId.uuidString.prefix(8))")
    }

    // MARK: - Query (Core Interface)

    /// 查询 Tab 的工作目录（统一接口）
    ///
    /// 这是核心查询方法，按优先级查找 CWD：
    /// 1. 已创建终端: 查询运行时 CWD（OSC 7 > proc_pidinfo > 缓存）
    /// 2. 分离终端: 使用分离时捕获的 CWD
    /// 3. 待创建终端: 使用注册的 CWD
    /// 4. 都没有: 返回用户主目录
    ///
    /// **重要**: 此方法总能返回有效值，不会返回 nil。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - terminalId: Rust 终端 ID（可选）
    /// - Returns: 工作目录（保证有效）
    func queryWorkingDirectory(tabId: UUID, terminalId: Int?) -> WorkingDirectory {
        lock.lock()
        defer { lock.unlock() }

        // 1. 优先查询已创建终端的运行时 CWD
        if let tid = terminalId {
            return queryActiveTerminalInternal(terminalId: tid)
        }

        // 2. 查询分离终端
        if let detached = detachedTerminals[tabId] {
            logDebug("[CWD Registry] Query result (detached): tabId=\(tabId.uuidString.prefix(8)), cwd=\(detached.path)")
            return detached
        }

        // 3. 查询待创建终端
        if let pending = pendingTerminals[tabId] {
            logDebug("[CWD Registry] Query result (pending): tabId=\(tabId.uuidString.prefix(8)), cwd=\(pending.path)")
            return pending
        }

        // 4. 默认值
        let defaultCwd = WorkingDirectory.userHome()
        logDebug("[CWD Registry] Query result (default): tabId=\(tabId.uuidString.prefix(8)), cwd=\(defaultCwd.path)")
        return defaultCwd
    }

    /// 查询已创建终端的运行时 CWD（内部方法）
    ///
    /// - Parameter terminalId: Rust 终端 ID
    /// - Returns: 工作目录
    private func queryActiveTerminalInternal(terminalId: Int) -> WorkingDirectory {
        // 1. 尝试从 OSC 7 缓存获取（最可靠）
        if let pool = terminalPool, let cachedPath = pool.getCachedCwd(terminalId: terminalId) {
            let cwd = WorkingDirectory.fromOSC7(path: cachedPath)
            // 更新缓存
            activeTerminals[terminalId] = cwd
            return cwd
        }

        // 2. Fallback 到 proc_pidinfo
        if let pool = terminalPool, let runtimePath = pool.getCwd(terminalId: terminalId) {
            let cwd = WorkingDirectory.fromProcPidinfo(path: runtimePath)
            // 不更新缓存，因为 proc_pidinfo 可能不可靠
            return cwd
        }

        // 3. 使用缓存的值（如果有）
        if let cached = activeTerminals[terminalId] {
            return cached
        }

        // 4. 默认值
        return .userHome()
    }

    // MARK: - Pool Transition

    /// Pool 切换前: 捕获所有活跃终端的 CWD
    ///
    /// 在 `setTerminalPool()` 关闭旧终端之前调用，确保 CWD 不丢失。
    ///
    /// - Parameter tabIdMapping: [terminalId: tabId] 映射表
    func captureBeforePoolTransition(tabIdMapping: [Int: UUID]) {
        lock.lock()
        defer { lock.unlock() }

        logDebug("[CWD Registry] Capturing before pool transition: \(tabIdMapping.count) terminals")

        for (terminalId, tabId) in tabIdMapping {
            let cwd = queryActiveTerminalInternal(terminalId: terminalId)
            // 保存到 detached 状态
            detachedTerminals[tabId] = cwd
            logDebug("[CWD Registry] Captured: tabId=\(tabId.uuidString.prefix(8)), terminalId=\(terminalId), cwd=\(cwd.path)")
        }

        // 清空 active 状态
        activeTerminals.removeAll()
        terminalToTabMapping.removeAll()
    }

    /// Pool 切换后: 恢复所有终端的 CWD
    ///
    /// 在新终端创建完成后调用，将 detached 状态迁移到 active。
    ///
    /// - Parameter tabIdMapping: [tabId: newTerminalId] 映射表
    func restoreAfterPoolTransition(tabIdMapping: [UUID: Int]) {
        lock.lock()
        defer { lock.unlock() }

        logDebug("[CWD Registry] Restoring after pool transition: \(tabIdMapping.count) terminals")

        for (tabId, newTerminalId) in tabIdMapping {
            if let detached = detachedTerminals.removeValue(forKey: tabId) {
                activeTerminals[newTerminalId] = detached
                terminalToTabMapping[newTerminalId] = tabId
                logDebug("[CWD Registry] Restored: tabId=\(tabId.uuidString.prefix(8)) → terminalId=\(newTerminalId)")
            }
        }
    }

    // MARK: - Snapshot (For Session Save)

    /// 获取所有工作目录快照（用于 Session 保存）
    ///
    /// 返回所有 Tab 的当前 CWD 状态，包括：
    /// - Active 终端的运行时 CWD
    /// - Detached 终端的缓存 CWD
    /// - Pending 终端的恢复 CWD
    ///
    /// - Parameter allTabs: 所有 Tab 的 (tabId, terminalId?) 列表
    /// - Returns: [tabId: WorkingDirectory]
    func snapshotAllWorkingDirectories(allTabs: [(tabId: UUID, terminalId: Int?)]) -> [UUID: WorkingDirectory] {
        lock.lock()
        defer { lock.unlock() }

        var result: [UUID: WorkingDirectory] = [:]

        for (tabId, terminalId) in allTabs {
            // 优先使用 active
            if let tid = terminalId {
                result[tabId] = queryActiveTerminalInternal(terminalId: tid)
            }
            // 其次 detached
            else if let detached = detachedTerminals[tabId] {
                result[tabId] = detached
            }
            // 再次 pending
            else if let pending = pendingTerminals[tabId] {
                result[tabId] = pending
            }
            // 默认值
            else {
                result[tabId] = .userHome()
            }
        }

        return result
    }

    // MARK: - Helper

    /// 通过 terminalId 查找 tabId
    ///
    /// - Parameter terminalId: Rust 终端 ID
    /// - Returns: Tab ID（如果存在映射）
    func getTabId(for terminalId: Int) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return terminalToTabMapping[terminalId]
    }

    // MARK: - Debug

    /// 调试信息
    var debugDescription: String {
        lock.lock()
        defer { lock.unlock() }

        return """
        TerminalWorkingDirectoryRegistry {
            active: \(activeTerminals.count) terminals
            pending: \(pendingTerminals.count) terminals
            detached: \(detachedTerminals.count) terminals
            mappings: \(terminalToTabMapping.count) entries
        }
        """
    }

    /// 日志辅助方法（已禁用）
    private func logDebug(_ message: String) {
        // 日志已禁用
    }
}
