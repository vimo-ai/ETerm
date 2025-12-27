//
//  ClaudeSessionMapper.swift
//  ETerm
//
//  Claude Session 存储（ClaudePlugin 专属）
//
//  设计原则：
//  - 单一写入者：只有 ClaudePlugin 调用写入方法
//  - 运行时映射：terminalId ↔ sessionId（快速查询）
//  - 持久化映射：tabId → sessionId（重启恢复）
//

import Foundation

// MARK: - Claude 插件持久化数据

/// Claude 插件状态（用于持久化）
struct ClaudePluginState: Codable {
    /// tabId (UUID string) → sessionId
    /// 使用 tabId 而非 terminalId，因为 tabId 是稳定的
    var sessions: [String: String]

    init(sessions: [String: String] = [:]) {
        self.sessions = sessions
    }
}

// MARK: - Claude Session Store

/// Claude Session 存储
///
/// 管理 Claude 会话与终端的映射关系，支持持久化恢复。
///
/// ## 职责
/// - 维护 terminalId ↔ sessionId 运行时映射（快速查询）
/// - 维护 tabId → sessionId 持久化映射（重启恢复）
/// - 与 SessionManager 交互进行持久化
///
/// ## 设计原则
/// - **单一写入者**：只有 ClaudePlugin 调用 establish/end 方法
/// - 其他组件（如 VlaudePlugin）通过通知获取信息，不直接写入
///
final class ClaudeSessionMapper {
    static let shared = ClaudeSessionMapper()

    private static let namespace = "claude"

    // MARK: - 运行时映射

    /// terminalId → sessionId
    private var terminalToSession: [Int: String] = [:]

    /// sessionId → terminalId
    private var sessionToTerminal: [String: Int] = [:]

    // MARK: - 持久化映射

    /// tabId → sessionId（用于恢复）
    private var tabToSession: [String: String] = [:]

    private let lock = NSLock()

    /// 串行队列，保证保存操作顺序执行
    private let saveQueue = DispatchQueue(label: "com.eterm.claude.session-mapper.save")

    private init() {
        loadFromStorage()
    }

    // MARK: - 写入 API（仅 ClaudePlugin 调用）

    /// 建立 Session 映射
    ///
    /// 当 Claude session 开始时调用。
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - sessionId: Claude Session ID
    ///   - tabId: Tab UUID string（用于持久化恢复）
    func establish(terminalId: Int, sessionId: String, tabId: String) {
        lock.lock()
        defer { lock.unlock() }

        // 清理旧的映射（如果该 terminal 之前有其他 session）
        if let oldSessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: oldSessionId)
        }

        // 建立运行时映射
        terminalToSession[terminalId] = sessionId
        sessionToTerminal[sessionId] = terminalId

        // 建立持久化映射
        tabToSession[tabId] = sessionId

        // 串行队列异步保存，保证顺序
        saveQueue.async { [weak self] in
            self?.saveToStorage()
        }
    }

    /// 结束 Session 映射
    ///
    /// 当 Claude session 结束或终端关闭时调用。
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - tabId: Tab UUID string
    func end(terminalId: Int, tabId: String) {
        lock.lock()

        // 清理运行时映射
        if let sessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: sessionId)
            terminalToSession.removeValue(forKey: terminalId)
        }

        // 清理持久化映射
        tabToSession.removeValue(forKey: tabId)

        lock.unlock()

        // 串行队列异步保存，保证顺序
        saveQueue.async { [weak self] in
            self?.saveToStorage()
        }
    }

    // MARK: - 读取 API

    /// 根据 terminalId 查找 sessionId
    func getSessionId(for terminalId: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return terminalToSession[terminalId]
    }

    /// 根据 sessionId 查找 terminalId
    func getTerminalId(for sessionId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return sessionToTerminal[sessionId]
    }

    /// 根据 tabId 获取 sessionId（用于恢复）
    func getSessionIdForTab(_ tabId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession[tabId]
    }

    /// 检查 tabId 是否有关联的 session
    func hasSessionForTab(_ tabId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession[tabId] != nil
    }

    /// 获取所有运行时映射
    func getAllMappings() -> [(sessionId: String, terminalId: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return sessionToTerminal.map { ($0.key, $0.value) }
    }

    // MARK: - 兼容 API（逐步废弃）

    /// 建立映射关系（兼容旧 API）
    @available(*, deprecated, message: "Use establish(terminalId:sessionId:tabId:) instead")
    func map(terminalId: Int, sessionId: String, tabId: String? = nil) {
        if let tabId = tabId {
            establish(terminalId: terminalId, sessionId: sessionId, tabId: tabId)
        } else {
            // 只建立运行时映射
            lock.lock()
            defer { lock.unlock() }

            if let oldSessionId = terminalToSession[terminalId] {
                sessionToTerminal.removeValue(forKey: oldSessionId)
            }
            terminalToSession[terminalId] = sessionId
            sessionToTerminal[sessionId] = terminalId
        }
    }

    /// 移除映射（兼容旧 API）
    @available(*, deprecated, message: "Use end(terminalId:tabId:) instead")
    func remove(terminalId: Int, tabId: String? = nil) {
        lock.lock()

        if let sessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: sessionId)
            terminalToSession.removeValue(forKey: terminalId)
        }

        if let tabId = tabId {
            tabToSession.removeValue(forKey: tabId)
        }

        lock.unlock()

        if tabId != nil {
            saveQueue.async { [weak self] in
                self?.saveToStorage()
            }
        }
    }

    /// 根据 tabId 移除持久化映射（兼容旧 API）
    @available(*, deprecated, message: "Use end(terminalId:tabId:) instead")
    func removeByTabId(_ tabId: String) {
        lock.lock()
        tabToSession.removeValue(forKey: tabId)
        lock.unlock()

        saveQueue.async { [weak self] in
            self?.saveToStorage()
        }
    }

    /// 清空所有映射
    func clear() {
        lock.lock()
        terminalToSession.removeAll()
        sessionToTerminal.removeAll()
        tabToSession.removeAll()
        lock.unlock()

        saveQueue.async { [weak self] in
            self?.saveToStorage()
        }
    }

    // MARK: - 持久化

    private func loadFromStorage() {
        guard let jsonString = SessionManager.shared.getPluginData(namespace: Self.namespace),
              let data = jsonString.data(using: .utf8) else {
            return
        }

        do {
            let state = try JSONDecoder().decode(ClaudePluginState.self, from: data)
            lock.lock()
            tabToSession = state.sessions
            lock.unlock()
        } catch {
            // 解析失败，使用空数据
        }
    }

    private func saveToStorage() {
        lock.lock()
        let state = ClaudePluginState(sessions: tabToSession)
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(state)
            if let jsonString = String(data: data, encoding: .utf8) {
                SessionManager.shared.setPluginData(namespace: Self.namespace, data: jsonString)
            }
        } catch {
            // 保存失败，静默处理
        }
    }
}
