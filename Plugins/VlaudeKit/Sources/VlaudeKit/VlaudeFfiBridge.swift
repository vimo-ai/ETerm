//
//  VlaudeFfiBridge.swift
//  VlaudeKit
//
//  Swift wrapper for vlaude-ffi data query API
//  Uses SharedDb for fast database queries instead of file scanning
//

import Foundation
import VlaudeFFI

// MARK: - Response Types

/// FFI Project info (from SharedDb)
/// Rust 使用 camelCase 序列化，直接匹配属性名
struct FfiProjectInfo: Codable {
    let id: Int64
    let name: String
    let projectPath: String
    let sessionCount: Int
    let messageCount: Int
    let lastActive: Int64?  // 毫秒时间戳（与 Rust 一致）

    /// Convert to legacy ProjectInfo format (for VlaudeClient compatibility)
    func toProjectInfo() -> ProjectInfo {
        // Extract encoded name from path
        let encodedName = URL(fileURLWithPath: projectPath).lastPathComponent

        return ProjectInfo(
            path: projectPath,
            encodedName: encodedName,
            name: name,
            sessionCount: sessionCount,
            lastActive: lastActive.map { UInt64($0) }  // 直接转换，已经是毫秒时间戳
        )
    }
}

/// FFI Session info (from SharedDb)
/// Note: Rust 使用 camelCase 序列化，所以不需要 CodingKeys 重命名
struct FfiSessionInfo: Codable {
    let sessionId: String
    let projectId: Int64
    let projectPath: String?
    let projectName: String?
    let messageCount: Int64?
    let lastMessageAt: Int64?  // 毫秒时间戳
    let encodedDirName: String?
    let createdAt: Int64  // 毫秒时间戳
    let updatedAt: Int64  // 毫秒时间戳
    // V5: 预览字段（数据库路径暂不支持，预留）
    let lastMessageType: String?
    let lastMessagePreview: String?
    // V6: Session Chain 关系
    let sessionType: String?
    let source: String?
    let childrenCount: Int64?
    let parentSessionId: String?
    let childSessionIds: [String]?

    /// Convert to legacy SessionMeta format (for VlaudeClient compatibility)
    func toSessionMeta() -> SessionMeta {
        // 优先使用 lastMessageAt，否则用 updatedAt
        let lastModified = lastMessageAt ?? updatedAt

        return SessionMeta(
            id: sessionId,
            projectPath: projectPath ?? "",
            projectName: projectName,
            encodedDirName: encodedDirName,
            sessionPath: nil,     // Not available in SharedDb
            lastModified: lastModified,
            messageCount: messageCount,
            lastMessageType: lastMessageType,
            lastMessagePreview: lastMessagePreview,
            lastMessageAt: lastMessageAt,
            sessionType: sessionType,
            source: source,
            childrenCount: childrenCount,
            parentSessionId: parentSessionId,
            childSessionIds: childSessionIds
        )
    }
}

/// FFI Message info (from SharedDb)
struct FfiMessage {
    let id: Int64
    let uuid: String
    let sessionId: String
    let role: String
    let contentText: String
    let timestamp: Int64?
    let contentBlocks: [[String: Any]]?

    /// Convert to legacy RawMessage format (for VlaudeClient compatibility)
    func toRawMessage() -> RawMessage {
        let messageType = role == "user" ? 0 : 1
        let ts = timestamp != nil ? String(timestamp!) : nil

        return RawMessage(
            uuid: uuid,
            sessionId: sessionId,
            messageType: messageType,
            content: contentText,
            timestamp: ts,
            contentBlocks: contentBlocks
        )
    }
}

extension FfiMessage {
    /// Decode from JSON dictionary
    /// 注意：JSONSerialization 返回 NSNumber，需要用 .int64Value 转换
    init?(from dict: [String: Any]) {
        guard let idNum = dict["id"] as? NSNumber,
              let uuid = dict["uuid"] as? String,
              let sessionId = dict["session_id"] as? String,
              let type = dict["type"] as? String,  // FFI 返回 "type" 而不是 "role"
              let contentText = dict["content_text"] as? String else {
            return nil
        }
        self.id = idNum.int64Value
        self.uuid = uuid
        self.sessionId = sessionId
        self.role = type  // 映射到 role 字段
        self.contentText = contentText
        self.timestamp = (dict["timestamp"] as? NSNumber)?.int64Value
        self.contentBlocks = dict["contentBlocks"] as? [[String: Any]]
    }
}

/// FFI Search result (from SharedDb)
struct FfiSearchResult: Codable {
    let messageId: Int64
    let sessionId: String
    let projectPath: String?
    let contentText: String
    let snippet: String?
    let rank: Double?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case projectPath = "project_path"
        case contentText = "content_text"
        case snippet
        case rank
    }
}

/// FFI DB Stats
struct FfiStats: Codable {
    let projectCount: Int
    let sessionCount: Int
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case projectCount = "project_count"
        case sessionCount = "session_count"
        case messageCount = "message_count"
    }
}

// MARK: - VlaudeFfiBridge

/// Swift bridge for vlaude-ffi data query API
final class VlaudeFfiBridge {
    static let shared = VlaudeFfiBridge()

    private let decoder: JSONDecoder

    private init() {
        decoder = JSONDecoder()
    }

    // MARK: - Helper

    /// Call FFI function and parse JSON response
    private func callFfi<T: Decodable>(_ call: () -> UnsafeMutablePointer<CChar>?) -> Result<T, Error> {
        guard let ptr = call() else {
            return .failure(VlaudeFfiError.nullResponse)
        }
        defer { vlaude_free_string(ptr) }

        let jsonString = String(cString: ptr)
        guard let data = jsonString.data(using: .utf8) else {
            return .failure(VlaudeFfiError.invalidUtf8)
        }

        // Check for error response
        if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = errorDict["error"] as? String {
            return .failure(VlaudeFfiError.ffiError(error))
        }

        do {
            let result = try decoder.decode(T.self, from: data)
            return .success(result)
        } catch {
            return .failure(VlaudeFfiError.decodingError(error))
        }
    }

    // MARK: - Public API

    /// List all projects with stats (支持分页)
    func listProjects(limit: UInt32 = 1000, offset: UInt32 = 0) -> [FfiProjectInfo]? {
        struct Response: Codable {
            let projects: [FfiProjectInfo]
        }

        let result: Result<Response, Error> = callFfi {
            vlaude_list_projects(limit, offset)
        }

        switch result {
        case .success(let response):
            return response.projects
        case .failure:
            return nil
        }
    }

    /// List all projects (legacy format for VlaudeClient)
    func listProjectsLegacy(limit: UInt32 = 1000, offset: UInt32 = 0) -> [ProjectInfo]? {
        return listProjects(limit: limit, offset: offset)?.map { $0.toProjectInfo() }
    }

    /// List sessions for a project (支持分页)
    func listSessions(projectPath: String, limit: UInt32 = 1000, offset: UInt32 = 0) -> [FfiSessionInfo]? {
        struct Response: Codable {
            let sessions: [FfiSessionInfo]
        }

        let result: Result<Response, Error> = callFfi {
            projectPath.withCString { path in
                vlaude_list_sessions(path, limit, offset)
            }
        }

        switch result {
        case .success(let response):
            return response.sessions
        case .failure:
            return nil
        }
    }

    /// List sessions for a project (legacy format for VlaudeClient)
    func listSessionsLegacy(projectPath: String, limit: UInt32 = 1000, offset: UInt32 = 0) -> [SessionMeta]? {
        return listSessions(projectPath: projectPath, limit: limit, offset: offset)?.map { $0.toSessionMeta() }
    }

    /// Get messages for a session
    func getMessages(sessionId: String, limit: UInt32 = 50, offset: UInt32 = 0) -> [FfiMessage]? {
        guard let ptr = sessionId.withCString({ sid in
            vlaude_get_messages(sid, limit, offset)
        }) else {
            return nil
        }
        defer { vlaude_free_string(ptr) }

        let jsonString = String(cString: ptr)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messagesArray = json["messages"] as? [[String: Any]] else {
            return nil
        }

        return messagesArray.compactMap { FfiMessage(from: $0) }
    }

    /// Get messages for a session (legacy format for VlaudeClient)
    func getMessagesLegacy(sessionId: String, limit: UInt32 = 50, offset: UInt32 = 0) -> MessagesResult? {
        guard let messages = getMessages(sessionId: sessionId, limit: limit, offset: offset) else {
            return nil
        }

        let rawMessages = messages.map { $0.toRawMessage() }
        let hasMore = messages.count >= Int(limit)

        return MessagesResult(
            messages: rawMessages,
            total: messages.count,  // Note: FFI doesn't return total, this is approximate
            hasMore: hasMore
        )
    }

    /// Get messages by Turn count (turn-based pagination)
    /// 返回原始 JSON dict（JSONL 格式），不经过 FfiMessage 转换
    /// - detail: "summary"（默认，裁剪大 payload）或 "full"（完整数据）
    func getMessagesByTurns(sessionId: String, turnsLimit: UInt32, before: Int? = nil, detail: String = "summary") -> TurnBasedRawResult? {
        let beforeVal: Int64 = before.map { Int64($0) } ?? -1

        guard let ptr = sessionId.withCString({ sid in
            detail.withCString { detailPtr in
                vlaude_get_messages_by_turns(sid, turnsLimit, beforeVal, detailPtr)
            }
        }) else {
            return nil
        }
        defer { vlaude_free_string(ptr) }

        let jsonString = String(cString: ptr)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 检查错误
        if json["error"] != nil { return nil }

        guard let messagesArray = json["messages"] as? [[String: Any]],
              let total = json["total"] as? Int,
              let hasMore = json["hasMore"] as? Bool,
              let openTurn = json["openTurn"] as? Bool else {
            return nil
        }

        let nextCursor = json["nextCursor"] as? Int

        return TurnBasedRawResult(
            messages: messagesArray,
            total: total,
            hasMore: hasMore,
            openTurn: openTurn,
            nextCursor: nextCursor
        )
    }

    /// Search messages
    func search(query: String, limit: UInt32 = 20) -> [FfiSearchResult]? {
        struct Response: Codable {
            let results: [FfiSearchResult]
        }

        let result: Result<Response, Error> = callFfi {
            query.withCString { q in
                vlaude_search(q, limit)
            }
        }

        switch result {
        case .success(let response):
            return response.results
        case .failure:
            return nil
        }
    }

    /// Get database stats
    func getStats() -> FfiStats? {
        let result: Result<FfiStats, Error> = callFfi {
            vlaude_get_stats()
        }

        switch result {
        case .success(let stats):
            return stats
        case .failure:
            return nil
        }
    }

    /// Check if FFI is available (SharedDb initialized)
    var isAvailable: Bool {
        // Try to get stats as a health check
        return getStats() != nil
    }
}

// MARK: - Errors

enum VlaudeFfiError: Error, LocalizedError {
    case nullResponse
    case invalidUtf8
    case ffiError(String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .nullResponse:
            return "FFI returned null"
        case .invalidUtf8:
            return "Invalid UTF-8 response"
        case .ffiError(let msg):
            return "FFI error: \(msg)"
        case .decodingError(let error):
            return "JSON decoding error: \(error.localizedDescription)"
        }
    }
}
