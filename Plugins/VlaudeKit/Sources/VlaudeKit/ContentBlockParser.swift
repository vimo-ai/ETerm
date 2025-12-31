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

    /// 提取 tool_result 的内容
    private static func extractToolResultContent(_ content: Any?) -> String {
        guard let content = content else {
            return ""
        }

        if let str = content as? String {
            return str
        }

        if let data = try? JSONSerialization.data(withJSONObject: content, options: .prettyPrinted),
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
