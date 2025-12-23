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
