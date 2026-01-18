//
//  AICliSessionMapper.swift
//  AICliKit
//
//  AI CLI Session 存储（通用版本）
//
//  设计原则：
//  - 运行时映射：terminalId ↔ sessionId（快速查询）
//  - 持久化映射：tabId → sessionId（重启恢复）
//  - 使用本地文件存储（$ETERM_HOME/plugins/aicli/sessions.json）
//  - 支持多种 AI CLI（Claude、Gemini、Codex、OpenCode）

import Foundation
import ETermKit

/// AI CLI 插件状态（用于持久化）
struct AICliPluginState: Codable {
    /// tabId (UUID string) → sessionId
    var sessions: [String: String]

    /// tabId → provider ID（记录会话来源）
    var providers: [String: String]

    init(sessions: [String: String] = [:], providers: [String: String] = [:]) {
        self.sessions = sessions
        self.providers = providers
    }
}

/// AI CLI Session 存储
///
/// 管理 AI CLI 会话与终端的映射关系，支持持久化恢复。
/// 支持多种 AI CLI Provider。
final class AICliSessionMapper {
    static let shared = AICliSessionMapper()

    /// 持久化文件路径
    private var storagePath: String {
        return ETermPaths.plugins + "/aicli/sessions.json"
    }

    /// 旧版 ClaudeKit 存储路径（用于迁移）
    private var legacyClaudePath: String {
        return ETermPaths.plugins + "/claude/sessions.json"
    }

    // MARK: - 运行时映射

    /// terminalId → sessionId
    private var terminalToSession: [Int: String] = [:]

    /// sessionId → terminalId
    private var sessionToTerminal: [String: Int] = [:]

    /// terminalId → providerId（记录当前 provider）
    private var terminalToProvider: [Int: String] = [:]

    // MARK: - 持久化映射

    /// tabId → sessionId（用于恢复）
    private var tabToSession: [String: String] = [:]

    /// tabId → providerId（用于恢复时选择正确的 provider）
    private var tabToProvider: [String: String] = [:]

    private let lock = NSLock()

    /// 串行队列，保证保存操作顺序执行
    private let saveQueue = DispatchQueue(label: "com.eterm.aicli.session-mapper.save")

    private init() {
        ensureDirectory()
        migrateFromClaudeKit()
        migrateFromSessionManager()
        loadFromStorage()
    }

    // MARK: - Migration

    /// 老版本 session.json 路径
    private var legacySessionPath: String {
        return ETermPaths.config + "/session.json"
    }

    /// 从老版本 ClaudeKit 迁移数据
    private func migrateFromClaudeKit() {
        // 如果新存储已有数据，跳过迁移
        if FileManager.default.fileExists(atPath: storagePath) {
            return
        }

        // 检查旧 ClaudeKit 存储是否存在
        guard FileManager.default.fileExists(atPath: legacyClaudePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: legacyClaudePath)) else {
            return
        }

        // 解析旧格式（ClaudePluginState）
        struct LegacyState: Codable {
            var sessions: [String: String]
        }

        do {
            let legacyState = try JSONDecoder().decode(LegacyState.self, from: data)

            lock.lock()
            tabToSession = legacyState.sessions
            // 旧数据都是 Claude，设置 provider
            for tabId in legacyState.sessions.keys {
                tabToProvider[tabId] = "claude"
            }
            lock.unlock()

            saveToStorage()

            logInfo("[AICliKit] Migrated \(legacyState.sessions.count) sessions from ClaudeKit")
        } catch {
            logError("[AICliKit] ClaudeKit migration failed: \(error)")
        }
    }

    /// 从老版本 SessionManager 迁移数据
    ///
    /// 老版本存储在 `~/.vimo/eterm/config/session.json` 的 `plugins.claude` 字段
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
                logWarn("[AICliKit] Migration: invalid data format")
                return
            }

            // 解析 claude 插件数据
            struct LegacyState: Codable {
                var sessions: [String: String]
            }

            let state = try JSONDecoder().decode(LegacyState.self, from: claudeData)

            // 写入新存储
            lock.lock()
            tabToSession = state.sessions
            for tabId in state.sessions.keys {
                tabToProvider[tabId] = "claude"
            }
            lock.unlock()

            // 保存到新位置
            saveToStorage()

            logInfo("[AICliKit] Migrated \(state.sessions.count) sessions from legacy storage")
        } catch {
            logError("[AICliKit] Migration failed: \(error)")
        }
    }

    // MARK: - 写入 API

    /// 建立 Session 映射
    ///
    /// 当 AI CLI session 开始时调用。
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - sessionId: Session ID
    ///   - tabId: Tab UUID string（用于持久化恢复）
    ///   - providerId: Provider 标识（claude, gemini, codex, opencode）
    func establish(terminalId: Int, sessionId: String, tabId: String, providerId: String) {
        lock.lock()
        defer { lock.unlock() }

        // 清理旧的映射（如果该 terminal 之前有其他 session）
        if let oldSessionId = terminalToSession[terminalId] {
            sessionToTerminal.removeValue(forKey: oldSessionId)
        }

        // 建立运行时映射
        terminalToSession[terminalId] = sessionId
        sessionToTerminal[sessionId] = terminalId
        terminalToProvider[terminalId] = providerId

        // 建立持久化映射
        tabToSession[tabId] = sessionId
        tabToProvider[tabId] = providerId

        // 串行队列异步保存
        saveQueue.async { [weak self] in
            self?.saveToStorage()
        }
    }

    /// 结束 Session 映射
    ///
    /// 当 AI CLI session 结束或终端关闭时调用。
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
        terminalToProvider.removeValue(forKey: terminalId)

        // 清理持久化映射
        tabToSession.removeValue(forKey: tabId)
        tabToProvider.removeValue(forKey: tabId)

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

    /// 根据 terminalId 查找 providerId
    func getProviderId(for terminalId: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return terminalToProvider[terminalId]
    }

    /// 根据 tabId 获取 sessionId（用于恢复）
    func getSessionIdForTab(_ tabId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession[tabId]
    }

    /// 根据 tabId 获取 providerId（用于恢复）
    func getProviderIdForTab(_ tabId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tabToProvider[tabId]
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
            let state = try JSONDecoder().decode(AICliPluginState.self, from: data)
            lock.lock()
            tabToSession = state.sessions
            tabToProvider = state.providers
            lock.unlock()
        } catch {
            // 解析失败，使用空数据
        }
    }

    private func saveToStorage() {
        lock.lock()
        let state = AICliPluginState(sessions: tabToSession, providers: tabToProvider)
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
