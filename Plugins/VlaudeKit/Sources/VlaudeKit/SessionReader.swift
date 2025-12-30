//
//  SessionReader.swift
//  VlaudeKit
//
//  Swift wrapper for session-reader-ffi
//  Provides Claude session file reading capabilities
//

import Foundation
import SessionReaderFFI

// MARK: - Data Types

/// Project information
struct ProjectInfo: Codable {
    let path: String
    let encodedName: String
    let name: String?
    let sessionCount: Int?
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
struct MessagesResult: Codable {
    let messages: [RawMessage]
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case total
        case hasMore = "has_more"
    }
}

/// Raw message from session file
struct RawMessage: Codable {
    let type: String?
    let message: MessageContent?
    let timestamp: String?

    struct MessageContent: Codable {
        let role: String?
        let content: AnyCodable?
    }
}

/// Indexable session data (for writing to SharedDb)
/// Contains correctly resolved project path (from cwd)
struct IndexableSession: Codable {
    let sessionId: String
    let projectPath: String
    let projectName: String
    let messages: [IndexableMessage]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case messages
    }
}

/// Message format for indexing
struct IndexableMessage: Codable {
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

/// Swift wrapper for session-reader-ffi
final class SessionReader {
    private var handle: OpaquePointer?

    // MARK: - Lifecycle

    init() {
        handle = sr_create()
        if handle == nil {
            print("[SessionReader] Warning: Failed to create reader")
        }
    }

    init(projectsPath: String) {
        handle = projectsPath.withCString { cstr in
            sr_create_with_path(cstr)
        }
        if handle == nil {
            print("[SessionReader] Warning: Failed to create reader with path: \(projectsPath)")
        }
    }

    deinit {
        if let handle = handle {
            sr_destroy(handle)
        }
    }

    // MARK: - Project Operations

    /// List all projects
    /// - Parameter limit: Maximum number of projects (0 = unlimited)
    /// - Returns: Array of ProjectInfo, or nil on failure
    func listProjects(limit: UInt32 = 0) -> [ProjectInfo]? {
        guard let handle = handle else { return nil }

        guard let cstr = sr_list_projects(handle, limit) else {
            return nil
        }
        defer { sr_free_string(cstr) }

        let json = String(cString: cstr)
        return decodeJSON(json)
    }

    // MARK: - Session Operations

    /// List sessions for a project
    /// - Parameter projectPath: Project path (nil = all projects)
    /// - Returns: Array of SessionMeta, or nil on failure
    func listSessions(projectPath: String? = nil) -> [SessionMeta]? {
        guard let handle = handle else { return nil }

        let cstr: UnsafeMutablePointer<CChar>?
        if let path = projectPath {
            cstr = path.withCString { sr_list_sessions(handle, $0) }
        } else {
            cstr = sr_list_sessions(handle, nil)
        }

        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }

        let json = String(cString: cstr)
        return decodeJSON(json)
    }

    /// Find the latest session for a project
    /// - Parameters:
    ///   - projectPath: Project path
    ///   - withinSeconds: Time range in seconds (0 = unlimited)
    /// - Returns: SessionMeta if found, nil otherwise
    func findLatestSession(projectPath: String, withinSeconds: UInt64 = 0) -> SessionMeta? {
        guard let handle = handle else { return nil }

        let cstr = projectPath.withCString { path in
            sr_find_latest_session(handle, path, withinSeconds)
        }

        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }

        let json = String(cString: cstr)

        // Handle null response
        if json == "null" {
            return nil
        }

        return decodeJSON(json)
    }

    // MARK: - Message Operations

    /// Read session messages with pagination
    /// - Parameters:
    ///   - sessionPath: Full path to session file
    ///   - limit: Maximum number of messages
    ///   - offset: Offset for pagination
    ///   - orderAsc: True for ascending, false for descending
    /// - Returns: MessagesResult or nil on failure
    func readMessages(
        sessionPath: String,
        limit: UInt32 = 50,
        offset: UInt32 = 0,
        orderAsc: Bool = true
    ) -> MessagesResult? {
        guard let handle = handle else { return nil }

        let cstr = sessionPath.withCString { path in
            sr_read_messages(handle, path, limit, offset, orderAsc)
        }

        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }

        let json = String(cString: cstr)
        return decodeJSON(json)
    }

    /// Read messages and return raw JSON string (for forwarding to server)
    func readMessagesRaw(
        sessionPath: String,
        limit: UInt32 = 50,
        offset: UInt32 = 0,
        orderAsc: Bool = true
    ) -> String? {
        guard let handle = handle else { return nil }

        let cstr = sessionPath.withCString { path in
            sr_read_messages(handle, path, limit, offset, orderAsc)
        }

        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }

        return String(cString: cstr)
    }

    // MARK: - Path Utilities

    /// Encode project path to Claude directory name
    static func encodePath(_ path: String) -> String? {
        let cstr = path.withCString { sr_encode_path($0) }
        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }
        return String(cString: cstr)
    }

    /// Decode Claude directory name to project path
    static func decodePath(_ encoded: String) -> String? {
        let cstr = encoded.withCString { sr_decode_path($0) }
        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }
        return String(cString: cstr)
    }

    /// Get library version
    static var version: String {
        guard let cstr = sr_version() else { return "unknown" }
        return String(cString: cstr)
    }

    // MARK: - Index Operations

    /// Parse session for indexing to SharedDb
    /// Correctly reads cwd to determine the real project path (fixes Chinese path issues)
    /// - Parameter jsonlPath: Full path to JSONL session file
    /// - Returns: IndexableSession if successful, nil if file is empty or parsing failed
    func parseSessionForIndex(jsonlPath: String) -> IndexableSession? {
        guard let handle = handle else { return nil }

        let cstr = jsonlPath.withCString { path in
            sr_parse_session_for_index(handle, path)
        }

        guard let cstr = cstr else { return nil }
        defer { sr_free_string(cstr) }

        let json = String(cString: cstr)

        // Handle null response (empty file or no valid messages)
        if json == "null" {
            return nil
        }

        return decodeJSON(json)
    }

    // MARK: - Private Helpers

    private func decodeJSON<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[SessionReader] JSON decode error: \(error)")
            return nil
        }
    }
}
