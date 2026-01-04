//
//  SessionReader.swift
//  MemexKit
//
//  Swift wrapper for claude-session-db FFI (统一入口)
//  Provides Claude session file parsing capabilities
//

import Foundation
import SharedDbFFI

// MARK: - Data Types

/// Indexable session data (for writing to SharedDb)
/// Contains correctly resolved project path (from cwd)
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

// MARK: - SessionReader

/// Swift wrapper for claude-session-db FFI (统一入口)
final class SessionReader {

    // MARK: - Lifecycle

    init() {}

    // MARK: - Index Operations

    /// Parse session for indexing to SharedDb
    /// Correctly reads cwd to determine the real project path (fixes Chinese path issues)
    /// - Parameter jsonlPath: Full path to JSONL session file
    /// - Returns: IndexableSession if successful, nil if file is empty or parsing failed
    func parseSessionForIndex(jsonlPath: String) -> IndexableSession? {
        let result = jsonlPath.withCString { path in
            session_db_parse_jsonl(path)
        }

        // Check for errors
        guard result.error == Success else {
            logWarn("[SessionReader] Parse error: \(result.error)")
            return nil
        }

        // Check for empty result (valid but no messages)
        guard let sessionPtr = result.session else {
            return nil
        }
        defer { session_db_free_parse_result(sessionPtr) }

        let session = sessionPtr.pointee

        // Convert session_id
        guard let sessionIdPtr = session.session_id else { return nil }
        let sessionId = String(cString: sessionIdPtr)

        // Convert project_path
        guard let projectPathPtr = session.project_path else { return nil }
        let projectPath = String(cString: projectPathPtr)

        // Convert project_name
        guard let projectNamePtr = session.project_name else { return nil }
        let projectName = String(cString: projectNamePtr)

        // Convert messages
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
            sessionId: sessionId,
            projectPath: projectPath,
            projectName: projectName,
            messages: messages
        )
    }
}
