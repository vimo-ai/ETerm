//
//  CoreEvents.swift
//  ETerm
//
//  核心层 - 领域事件定义

import Foundation
import AppKit

/// 核心层领域事件
///
/// 所有核心层事件定义在此，插件通过 EventService 订阅
enum CoreEvents {

    // MARK: - Terminal 事件

    enum Terminal {
        /// 终端创建完成
        struct DidCreate: DomainEvent {
            static let name = "terminal.didCreate"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String
        }

        /// 终端即将关闭
        struct WillClose: DomainEvent {
            static let name = "terminal.willClose"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String?
        }

        /// 终端已关闭
        struct DidClose: DomainEvent {
            static let name = "terminal.didClose"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String?
        }

        /// 终端获得焦点
        struct DidFocus: DomainEvent {
            static let name = "terminal.didFocus"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String?
        }

        /// 终端失去焦点
        struct DidBlur: DomainEvent {
            static let name = "terminal.didBlur"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String?
        }

        /// 选区结束事件
        struct DidEndSelection: DomainEvent {
            static let name = "terminal.didEndSelection"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            /// 被选中的文本内容
            let text: String

            /// 选区在屏幕上的矩形位置（用于定位弹窗）
            let screenRect: NSRect

            /// 触发选择的源视图（弱引用）
            weak var sourceView: NSView?
        }
    }

    // MARK: - Tab 事件

    enum Tab {
        /// Tab 激活（用户切换到该 Tab）
        struct DidActivate: DomainEvent {
            static let name = "tab.didActivate"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String
        }

        /// Tab 失活
        struct DidDeactivate: DomainEvent {
            static let name = "tab.didDeactivate"
            let metadata = EventMetadata()
            var eventId: UUID { metadata.eventId }
            var timestamp: Date { metadata.timestamp }

            let terminalId: Int
            let tabId: String
        }
    }
}
