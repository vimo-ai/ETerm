//
//  ContentBlockParser.swift
//  VlaudeKit
//
//  从 raw JSONL 行解析结构化内容块，用于 UI 渲染
//  解决 [Tool: Read] 等静态文本的交互体验问题
//
//  使用方式：
//  1. 直接从 JSONL 文件读取：ContentBlockParser.readMessage(from: sessionPath, uuid: messageUuid)
//  2. 从已有 raw 字符串解析：ContentBlockParser.parse(rawJsonLine)
//

import Foundation

// MARK: - Content Block Types

/// 内容块类型
public enum ContentBlock: Equatable {
    /// 纯文本
    case text(String)

    /// 工具调用
    case toolUse(ToolUseBlock)

    /// 工具返回结果
    case toolResult(ToolResultBlock)

    /// 思考过程
    case thinking(String)

    /// 未知类型（fallback）
    case unknown(String)
}

/// 工具调用块
public struct ToolUseBlock: Equatable {
    public let id: String
    public let name: String
    public let input: [String: Any]

    /// 生成用于 UI 展示的简短描述
    public var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] as? String {
                let fileName = (path as NSString).lastPathComponent
                if let limit = input["limit"] as? Int {
                    return "读取文件: \(fileName) (前 \(limit) 行)"
                }
                return "读取文件: \(fileName)"
            }
            return "读取文件"

        case "Write":
            if let path = input["file_path"] as? String {
                let fileName = (path as NSString).lastPathComponent
                return "写入文件: \(fileName)"
            }
            return "写入文件"

        case "Edit":
            if let path = input["file_path"] as? String {
                let fileName = (path as NSString).lastPathComponent
                return "编辑文件: \(fileName)"
            }
            return "编辑文件"

        case "Bash":
            if let cmd = input["command"] as? String {
                let preview = String(cmd.prefix(50))
                return "执行命令: \(preview)\(cmd.count > 50 ? "..." : "")"
            }
            return "执行命令"

        case "Glob":
            if let pattern = input["pattern"] as? String {
                return "搜索文件: \(pattern)"
            }
            return "搜索文件"

        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "搜索内容: \(pattern)"
            }
            return "搜索内容"

        case "Task":
            if let desc = input["description"] as? String {
                return "子任务: \(desc)"
            }
            return "子任务"

        case "WebFetch":
            if let url = input["url"] as? String {
                return "获取网页: \(url)"
            }
            return "获取网页"

        case "WebSearch":
            if let query = input["query"] as? String {
                return "搜索: \(query)"
            }
            return "网络搜索"

        default:
            return "工具: \(name)"
        }
    }

    /// 获取工具图标名称
    public var iconName: String {
        switch name {
        case "Read": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit": return "pencil"
        case "Bash": return "terminal"
        case "Glob": return "folder.badge.questionmark"
        case "Grep": return "magnifyingglass"
        case "Task": return "list.bullet"
        case "WebFetch": return "globe"
        case "WebSearch": return "magnifyingglass.circle"
        case "TodoWrite": return "checklist"
        default: return "wrench"
        }
    }

    public static func == (lhs: ToolUseBlock, rhs: ToolUseBlock) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

/// 工具结果块
public struct ToolResultBlock: Equatable {
    public let toolUseId: String
    public let isError: Bool
    public let content: String

    /// 生成用于 UI 展示的预览
    public var preview: String {
        let maxLength = 200
        if content.count <= maxLength {
            return content
        }
        return String(content.prefix(maxLength)) + "..."
    }

    /// 是否有更多内容
    public var hasMore: Bool {
        content.count > 200
    }

    /// 内容大小描述
    public var sizeDescription: String {
        let bytes = content.utf8.count
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
    }
}

// MARK: - Parser

/// 从 raw JSONL 行解析内容块
public enum ContentBlockParser {

    /// 解析 raw JSON 字符串为内容块数组
    /// - Parameter raw: 原始 JSONL 行
    /// - Returns: 解析后的内容块数组
    public static func parse(_ raw: String?) -> [ContentBlock] {
        guard let raw = raw, !raw.isEmpty else {
            return []
        }

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // 提取 message.content
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] else {
            return []
        }

        // content 可能是字符串或数组
        if let text = content as? String {
            return [.text(text)]
        }

        guard let blocks = content as? [[String: Any]] else {
            return []
        }

        return blocks.compactMap { parseBlock($0) }
    }

    /// 解析单个内容块
    private static func parseBlock(_ block: [String: Any]) -> ContentBlock? {
        guard let type = block["type"] as? String else {
            return nil
        }

        switch type {
        case "text":
            if let text = block["text"] as? String {
                return .text(text)
            }

        case "tool_use":
            if let id = block["id"] as? String,
               let name = block["name"] as? String {
                let input = block["input"] as? [String: Any] ?? [:]
                return .toolUse(ToolUseBlock(id: id, name: name, input: input))
            }

        case "tool_result":
            if let toolUseId = block["tool_use_id"] as? String {
                let isError = block["is_error"] as? Bool ?? false
                let content = extractToolResultContent(block["content"])
                return .toolResult(ToolResultBlock(toolUseId: toolUseId, isError: isError, content: content))
            }

        case "thinking":
            if let thinking = block["thinking"] as? String {
                return .thinking(thinking)
            }

        default:
            // 返回原始 JSON 作为 fallback
            if let data = try? JSONSerialization.data(withJSONObject: block),
               let str = String(data: data, encoding: .utf8) {
                return .unknown(str)
            }
        }

        return nil
    }

    /// 解析 tool_result user 消息的 toolUseResult JSON
    private static func parseToolResultContent(_ content: String) -> [ContentBlock]? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return [.text(content)]
        }

        // toolUseResult 可以是 dict 或 array
        if let dict = json as? [String: Any] {
            if let block = parseToolResultBlock(dict) {
                return [block]
            }
        } else if let arr = json as? [[String: Any]] {
            let blocks = arr.compactMap { parseToolResultBlock($0) }
            return blocks.isEmpty ? nil : blocks
        }

        return [.text(content)]
    }

    /// 从 toolUseResult 字典解析为 ContentBlock
    private static func parseToolResultBlock(_ dict: [String: Any]) -> ContentBlock? {
        // toolUseResult 格式: { toolUseId, content, isError }
        let toolUseId = dict["toolUseId"] as? String
            ?? dict["tool_use_id"] as? String
            ?? ""
        let isError = dict["isError"] as? Bool
            ?? dict["is_error"] as? Bool
            ?? false
        let resultContent = extractToolResultContent(dict["content"])

        guard !toolUseId.isEmpty || !resultContent.isEmpty else { return nil }

        return .toolResult(ToolResultBlock(
            toolUseId: toolUseId,
            isError: isError,
            content: resultContent
        ))
    }

    /// 提取 tool_result 的内容
    private static func extractToolResultContent(_ content: Any?) -> String {
        guard let content = content else {
            return ""
        }

        if let str = content as? String {
            return str
        }

        if JSONSerialization.isValidJSONObject(content),
           let data = try? JSONSerialization.data(withJSONObject: content, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }

        return "\(content)"
    }
}

// MARK: - Convenience Extensions

public extension Array where Element == ContentBlock {

    /// 是否包含工具调用
    var hasToolUse: Bool {
        contains { block in
            if case .toolUse = block { return true }
            return false
        }
    }

    /// 获取所有工具调用
    var toolUses: [ToolUseBlock] {
        compactMap { block in
            if case .toolUse(let tool) = block { return tool }
            return nil
        }
    }

    /// 获取纯文本内容
    var textContent: String {
        compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// 是否只包含文本（无工具调用）
    var isTextOnly: Bool {
        allSatisfy { block in
            if case .text = block { return true }
            return false
        }
    }
}

// MARK: - JSONL File Reader

public extension ContentBlockParser {

    /// 从 JSONL 文件读取指定消息的内容块
    /// - Parameters:
    ///   - sessionPath: 会话文件路径 (.jsonl)
    ///   - uuid: 消息 UUID
    /// - Returns: 解析后的内容块数组，找不到返回 nil
    static func readMessage(from sessionPath: String, uuid: String) -> [ContentBlock]? {
        guard let fileHandle = FileHandle(forReadingAtPath: sessionPath) else {
            return nil
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // 逐行查找匹配的消息
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // 检查 UUID 匹配（可能在顶层或 message.id）
            let lineUuid = json["uuid"] as? String
                ?? (json["message"] as? [String: Any])?["id"] as? String

            if lineUuid == uuid {
                return parse(line)
            }
        }

        return nil
    }

    /// 从 JSONL 文件读取所有消息的内容块
    /// - Parameter sessionPath: 会话文件路径 (.jsonl)
    /// - Returns: [(uuid, role, blocks)] 元组数组
    static func readAllMessages(from sessionPath: String) -> [(uuid: String, role: String, blocks: [ContentBlock])] {
        guard let fileHandle = FileHandle(forReadingAtPath: sessionPath) else {
            return []
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [(uuid: String, role: String, blocks: [ContentBlock])] = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // 只处理 message 类型
            let entryType = json["type"] as? String
            guard entryType == "user" || entryType == "assistant" || entryType == "message" else {
                continue
            }

            // 跳过 tool_result 等非显示消息
            if json["toolUseResult"] != nil { continue }
            if json["isVisibleInTranscriptOnly"] as? Bool == true { continue }
            if json["isCompactSummary"] as? Bool == true { continue }
            if json["isMeta"] as? Bool == true { continue }

            // 提取 UUID
            guard let uuid = json["uuid"] as? String
                ?? (json["message"] as? [String: Any])?["id"] as? String else {
                continue
            }

            // 提取 role
            let role: String
            if entryType == "user" {
                role = "user"
            } else if entryType == "assistant" {
                role = "assistant"
            } else {
                role = (json["message"] as? [String: Any])?["role"] as? String ?? "user"
            }

            // 解析内容块
            let blocks = parse(line)
            if !blocks.isEmpty {
                results.append((uuid: uuid, role: role, blocks: blocks))
            }
        }

        return results
    }
}

// MARK: - Rich Message Model

/// 富消息模型（包含结构化内容块）
public struct RichMessage {
    public let uuid: String
    public let role: String
    public let timestamp: String?
    public let blocks: [ContentBlock]

    /// 是否包含工具调用
    public var hasToolUse: Bool { blocks.hasToolUse }

    /// 获取纯文本内容
    public var textContent: String { blocks.textContent }

    /// 是否只有文本
    public var isTextOnly: Bool { blocks.isTextOnly }
}

public extension ContentBlockParser {

    /// 从 JSONL 文件读取富消息列表
    /// - Parameter sessionPath: 会话文件路径
    /// - Returns: RichMessage 数组
    static func readRichMessages(from sessionPath: String) -> [RichMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: sessionPath) else {
            return []
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [RichMessage] = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // 只处理 message 类型
            let entryType = json["type"] as? String
            guard entryType == "user" || entryType == "assistant" || entryType == "message" else {
                continue
            }

            // 跳过非显示消息
            if json["toolUseResult"] != nil { continue }
            if json["isVisibleInTranscriptOnly"] as? Bool == true { continue }
            if json["isCompactSummary"] as? Bool == true { continue }
            if json["isMeta"] as? Bool == true { continue }

            // 提取 UUID
            guard let uuid = json["uuid"] as? String
                ?? (json["message"] as? [String: Any])?["id"] as? String else {
                continue
            }

            // 提取 role
            let role: String
            if entryType == "user" {
                role = "user"
            } else if entryType == "assistant" {
                role = "assistant"
            } else {
                role = (json["message"] as? [String: Any])?["role"] as? String ?? "user"
            }

            // 提取 timestamp
            let timestamp = json["timestamp"] as? String

            // 解析内容块
            let blocks = parse(line)
            if !blocks.isEmpty {
                results.append(RichMessage(
                    uuid: uuid,
                    role: role,
                    timestamp: timestamp,
                    blocks: blocks
                ))
            }
        }

        return results
    }
}

// MARK: - Content Block Extraction (for Push)

public extension ContentBlockParser {

    /// 从 RawMessage.content 字符串解析结构化内容块（用于实时推送）
    ///
    /// 与 `parse(_:)` 不同，此方法接收的是已提取的 content 字符串
    /// （而非完整 JSONL 行），直接解析为 ContentBlock 数组。
    ///
    /// - Parameters:
    ///   - content: 消息内容字符串（user: 纯文本, assistant: JSON 数组字符串）
    ///   - messageType: 消息类型（0 = user, 1 = assistant）
    /// - Returns: 解析后的内容块数组，解析失败返回 nil
    static func parseContentBlocks(from content: String, messageType: Int, eventType: String? = nil) -> [ContentBlock]? {
        guard !content.isEmpty else { return nil }

        if messageType == 0 {
            // user 消息：区分 tool_result 和普通文本
            if eventType == "tool_result" {
                return parseToolResultContent(content)
            }
            return [.text(content)]
        }

        // assistant 消息：尝试解析为 JSON 数组
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            // 非 JSON，当作纯文本
            return [.text(content)]
        }

        // 纯字符串 content
        if let text = json as? String {
            return [.text(text)]
        }

        // content blocks 数组
        guard let blocks = json as? [[String: Any]] else {
            return [.text(content)]
        }

        let parsed = blocks.compactMap { parseBlock($0) }
        return parsed.isEmpty ? nil : parsed
    }
}

// MARK: - Preview Generator

public extension ContentBlockParser {

    /// 从 RawMessage 生成预览文本（用于列表页显示）
    /// - Parameters:
    ///   - content: 消息内容（字符串或 JSON）
    ///   - messageType: 消息类型（0 = user, 1 = assistant）
    /// - Returns: 预览文本（最多 100 字符）
    static func generatePreview(content: String, messageType: Int) -> String {
        if messageType == 0 {
            // User 消息：直接截断文本
            return truncateChars(content, maxChars: 100)
        }

        // Assistant 消息：解析 content 数组生成摘要
        return generateAssistantPreview(content)
    }

    /// 从 content 数组生成 assistant 消息预览
    private static func generateAssistantPreview(_ content: String) -> String {
        // 尝试解析为 JSON
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            // 非 JSON，直接截断
            return truncateChars(content, maxChars: 100)
        }

        // 如果是纯字符串
        if let text = json as? String {
            return truncateChars(text, maxChars: 100)
        }

        // 如果是数组（content blocks）
        guard let blocks = json as? [[String: Any]] else {
            return truncateChars(content, maxChars: 100)
        }

        var textParts: [String] = []
        var toolUses: [String] = []
        var hasThinking = false

        for block in blocks {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                if let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    toolUses.append(formatToolUse(name: name, input: input))
                }
            case "thinking":
                hasThinking = true
            default:
                break
            }
        }

        // 优先级：text > tool_use > thinking
        if !textParts.isEmpty {
            return truncateChars(textParts.joined(separator: " "), maxChars: 100)
        }

        if !toolUses.isEmpty {
            return toolUses.first ?? ""
        }

        if hasThinking {
            return "💭 思考中..."
        }

        return "（空消息）"
    }

    /// 格式化 tool_use 预览
    private static func formatToolUse(name: String, input: [String: Any]) -> String {
        let param: String
        switch name {
        case "Bash":
            param = (input["command"] as? String).map { truncateChars($0, maxChars: 30) } ?? ""
        case "Read":
            param = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        case "Write":
            param = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        case "Edit":
            param = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        case "Glob":
            param = (input["pattern"] as? String) ?? ""
        case "Grep":
            param = (input["pattern"] as? String) ?? ""
        default:
            param = ""
        }

        if param.isEmpty {
            return "🔧 \(name)"
        }
        return "🔧 \(name): \(param)"
    }

    /// Unicode 安全截断（避免多字节字符被截断）
    private static func truncateChars(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars {
            return trimmed
        }
        return String(trimmed.prefix(maxChars))
    }
}
