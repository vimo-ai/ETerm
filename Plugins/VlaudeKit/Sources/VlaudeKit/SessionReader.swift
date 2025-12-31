//
//  SessionReader.swift
//  VlaudeKit
//
//  Swift wrapper for claude-session-db FFI (统一入口)
//  Provides Claude session file reading capabilities
//

import Foundation
import SharedDbFFI

// MARK: - Data Types

/// Project information
struct ProjectInfo: Codable {
    let path: String
    let encodedName: String
    let name: String
    let sessionCount: Int
    let lastActive: UInt64?

    enum CodingKeys: String, CodingKey {
        case path
        case encodedName = "encoded_name"
        case name
        case sessionCount = "session_count"
        case lastActive = "last_active"
    }
}

/// Session metadata
struct SessionMeta: Codable {
    let id: String
    let projectPath: String
    let projectName: String?
    let encodedDirName: String?
    let sessionPath: String?
    let lastModified: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case projectPath = "project_path"
        case projectName = "project_name"
        case encodedDirName = "encoded_dir_name"
        case sessionPath = "session_path"
        case lastModified = "last_modified"
    }
}

/// Messages result with pagination info
struct MessagesResult {
    let messages: [RawMessage]
    let total: Int
    let hasMore: Bool
}

/// Raw message from session file
struct RawMessage: Codable {
    let uuid: String
    let sessionId: String
    let messageType: Int  // 0 = User, 1 = Assistant
    let content: String
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case sessionId = "session_id"
        case messageType = "message_type"
        case content
        case timestamp
    }

    // Computed property for compatibility
    var type: String? {
        messageType == 0 ? "user" : "assistant"
    }

    var message: MessageContent? {
        MessageContent(role: messageType == 0 ? "user" : "assistant", content: AnyCodable(content))
    }

    struct MessageContent: Codable {
        let role: String?
        let content: AnyCodable?
    }
}

/// Indexable session data (for writing to SharedDb)
struct IndexableSession {
    let sessionId: String
    let projectPath: String
    let projectName: String
    let messages: [IndexableMessage]
}

/// Message format for indexing
struct IndexableMessage {
    let uuid: String
    let role: String
    let content: String
    let timestamp: Int64
    let sequence: Int64
}

/// Helper for decoding any JSON value
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - SessionReader

/// Swift wrapper for claude-session-db FFI (统一入口)
final class SessionReader {
    private var projectsPath: String?

    // MARK: - Lifecycle

    init() {
        self.projectsPath = nil
    }

    init(projectsPath: String) {
        self.projectsPath = projectsPath
    }

    // MARK: - Project Operations

    /// List all projects
    func listProjects(limit: UInt32 = 0) -> [ProjectInfo]? {
        var arrayPtr: UnsafeMutablePointer<ProjectInfoArray>?

        let err: SessionDbError
        if let path = projectsPath {
            err = path.withCString { cpath in
                session_db_list_file_projects(cpath, limit, &arrayPtr)
            }
        } else {
            err = session_db_list_file_projects(nil, limit, &arrayPtr)
        }

        guard err == Success, let array = arrayPtr else {
            return nil
        }
        defer { session_db_free_project_list(array) }

        var results: [ProjectInfo] = []
        if array.pointee.len > 0, let data = array.pointee.data {
            for i in 0..<Int(array.pointee.len) {
                let p = data[i]
                guard let encodedNamePtr = p.encoded_name,
                      let pathPtr = p.path,
                      let namePtr = p.name else {
                    continue
                }
                results.append(ProjectInfo(
                    path: String(cString: pathPtr),
                    encodedName: String(cString: encodedNamePtr),
                    name: String(cString: namePtr),
                    sessionCount: Int(p.session_count),
                    lastActive: p.last_active > 0 ? p.last_active : nil
                ))
            }
        }
        return results
    }

    // MARK: - Session Operations

    /// List sessions for a project
    func listSessions(projectPath: String? = nil) -> [SessionMeta]? {
        var arrayPtr: UnsafeMutablePointer<SessionMetaArray>?

        let err: SessionDbError
        if let path = self.projectsPath {
            if let projPath = projectPath {
                err = path.withCString { cpath in
                    projPath.withCString { cproj in
                        session_db_list_session_metas(cpath, cproj, &arrayPtr)
                    }
                }
            } else {
                err = path.withCString { cpath in
                    session_db_list_session_metas(cpath, nil, &arrayPtr)
                }
            }
        } else {
            if let projPath = projectPath {
                err = projPath.withCString { cproj in
                    session_db_list_session_metas(nil, cproj, &arrayPtr)
                }
            } else {
                err = session_db_list_session_metas(nil, nil, &arrayPtr)
            }
        }

        guard err == Success, let array = arrayPtr else {
            return nil
        }
        defer { session_db_free_session_meta_list(array) }

        var results: [SessionMeta] = []
        if array.pointee.len > 0, let data = array.pointee.data {
            for i in 0..<Int(array.pointee.len) {
                let s = data[i]
                guard let idPtr = s.id,
                      let projectPathPtr = s.project_path else {
                    continue
                }
                results.append(SessionMeta(
                    id: String(cString: idPtr),
                    projectPath: String(cString: projectPathPtr),
                    projectName: s.project_name != nil ? String(cString: s.project_name) : nil,
                    encodedDirName: s.encoded_dir_name != nil ? String(cString: s.encoded_dir_name) : nil,
                    sessionPath: s.session_path != nil ? String(cString: s.session_path) : nil,
                    lastModified: s.file_mtime >= 0 ? s.file_mtime : nil
                ))
            }
        }
        return results
    }

    /// Find the latest session for a project
    func findLatestSession(projectPath: String, withinSeconds: UInt64 = 0) -> SessionMeta? {
        var sessionPtr: UnsafeMutablePointer<SessionMetaC>?

        let err: SessionDbError
        if let path = self.projectsPath {
            err = path.withCString { cpath in
                projectPath.withCString { cproj in
                    session_db_find_latest_session(cpath, cproj, withinSeconds, &sessionPtr)
                }
            }
        } else {
            err = projectPath.withCString { cproj in
                session_db_find_latest_session(nil, cproj, withinSeconds, &sessionPtr)
            }
        }

        guard err == Success, let session = sessionPtr else {
            return nil
        }
        defer { session_db_free_session_meta(session) }

        let s = session.pointee
        guard let idPtr = s.id,
              let projectPathPtr = s.project_path else {
            return nil
        }

        return SessionMeta(
            id: String(cString: idPtr),
            projectPath: String(cString: projectPathPtr),
            projectName: s.project_name != nil ? String(cString: s.project_name) : nil,
            encodedDirName: s.encoded_dir_name != nil ? String(cString: s.encoded_dir_name) : nil,
            sessionPath: s.session_path != nil ? String(cString: s.session_path) : nil,
            lastModified: s.file_mtime >= 0 ? s.file_mtime : nil
        )
    }

    // MARK: - Message Operations

    /// Read session messages with pagination
    func readMessages(
        sessionPath: String,
        limit: UInt32 = 50,
        offset: UInt32 = 0,
        orderAsc: Bool = true
    ) -> MessagesResult? {
        var resultPtr: UnsafeMutablePointer<MessagesResultC>?

        let err = sessionPath.withCString { cpath in
            session_db_read_session_messages(cpath, UInt(limit), UInt(offset), orderAsc, &resultPtr)
        }

        guard err == Success, let result = resultPtr else {
            return nil
        }
        defer { session_db_free_messages_result(result) }

        var messages: [RawMessage] = []
        let r = result.pointee
        if r.message_count > 0, let data = r.messages {
            for i in 0..<Int(r.message_count) {
                let m = data[i]
                guard let uuidPtr = m.uuid,
                      let sessionIdPtr = m.session_id,
                      let contentPtr = m.content else {
                    continue
                }
                messages.append(RawMessage(
                    uuid: String(cString: uuidPtr),
                    sessionId: String(cString: sessionIdPtr),
                    messageType: Int(m.message_type),
                    content: String(cString: contentPtr),
                    timestamp: m.timestamp != nil ? String(cString: m.timestamp) : nil
                ))
            }
        }

        return MessagesResult(
            messages: messages,
            total: Int(r.total),
            hasMore: r.has_more
        )
    }

    /// Read messages and return raw JSON string (for forwarding to server)
    func readMessagesRaw(
        sessionPath: String,
        limit: UInt32 = 50,
        offset: UInt32 = 0,
        orderAsc: Bool = true
    ) -> String? {
        guard let result = readMessages(sessionPath: sessionPath, limit: limit, offset: offset, orderAsc: orderAsc) else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(result.messages) else {
            return nil
        }

        // Wrap in MessagesResult format
        let json: [String: Any] = [
            "messages": (try? JSONSerialization.jsonObject(with: data)) ?? [],
            "total": result.total,
            "has_more": result.hasMore
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: json) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    // MARK: - Path Utilities

    /// Encode project path to Claude directory name
    static func encodePath(_ path: String) -> String? {
        let cstr = path.withCString { session_db_encode_path($0) }
        guard let cstr = cstr else { return nil }
        defer { session_db_free_string(cstr) }
        return String(cString: cstr)
    }

    /// Decode Claude directory name to project path
    static func decodePath(_ encoded: String) -> String? {
        let cstr = encoded.withCString { session_db_decode_path($0) }
        guard let cstr = cstr else { return nil }
        defer { session_db_free_string(cstr) }
        return String(cString: cstr)
    }

    /// Get library version
    static var version: String {
        "1.0.0"  // TODO: Add version FFI if needed
    }

    // MARK: - Index Operations

    /// Parse session for indexing to SharedDb
    func parseSessionForIndex(jsonlPath: String) -> IndexableSession? {
        let result = jsonlPath.withCString { path in
            session_db_parse_jsonl(path)
        }

        guard result.error == Success else {
            print("[SessionReader] Parse error: \(result.error)")
            return nil
        }

        guard let sessionPtr = result.session else {
            return nil
        }
        defer { session_db_free_parse_result(sessionPtr) }

        let session = sessionPtr.pointee

        guard let sessionIdPtr = session.session_id,
              let projectPathPtr = session.project_path,
              let projectNamePtr = session.project_name else {
            return nil
        }

        var messages: [IndexableMessage] = []
        if session.messages.len > 0, let data = session.messages.data {
            for i in 0..<Int(session.messages.len) {
                let msg = data[i]
                guard let uuidPtr = msg.uuid,
                      let rolePtr = msg.role,
                      let contentPtr = msg.content else {
                    continue
                }
                messages.append(IndexableMessage(
                    uuid: String(cString: uuidPtr),
                    role: String(cString: rolePtr),
                    content: String(cString: contentPtr),
                    timestamp: msg.timestamp,
                    sequence: msg.sequence
                ))
            }
        }

        return IndexableSession(
            sessionId: String(cString: sessionIdPtr),
            projectPath: String(cString: projectPathPtr),
            projectName: String(cString: projectNamePtr),
            messages: messages
        )
    }
}
