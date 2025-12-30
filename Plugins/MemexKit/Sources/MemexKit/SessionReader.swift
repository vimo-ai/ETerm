//
//  SessionReader.swift
//  MemexKit
//
//  Swift wrapper for session-reader-ffi
//  Provides Claude session file parsing capabilities
//

import Foundation
import SessionReaderFFI

// MARK: - Data Types

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

// MARK: - SessionReader

/// Swift wrapper for session-reader-ffi (minimal version for MemexKit)
final class SessionReader {
    private var handle: OpaquePointer?

    // MARK: - Lifecycle

    init() {
        handle = sr_create()
        if handle == nil {
            print("[SessionReader] Warning: Failed to create reader")
        }
    }

    deinit {
        if let handle = handle {
            sr_destroy(handle)
        }
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
