//
//  ClaudeSessionMapper.swift
//  ClaudeKit
//
//  Claude Session 存储（SDK 版本）
//
//  设计原则：
//  - 运行时映射：terminalId ↔ sessionId（快速查询）
//  - 持久化映射：tabId → sessionId（重启恢复）
//  - 使用本地文件存储（$ETERM_HOME/plugins/claude/sessions.json）

import Foundation
import ETermKit

/// Claude 插件状态（用于持久化）
struct ClaudePluginState: Codable {
    /// tabId (UUID string) → sessionId
    var sessions: [String: String]

    init(sessions: [String: String] = [:]) {
        self.sessions = sessions
    }
}

/// Claude Session 存储
///
/// 管理 Claude 会话与终端的映射关系，支持持久化恢复。
final class ClaudeSessionMapper {
    static let shared = ClaudeSessionMapper()

    /// 持久化文件路径
    private var storagePath: String {
        return ETermPaths.plugins + "/claude/sessions.json"
    }

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
        ensureDirectory()
        migrateFromSessionManager()
        loadFromStorage()
    }

    // MARK: - Migration

    /// 老版本 session.json 路径
    private var legacySessionPath: String {
        return ETermPaths.config + "/session.json"
    }

    /// 从老版本 SessionManager 迁移数据
    ///
    /// 老版本存储在 `~/.eterm/config/session.json` 的 `plugins.claude` 字段
    private func migrateFromSessionManager() {
        // 如果新存储已有数据，跳过迁移
        if FileManager.default.fileExists(atPath: storagePath) {
            return
        }

        // 检查老存储是否存在
        guard FileManager.default.fileExists(atPath: legacySessionPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: legacySessionPath)) else {
            return
        }

        // 解析老版本 session.json
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plugins = json["plugins"] as? [String: Any],
                  let claudeDataString = plugins["claude"] as? String,
                  let claudeData = claudeDataString.data(using: .utf8) else {
                print("[ClaudeKit] Migration: invalid data format")
                return
            }

            // 解析 claude 插件数据
            let state = try JSONDecoder().decode(ClaudePluginState.self, from: claudeData)

            // 写入新存储
            lock.lock()
            tabToSession = state.sessions
            lock.unlock()

            // 保存到新位置
            saveToStorage()

            print("[ClaudeKit] Migrated \(state.sessions.count) sessions from legacy storage")
        } catch {
            print("[ClaudeKit] Migration failed: \(error)")
        }
    }

    // MARK: - 写入 API

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

        // 串行队列异步保存
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

        // 串行队列异步保存
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

    /// 获取 session 数量
    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession.count
    }

    // MARK: - 持久化

    private func ensureDirectory() {
        let directory = (storagePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    private func loadFromStorage() {
        guard FileManager.default.fileExists(atPath: storagePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)) else {
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: URL(fileURLWithPath: storagePath))
        } catch {
            // 保存失败，静默处理
        }
    }
}
