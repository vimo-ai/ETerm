//
//  SharedDbBridge.swift
//  VlaudeKit
//
//  Swift wrapper for ai-cli-session-db FFI
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

    static func from(_ code: FfiError) -> SharedDbError? {
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

// MARK: - SharedDbBridge

/// Swift bridge for ai-cli-session-db
/// Provides cached session data access via shared database (read-only)
/// All write operations should go through AgentClient
/// Thread-safe: all FFI calls are serialized on a private queue
final class SharedDbBridge {
    private var handle: OpaquePointer?

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

}
