//
//  ClaudeSessionMapper.swift
//  ETerm
//
//  管理 Terminal ID ↔ Claude Session ID 的映射关系
//  支持持久化，用于重启后恢复 Claude 会话
//

import Foundation

// MARK: - Claude 插件持久化数据

/// Claude 插件状态（用于持久化）
struct ClaudePluginState: Codable {
    /// tabId (UUID string) → sessionId
    /// 使用 tabId 而非 terminalId，因为 terminalId 是运行时生成的
    var sessions: [String: String]

    init(sessions: [String: String] = [:]) {
        self.sessions = sessions
    }
}

// MARK: - Claude Session 映射管理器

/// Claude Session 映射管理器
class ClaudeSessionMapper {
    static let shared = ClaudeSessionMapper()

    private static let namespace = "claude"

    /// terminalId → sessionId（运行时映射）
    private var terminalToSession: [Int: String] = [:]

    /// sessionId → terminalId（运行时映射）
    private var sessionToTerminal: [String: Int] = [:]

    /// tabId → sessionId（持久化映射）
    private var tabToSession: [String: String] = [:]

    private let lock = NSLock()

    private init() {
        // 启动时从 SessionManager 加载持久化数据
        loadFromStorage()
    }

    // MARK: - 持久化

    /// 从存储加载
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

    /// 保存到存储
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

    // MARK: - 运行时映射

    /// 建立映射关系
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID（运行时）
    ///   - sessionId: Claude Session ID
    ///   - tabId: Tab UUID string（用于持久化，可选）
    func map(terminalId: Int, sessionId: String, tabId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        // 清理旧的映射（如果该 terminal 之前有其他 session）
        if let oldSessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: oldSessionId)
        }

        // 建立运行时映射
        terminalToSession[terminalId] = sessionId
        sessionToTerminal[sessionId] = terminalId

        // 如果提供了 tabId，建立持久化映射
        if let tabId = tabId {
            tabToSession[tabId] = sessionId
            // 异步保存，避免阻塞
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.saveToStorage()
            }
        }
    }

    /// 根据 terminal_id 查找 session_id
    func getSessionId(for terminalId: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return terminalToSession[terminalId]
    }

    /// 根据 session_id 查找 terminal_id
    func getTerminalId(for sessionId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return sessionToTerminal[sessionId]
    }

    /// 移除映射（terminal 关闭时调用）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - tabId: Tab UUID string（可选，用于清理持久化数据）
    func remove(terminalId: Int, tabId: String? = nil) {
        lock.lock()

        if let sessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: sessionId)
            terminalToSession.removeValue(forKey: terminalId)
        }

        // 如果提供了 tabId，同时清理持久化映射
        if let tabId = tabId {
            tabToSession.removeValue(forKey: tabId)
        }

        lock.unlock()

        // 如果清理了持久化数据，保存
        if tabId != nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.saveToStorage()
            }
        }
    }

    /// 清空所有映射
    func clear() {
        lock.lock()
        terminalToSession.removeAll()
        sessionToTerminal.removeAll()
        tabToSession.removeAll()
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveToStorage()
        }
    }

    /// 获取所有映射（session_id → terminal_id）
    func getAllMappings() -> [(sessionId: String, terminalId: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return sessionToTerminal.map { ($0.key, $0.value) }
    }

    // MARK: - 持久化映射（用于恢复）

    /// 根据 tabId 获取 sessionId（用于恢复）
    ///
    /// - Parameter tabId: Tab UUID string
    /// - Returns: 关联的 Claude Session ID，不存在返回 nil
    func getSessionIdForTab(_ tabId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession[tabId]
    }

    /// 根据 tabId 移除持久化映射
    ///
    /// - Parameter tabId: Tab UUID string
    func removeByTabId(_ tabId: String) {
        lock.lock()
        tabToSession.removeValue(forKey: tabId)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveToStorage()
        }
    }

    /// 检查 tabId 是否有关联的 session（用于判断是否需要恢复）
    func hasSessionForTab(_ tabId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession[tabId] != nil
    }
}
