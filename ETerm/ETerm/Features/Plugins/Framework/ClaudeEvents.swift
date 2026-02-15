//
//  ClaudeEvents.swift
//  ETerm
//
//  Claude 插件 - 事件定义

import Foundation

/// Claude 插件事件
///
/// 由 ClaudeSocketServer 发射，插件可订阅
enum ClaudeEvents {

    /// Session 开始
    struct SessionStart: DomainEvent {
        static let name = "claude.sessionStart"
        let metadata = EventMetadata()
        var eventId: UUID { metadata.eventId }
        var timestamp: Date { metadata.timestamp }

        let terminalId: Int
        let sessionId: String
    }

    /// 用户提交问题（Claude 开始思考）
    struct PromptSubmit: DomainEvent {
        static let name = "claude.promptSubmit"
        let metadata = EventMetadata()
        var eventId: UUID { metadata.eventId }
        var timestamp: Date { metadata.timestamp }

        let terminalId: Int
        let sessionId: String
        let prompt: String?
    }

    /// 等待用户输入
    struct WaitingInput: DomainEvent {
        static let name = "claude.waitingInput"
        let metadata = EventMetadata()
        var eventId: UUID { metadata.eventId }
        var timestamp: Date { metadata.timestamp }

        let terminalId: Int
        let sessionId: String
    }

    /// 权限请求（需要用户确认才能继续）
    struct PermissionPrompt: DomainEvent {
        static let name = "claude.permissionPrompt"
        let metadata = EventMetadata()
        var eventId: UUID { metadata.eventId }
        var timestamp: Date { metadata.timestamp }

        let terminalId: Int
        let sessionId: String
        let message: String?  // 可选（PermissionRequest hook 没有）

        // 工具信息（来自 PermissionRequest hook）
        let toolName: String  // 工具名称：Bash, Write, Edit, Task 等
        let toolInput: [String: Any]  // 工具输入：{"command": "..."} 等
        let toolUseId: String?  // 工具调用 ID

        let transcriptPath: String?
        let cwd: String?
    }

    /// 响应完成
    struct ResponseComplete: DomainEvent {
        static let name = "claude.responseComplete"
        let metadata = EventMetadata()
        var eventId: UUID { metadata.eventId }
        var timestamp: Date { metadata.timestamp }

        let terminalId: Int
        let sessionId: String
    }

    /// Session 结束
    struct SessionEnd: DomainEvent {
        static let name = "claude.sessionEnd"
        let metadata = EventMetadata()
        var eventId: UUID { metadata.eventId }
        var timestamp: Date { metadata.timestamp }

        let terminalId: Int
        let sessionId: String
    }
}
