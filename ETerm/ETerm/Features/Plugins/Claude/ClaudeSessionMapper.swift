//
//  ClaudeSessionMapper.swift
//  ETerm
//
//  管理 Terminal ID ↔ Claude Session ID 的映射关系
//

import Foundation

/// Claude Session 映射管理器
class ClaudeSessionMapper {
    static let shared = ClaudeSessionMapper()

    /// terminal_id → session_id
    private var terminalToSession: [Int: String] = [:]

    /// session_id → terminal_id
    private var sessionToTerminal: [String: Int] = [:]

    private let lock = NSLock()

    private init() {}

    /// 建立映射关系
    func map(terminalId: Int, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }

        // 清理旧的映射（如果该 terminal 之前有其他 session）
        if let oldSessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: oldSessionId)
        }

        // 建立新映射
        terminalToSession[terminalId] = sessionId
        sessionToTerminal[sessionId] = terminalId

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
    func remove(terminalId: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let sessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: sessionId)
            terminalToSession.removeValue(forKey: terminalId)
        }
    }

    /// 清空所有映射
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        terminalToSession.removeAll()
        sessionToTerminal.removeAll()
    }


    /// 获取所有映射（session_id → terminal_id）
    func getAllMappings() -> [(sessionId: String, terminalId: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return sessionToTerminal.map { ($0.key, $0.value) }
    }
}
