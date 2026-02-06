//
//  SessionReader.swift
//  VlaudeKit
//
//  Swift wrapper for ai-cli-session-db FFI (统一入口)
//  Provides Claude session file reading capabilities
//

import Foundation
import SharedDbFFI
import ETermKit

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
    let messageCount: Int64?
    /// 最后一条消息类型 ("user" / "assistant")
    let lastMessageType: String?
    /// 最后一条消息预览（纯文本，100 字符）
    let lastMessagePreview: String?
    /// 最后一条消息时间戳（毫秒）
    let lastMessageAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case projectPath = "project_path"
        case projectName = "project_name"
        case encodedDirName = "encoded_dir_name"
        case sessionPath = "session_path"
        case lastModified = "last_modified"
        case messageCount = "message_count"
        case lastMessageType = "last_message_type"
        case lastMessagePreview = "last_message_preview"
        case lastMessageAt = "last_message_at"
    }
}

/// Messages result with pagination info
struct MessagesResult {
    let messages: [RawMessage]
    let total: Int
    let hasMore: Bool
}

/// Raw message from session file
struct RawMessage {
    let uuid: String
    let sessionId: String
    let messageType: Int  // 0 = User, 1 = Assistant
    let content: String
    let timestamp: String?
    /// FFI 返回的 contentBlocks（已解析）
    let contentBlocks: [[String: Any]]?

    // V2 Turn Context 字段
    /// JSONL 顶层 requestId（同一 API call 共享，用于 Turn 分组）
    let requestId: String?
    /// message.stop_reason: "end_turn" | "tool_use" | "stop_sequence"
    let stopReason: String?
    /// 主 block 类型: "thinking" | "text" | "tool_use" | "tool_result" | "user_text"
    let eventType: String?
    /// subagent 归属标记
    let agentId: String?

    init(uuid: String, sessionId: String, messageType: Int, content: String, timestamp: String?,
         contentBlocks: [[String: Any]]? = nil,
         requestId: String? = nil, stopReason: String? = nil,
         eventType: String? = nil, agentId: String? = nil) {
        self.uuid = uuid
        self.sessionId = sessionId
        self.messageType = messageType
        self.content = content
        self.timestamp = timestamp
        self.contentBlocks = contentBlocks
        self.requestId = requestId
        self.stopReason = stopReason
        self.eventType = eventType
        self.agentId = agentId
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

// MARK: - Incremental Read

/// 增量读取结果
struct IncrementalReadResult {
    /// 新读取的消息
    let messages: [RawMessage]
    /// 新的文件偏移量（指向最后一条完整行之后）
    let newOffset: Int64
    /// 最后处理的消息 UUID
    let lastUUID: String?
}

// MARK: - SessionReader

/// Swift wrapper for ai-cli-session-db FFI (统一入口)
final class SessionReader {
    private var projectsPath: String?

    // MARK: - Lifecycle

    init() {
        self.projectsPath = nil
    }

    init(projectsPath: String) {
        self.projectsPath = projectsPath
    }

    // MARK: - Incremental Read (纯 Swift，不经 FFI)

    /// 从指定偏移量增量读取 JSONL 消息
    ///
    /// 用于游标协议：从上次读到的位置继续读取新消息。
    /// 只消费完整行（不完整的末尾行丢弃，下次重读）。
    ///
    /// - Parameters:
    ///   - sessionPath: JSONL 文件路径
    ///   - sessionId: 会话 ID
    ///   - fromOffset: 起始偏移量（字节）
    /// - Returns: 增量读取结果，包含新消息和更新后的偏移量
    func readMessagesFromOffset(
        sessionPath: String,
        sessionId: String,
        fromOffset: Int64
    ) -> IncrementalReadResult? {
        guard let fileHandle = FileHandle(forReadingAtPath: sessionPath) else {
            return nil
        }
        defer { try? fileHandle.close() }

        // 游标失效检查：文件大小 < offset 时重置
        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return nil
        }

        let actualOffset: UInt64
        if fromOffset < 0 || UInt64(fromOffset) > fileSize {
            // 游标失效，重置到文件开头
            actualOffset = 0
        } else {
            actualOffset = UInt64(fromOffset)
        }

        // Seek 到目标位置
        do {
            try fileHandle.seek(toOffset: actualOffset)
        } catch {
            return nil
        }

        // 读取剩余数据
        let data: Data
        do {
            data = fileHandle.readDataToEndOfFile()
        }

        guard !data.isEmpty else {
            return IncrementalReadResult(
                messages: [],
                newOffset: Int64(actualOffset),
                lastUUID: nil
            )
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // 分行处理
        var lines = content.components(separatedBy: "\n")

        // 完整行保证：如果最后一个字符不是换行符，丢弃最后一行（不完整）
        if !content.hasSuffix("\n") && !lines.isEmpty {
            lines.removeLast()
        }

        // 解析每一行
        var messages: [RawMessage] = []
        var lastUUID: String? = nil
        var bytesConsumed: Int64 = 0

        for line in lines {
            // +1 for newline character
            bytesConsumed += Int64(line.utf8.count) + 1

            // 跳过空行
            guard !line.isEmpty else { continue }

            // 解析 JSON
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                // W2: 记录解析失败用于诊断（损坏数据跳过是正确的，不完整行已由 removeLast 保证不进入循环）
                logDebug("[VlaudeKit][V2] JSONL 行解析失败，跳过 (session=\(sessionId), offset=\(Int64(actualOffset) + bytesConsumed))")
                continue
            }

            // 只处理 user/assistant/message 类型
            let entryType = json["type"] as? String
            guard entryType == "user" || entryType == "assistant" || entryType == "message" else {
                continue
            }

            // 跳过非显示消息（V2: 不再跳过 toolUseResult，改为标记 eventType）
            if json["isVisibleInTranscriptOnly"] as? Bool == true { continue }
            if json["isCompactSummary"] as? Bool == true { continue }
            if json["isMeta"] as? Bool == true { continue }

            // 提取 UUID
            guard let uuid = json["uuid"] as? String
                ?? (json["message"] as? [String: Any])?["id"] as? String else {
                continue
            }

            // 提取消息类型
            // W3: type=message 时检查 message.role（防御性：理论上都是 assistant）
            let messageType: Int
            if entryType == "user" {
                messageType = 0
            } else if entryType == "message" {
                if let msg = json["message"] as? [String: Any],
                   let role = msg["role"] as? String, role == "user" {
                    messageType = 0
                } else {
                    messageType = 1
                }
            } else {
                messageType = 1  // assistant
            }

            // 提取 content（序列化为字符串，兼容 ContentBlockParser.generatePreview）
            let contentStr: String
            if let toolResult = json["toolUseResult"] {
                // tool_result 消息：序列化整个 toolUseResult 对象
                if let str = toolResult as? String {
                    contentStr = str
                } else if JSONSerialization.isValidJSONObject(toolResult),
                          let jsonData = try? JSONSerialization.data(withJSONObject: toolResult),
                          let str = String(data: jsonData, encoding: .utf8) {
                    contentStr = str
                } else {
                    contentStr = "\(toolResult)"
                }
            } else if let msgContent = (json["message"] as? [String: Any])?["content"] {
                if let str = msgContent as? String {
                    contentStr = str
                } else if JSONSerialization.isValidJSONObject(msgContent),
                          let jsonData = try? JSONSerialization.data(withJSONObject: msgContent),
                          let str = String(data: jsonData, encoding: .utf8) {
                    contentStr = str
                } else {
                    contentStr = ""
                }
            } else {
                contentStr = ""
            }

            // 提取 timestamp
            let timestamp = json["timestamp"] as? String

            // V2: 提取 Turn Context 字段
            let requestId = json["requestId"] as? String
            let agentId = json["agentId"] as? String

            // 提取 message.stop_reason
            let stopReason: String?
            if let msg = json["message"] as? [String: Any] {
                stopReason = msg["stop_reason"] as? String
            } else {
                stopReason = nil
            }

            // 推断 eventType
            let eventType: String?
            if messageType == 0 {
                // user 消息
                if json["toolUseResult"] != nil {
                    eventType = "tool_result"
                } else {
                    eventType = "user_text"
                }
            } else {
                // S3: assistant 消息按优先级推断 eventType（tool_use > thinking > 首个 block）
                // 一条消息可能包含 [text, tool_use] 多个 block，tool_use 最关键不能遗漏
                if let msg = json["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    let types = content.compactMap { $0["type"] as? String }
                    if types.contains("tool_use") {
                        eventType = "tool_use"
                    } else if types.contains("thinking") {
                        eventType = "thinking"
                    } else {
                        eventType = types.first
                    }
                } else {
                    eventType = nil
                }
            }

            messages.append(RawMessage(
                uuid: uuid,
                sessionId: sessionId,
                messageType: messageType,
                content: contentStr,
                timestamp: timestamp,
                requestId: requestId,
                stopReason: stopReason,
                eventType: eventType,
                agentId: agentId
            ))

            lastUUID = uuid
        }

        let newOffset = Int64(actualOffset) + bytesConsumed
        return IncrementalReadResult(
            messages: messages,
            newOffset: newOffset,
            lastUUID: lastUUID
        )
    }

    // MARK: - Project Operations

    /// List all projects
    func listProjects(limit: UInt32 = 0) -> [ProjectInfo]? {
        var arrayPtr: UnsafeMutablePointer<ProjectInfoArray>?

        let err: FfiError
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

        let err: FfiError
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
                    lastModified: s.file_mtime >= 0 ? s.file_mtime : nil,
                    messageCount: s.message_count >= 0 ? s.message_count : nil,
                    lastMessageType: s.last_message_type != nil ? String(cString: s.last_message_type) : nil,
                    lastMessagePreview: s.last_message_preview != nil ? String(cString: s.last_message_preview) : nil,
                    lastMessageAt: s.last_message_at >= 0 ? s.last_message_at : nil
                ))
            }
        }
        return results
    }

    /// Find the latest session for a project
    func findLatestSession(projectPath: String, withinSeconds: UInt64 = 0) -> SessionMeta? {
        var sessionPtr: UnsafeMutablePointer<SessionMetaC>?

        let err: FfiError
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
            lastModified: s.file_mtime >= 0 ? s.file_mtime : nil,
            messageCount: s.message_count >= 0 ? s.message_count : nil,
            lastMessageType: s.last_message_type != nil ? String(cString: s.last_message_type) : nil,
            lastMessagePreview: s.last_message_preview != nil ? String(cString: s.last_message_preview) : nil,
            lastMessageAt: s.last_message_at >= 0 ? s.last_message_at : nil
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

        // 手动转换 RawMessage 到字典
        let messagesArray: [[String: Any]] = result.messages.map { msg in
            var dict: [String: Any] = [
                "uuid": msg.uuid,
                "session_id": msg.sessionId,
                "message_type": msg.messageType,
                "content": msg.content
            ]
            if let ts = msg.timestamp {
                dict["timestamp"] = ts
            }
            return dict
        }

        // Wrap in MessagesResult format
        let json: [String: Any] = [
            "messages": messagesArray,
            "total": result.total,
            "has_more": result.hasMore
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: json) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    // MARK: - Path Utilities

    /// 获取会话文件路径
    ///
    /// 通过 session_id 查询完整的 JSONL 文件路径。
    /// 需要先调用 listSessions 来填充缓存。
    func getSessionPath(sessionId: String) -> String? {
        guard let projectsPath = projectsPath else { return nil }
        let cstr = projectsPath.withCString { pp in
            sessionId.withCString { sid in
                session_db_get_session_path(pp, sid)
            }
        }
        guard let cstr = cstr else { return nil }
        defer { session_db_free_string(cstr) }
        return String(cString: cstr)
    }

    /// 获取项目的编码目录名
    ///
    /// 通过 project_path 查询对应的编码目录名。
    /// 需要先调用 listProjects 来填充缓存。
    func getEncodedDirName(projectPath: String) -> String? {
        guard let projectsPath = projectsPath else { return nil }
        let cstr = projectsPath.withCString { pp in
            projectPath.withCString { path in
                session_db_get_encoded_dir_name(pp, path)
            }
        }
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
            logWarn("[SessionReader] Parse error: \(result.error)")
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
