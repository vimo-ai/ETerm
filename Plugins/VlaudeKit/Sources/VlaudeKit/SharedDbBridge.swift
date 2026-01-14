//
//  SharedDbBridge.swift
//  VlaudeKit
//
//  Swift wrapper for claude-session-db FFI
//  Provides cached session data access via shared database
//

import Foundation
import SharedDbFFI
import ETermKit

// MARK: - Error Types

enum SharedDbError: Error {
    case nullPointer
    case invalidUtf8
    case databaseError
    case coordinationError
    case permissionDenied
    case unknown(Int32)

    static func from(_ code: SessionDbError) -> SharedDbError? {
        switch code {
        case Success: return nil
        case NullPointer: return .nullPointer
        case InvalidUtf8: return .invalidUtf8
        case DatabaseError: return .databaseError
        case CoordinationError: return .coordinationError
        case PermissionDenied: return .permissionDenied
        default: return .unknown(Int32(code.rawValue))
        }
    }
}

// MARK: - Writer Role

enum WriterRole {
    case writer
    case reader

    init(rawValue: Int32) {
        self = rawValue == 0 ? .writer : .reader
    }
}

// MARK: - Writer Health

enum WriterHealth {
    case alive     // 心跳正常
    case timeout   // 心跳超时
    case released  // 已释放（没有 Writer）

    init(rawValue: Int32) {
        switch rawValue {
        case 0: self = .alive
        case 1: self = .timeout
        case 2: self = .released
        default: self = .released
        }
    }
}

// MARK: - Writer Type

enum WriterTypeValue: Int32 {
    case memexDaemon = 0
    case vlaudeDaemon = 1
    case memexKit = 2
    case vlaudeKit = 3
}

// MARK: - Data Types

struct SharedProject {
    let id: Int64
    let name: String
    let path: String
    let source: String
    let createdAt: Int64
    let updatedAt: Int64
}

struct SharedSession {
    let id: Int64
    let sessionId: String
    let projectId: Int64
    let messageCount: Int64
    let lastMessageAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64
}

struct SharedMessage {
    let id: Int64
    let sessionId: String
    let uuid: String
    let role: String  // "human" or "assistant"
    let content: String
    let timestamp: Int64
    let sequence: Int64
}

/// 用于插入消息的输入结构体
struct MessageInput {
    let uuid: String
    let role: String  // "human" or "assistant"
    let content: String
    let timestamp: Int64
    let sequence: Int64

    var roleValue: Int32 {
        role == "human" ? 0 : 1
    }
}

struct SharedSearchResult {
    let messageId: Int64
    let sessionId: String
    let projectId: Int64
    let projectName: String
    let role: String
    let content: String
    let snippet: String
    let score: Double
    let timestamp: Int64?
}

struct SharedStats {
    let projectCount: Int64
    let sessionCount: Int64
    let messageCount: Int64
}

// MARK: - Approval Status

/// 权限审批状态
/// 值需要与 ApprovalStatusC 枚举一致
enum ApprovalStatus: Int32 {
    case pending = 0
    case approved = 1
    case rejected = 2
    case timeout = 3

    /// 转换为 C 枚举
    var toC: ApprovalStatusC {
        ApprovalStatusC(rawValue: UInt32(self.rawValue))
    }

    /// 字符串表示
    var stringValue: String {
        switch self {
        case .pending: return "pending"
        case .approved: return "approved"
        case .rejected: return "rejected"
        case .timeout: return "timeout"
        }
    }
}

// MARK: - SharedDbBridge

/// Swift bridge for claude-session-db
/// Provides cached session data access via shared database
/// Thread-safe: all FFI calls are serialized on a private queue
final class SharedDbBridge {
    private var handle: OpaquePointer?
    private(set) var role: WriterRole = .reader
    private var heartbeatTimer: DispatchSourceTimer?

    /// 串行队列，确保所有 FFI 调用线程安全
    private let queue = DispatchQueue(label: "com.eterm.SharedDbBridge", qos: .userInitiated)

    // MARK: - Lifecycle

    /// Connect to shared database (path managed by Rust layer)
    init() throws {
        var handlePtr: OpaquePointer?
        // 传 nil 让 Rust 使用默认路径
        let error = session_db_connect(nil, &handlePtr)

        if let err = SharedDbError.from(error) {
            throw err
        }

        self.handle = handlePtr
    }

    deinit {
        stopHeartbeat()
        // 释放 Writer 角色
        if role == .writer, let handle = handle {
            session_db_release_writer(handle)
        }
        if let handle = handle {
            session_db_close(handle)
        }
    }

    // MARK: - Safe String Conversion

    /// 安全地将 C 字符串转换为 Swift String
    private func safeString(_ ptr: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let ptr = ptr else {
            throw SharedDbError.nullPointer
        }
        guard let str = String(validatingUTF8: ptr) else {
            throw SharedDbError.invalidUtf8
        }
        return str
    }

    // MARK: - Writer Coordination

    /// Register as writer (thread-safe)
    /// - Returns: Assigned role (writer or reader)
    func register() throws -> WriterRole {
        let assignedRole: WriterRole = try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var roleValue: Int32 = 1  // Default to reader
            let error = session_db_register_writer(handle, WriterTypeValue.vlaudeKit.rawValue, &roleValue)

            if let err = SharedDbError.from(error) {
                throw err
            }

            let newRole = WriterRole(rawValue: roleValue)
            role = newRole
            return newRole
        }

        // Writer 或 Reader 都启动定时器：
        // - Writer: 发送心跳
        // - Reader: 检查 Writer 是否超时，尝试接管
        startHeartbeat()

        return assignedRole
    }

    /// Release writer role (thread-safe)
    func release() throws {
        stopHeartbeat()

        try queue.sync {
            guard let handle = handle else { return }

            let error = session_db_release_writer(handle)
            if let err = SharedDbError.from(error) {
                throw err
            }

            role = .reader
        }
    }

    /// Send heartbeat (thread-safe)
    func heartbeat() throws {
        var errorToThrow: SharedDbError?

        queue.sync {
            guard let handle = handle, role == .writer else { return }

            let error = session_db_heartbeat(handle)
            if let err = SharedDbError.from(error) {
                role = .reader
                errorToThrow = err
            }
        }

        if let err = errorToThrow {
            throw err
        }
    }

    /// Check writer health status (thread-safe, Reader calls this)
    func checkWriterHealth() throws -> WriterHealth {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var healthValue: Int32 = 0
            let error = session_db_check_writer_health(handle, &healthValue)

            if let err = SharedDbError.from(error) {
                throw err
            }

            return WriterHealth(rawValue: healthValue)
        }
    }

    /// Try to take over as Writer (thread-safe, Reader calls this when Writer times out)
    /// - Returns: true if takeover succeeded
    func tryTakeover() throws -> Bool {
        let taken: Bool = try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var takenValue: Int32 = 0
            let error = session_db_try_takeover(handle, &takenValue)

            if let err = SharedDbError.from(error) {
                throw err
            }

            if takenValue == 1 {
                role = .writer
                return true
            }
            return false
        }

        if taken {
            startHeartbeat()
        }

        return taken
    }

    private func startHeartbeat() {
        stopHeartbeat()

        // 使用全局队列，避免与 queue.sync 死锁
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            if self.role == .writer {
                // Writer: 发送心跳
                try? self.heartbeat()
            } else {
                // Reader: 检查 Writer 是否超时，尝试接管
                if let health = try? self.checkWriterHealth(),
                   health == .timeout || health == .released {
                    _ = try? self.tryTakeover()
                }
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Stats

    /// Get database statistics (thread-safe)
    func getStats() throws -> SharedStats {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var projects: Int64 = 0
            var sessions: Int64 = 0
            var messages: Int64 = 0

            let error = session_db_get_stats(handle, &projects, &sessions, &messages)
            if let err = SharedDbError.from(error) {
                throw err
            }

            return SharedStats(
                projectCount: projects,
                sessionCount: sessions,
                messageCount: messages
            )
        }
    }

    // MARK: - Project Operations

    /// List all projects (thread-safe)
    func listProjects() throws -> [SharedProject] {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var arrayPtr: UnsafeMutablePointer<ProjectArray>?
            let error = session_db_list_projects(handle, &arrayPtr)

            if let err = SharedDbError.from(error) {
                throw err
            }

            guard let array = arrayPtr?.pointee else {
                return []
            }

            defer { session_db_free_projects(arrayPtr) }

            var result: [SharedProject] = []
            for i in 0..<Int(array.len) {
                let p = array.data[i]
                result.append(SharedProject(
                    id: p.id,
                    name: try safeString(p.name),
                    path: try safeString(p.path),
                    source: try safeString(p.source),
                    createdAt: p.created_at,
                    updatedAt: p.updated_at
                ))
            }

            return result
        }
    }

    // MARK: - Session Operations

    /// List sessions for a project (thread-safe)
    func listSessions(projectId: Int64) throws -> [SharedSession] {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var arrayPtr: UnsafeMutablePointer<SessionArray>?
            let error = session_db_list_sessions(handle, projectId, &arrayPtr)

            if let err = SharedDbError.from(error) {
                throw err
            }

            guard let array = arrayPtr?.pointee else {
                return []
            }

            defer { session_db_free_sessions(arrayPtr) }

            var result: [SharedSession] = []
            for i in 0..<Int(array.len) {
                let s = array.data[i]
                result.append(SharedSession(
                    id: s.id,
                    sessionId: try safeString(s.session_id),
                    projectId: s.project_id,
                    messageCount: s.message_count,
                    lastMessageAt: s.last_message_at >= 0 ? s.last_message_at : nil,
                    createdAt: s.created_at,
                    updatedAt: s.updated_at
                ))
            }

            return result
        }
    }

    // MARK: - Message Operations

    /// List messages for a session (thread-safe)
    func listMessages(sessionId: String, limit: Int = 50, offset: Int = 0) throws -> [SharedMessage] {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var arrayPtr: UnsafeMutablePointer<MessageArray>?
            let error = sessionId.withCString { cstr in
                session_db_list_messages(handle, cstr, UInt(limit), UInt(offset), &arrayPtr)
            }

            if let err = SharedDbError.from(error) {
                throw err
            }

            guard let array = arrayPtr?.pointee else {
                return []
            }

            defer { session_db_free_messages(arrayPtr) }

            var result: [SharedMessage] = []
            for i in 0..<Int(array.len) {
                let m = array.data[i]
                let roleStr = m.role == 0 ? "human" : "assistant"
                result.append(SharedMessage(
                    id: m.id,
                    sessionId: try safeString(m.session_id),
                    uuid: try safeString(m.uuid),
                    role: roleStr,
                    content: try safeString(m.content),
                    timestamp: m.timestamp,
                    sequence: m.sequence
                ))
            }

            return result
        }
    }

    // MARK: - Search Operations

    /// Full-text search (thread-safe)
    func search(query: String, limit: Int = 20) throws -> [SharedSearchResult] {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var arrayPtr: UnsafeMutablePointer<SearchResultArray>?
            let error = query.withCString { cstr in
                session_db_search_fts(handle, cstr, UInt(limit), &arrayPtr)
            }

            if let err = SharedDbError.from(error) {
                throw err
            }

            guard let array = arrayPtr?.pointee else {
                return []
            }

            defer { session_db_free_search_results(arrayPtr) }

            var result: [SharedSearchResult] = []
            for i in 0..<Int(array.len) {
                let r = array.data[i]
                result.append(SharedSearchResult(
                    messageId: r.message_id,
                    sessionId: try safeString(r.session_id),
                    projectId: r.project_id,
                    projectName: try safeString(r.project_name),
                    role: try safeString(r.role),
                    content: try safeString(r.content),
                    snippet: try safeString(r.snippet),
                    score: r.score,
                    timestamp: r.timestamp >= 0 ? r.timestamp : nil
                ))
            }

            return result
        }
    }

    /// Full-text search with project filter (thread-safe)
    func search(query: String, projectId: Int64, limit: Int = 20) throws -> [SharedSearchResult] {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var arrayPtr: UnsafeMutablePointer<SearchResultArray>?
            let error = query.withCString { cstr in
                session_db_search_fts_with_project(handle, cstr, UInt(limit), projectId, &arrayPtr)
            }

            if let err = SharedDbError.from(error) {
                throw err
            }

            guard let array = arrayPtr?.pointee else {
                return []
            }

            defer { session_db_free_search_results(arrayPtr) }

            var result: [SharedSearchResult] = []
            for i in 0..<Int(array.len) {
                let r = array.data[i]
                result.append(SharedSearchResult(
                    messageId: r.message_id,
                    sessionId: try safeString(r.session_id),
                    projectId: r.project_id,
                    projectName: try safeString(r.project_name),
                    role: try safeString(r.role),
                    content: try safeString(r.content),
                    snippet: try safeString(r.snippet),
                    score: r.score,
                    timestamp: r.timestamp >= 0 ? r.timestamp : nil
                ))
            }

            return result
        }
    }

    // MARK: - Write Operations

    /// 辅助方法：安全地将多个 String 转为 C 字符串指针数组
    private func withCStrings<R>(
        _ strings: [String],
        body: ([UnsafePointer<CChar>]) throws -> R
    ) rethrows -> R {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        cStrings.reserveCapacity(strings.count)

        defer {
            cStrings.forEach { free($0) }
        }

        for str in strings {
            guard let ptr = strdup(str) else {
                // strdup 失败时返回空字符串指针
                cStrings.append(strdup("")!)
                continue
            }
            cStrings.append(ptr)
        }

        return try body(cStrings.map { UnsafePointer($0) })
    }

    /// Upsert a project (thread-safe)
    /// - Parameters:
    ///   - path: Project path
    ///   - name: Project name
    ///   - source: Project source (e.g., "claude-code")
    /// - Returns: Project ID
    func upsertProject(path: String, name: String, source: String) throws -> Int64 {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var projectId: Int64 = 0
            let error = name.withCString { namePtr in
                path.withCString { pathPtr in
                    source.withCString { sourcePtr in
                        session_db_upsert_project(handle, namePtr, pathPtr, sourcePtr, &projectId)
                    }
                }
            }

            if let err = SharedDbError.from(error) {
                throw err
            }

            return projectId
        }
    }

    /// Upsert a session (thread-safe)
    /// - Parameters:
    ///   - sessionId: Session ID string
    ///   - projectId: Associated project ID
    func upsertSession(sessionId: String, projectId: Int64) throws {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            let error = sessionId.withCString { cstr in
                session_db_upsert_session(handle, cstr, projectId)
            }

            if let err = SharedDbError.from(error) {
                throw err
            }
        }
    }

    /// Insert messages in batch (thread-safe)
    /// - Parameters:
    ///   - sessionId: Session ID string
    ///   - messages: Array of messages to insert
    /// - Returns: Number of messages actually inserted
    func insertMessages(sessionId: String, messages: [MessageInput]) throws -> Int {
        guard !messages.isEmpty else { return 0 }

        return try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var inserted: UInt = 0

            let error = withCStrings(messages.map(\.uuid)) { uuidPtrs in
                withCStrings(messages.map(\.content)) { contentPtrs in
                    // 构建 MessageInputC 数组
                    let cMessages: [MessageInputC] = messages.enumerated().map { idx, msg in
                        MessageInputC(
                            uuid: uuidPtrs[idx],
                            role: msg.roleValue,
                            content: contentPtrs[idx],
                            timestamp: msg.timestamp,
                            sequence: msg.sequence
                        )
                    }

                    return sessionId.withCString { sessionCstr in
                        cMessages.withUnsafeBufferPointer { msgBuf in
                            session_db_insert_messages(
                                handle,
                                sessionCstr,
                                msgBuf.baseAddress,
                                UInt(messages.count),
                                &inserted
                            )
                        }
                    }
                }
            }

            if let err = SharedDbError.from(error) {
                throw err
            }

            return Int(inserted)
        }
    }

    // MARK: - Approval Operations

    /// Update approval status by tool call ID
    /// - Parameters:
    ///   - toolCallId: Tool call ID
    ///   - status: New approval status
    ///   - resolvedAt: Timestamp when resolved (0 for pending)
    /// - Returns: Number of rows updated
    func updateApprovalStatusByToolCallId(
        toolCallId: String,
        status: ApprovalStatus,
        resolvedAt: Int64
    ) throws -> Int {
        try queue.sync {
            guard let handle = handle else { throw SharedDbError.nullPointer }

            var updated: UInt = 0
            let error = toolCallId.withCString { cstr in
                session_db_update_approval_status_by_tool_call_id(
                    handle,
                    cstr,
                    status.toC,
                    resolvedAt,
                    &updated
                )
            }

            if let err = SharedDbError.from(error) {
                throw err
            }

            return Int(updated)
        }
    }
}
