//
//  WritingAssistantPlugin.swift
//  WritingAssistantKit
//
//  写作助手插件入口点
//

import Foundation
import ETermKit

/// 写作助手插件入口类
///
/// 实现 PluginLogic 协议，提供 Cmd+K 快捷写作功能。
/// 通过 manifest.json 中的 commands 和 keyBinding 配置注册快捷键。
public final class WritingAssistantPlugin: PluginLogic {

    // MARK: - PluginLogic

    public static let id = "com.eterm.writing-assistant"

    private weak var host: HostBridge?

    public init() {}

    public func activate(host: HostBridge) {
        self.host = host
    }

    public func deactivate() {
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 当前不需要处理事件
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "writing.showComposer":
            showComposer()

        case "writing.hideComposer":
            hideComposer()

        case "writing.toggleComposer":
            toggleComposer()

        default:
            // 未知命令，静默忽略
            break
        }
    }

    // MARK: - Private Methods

    private func showComposer() {
        host?.emit(
            eventName: "plugin.writing-assistant.showComposer",
            payload: ["position": ["x": 0, "y": 0]]
        )
    }

    private func hideComposer() {
        host?.emit(
            eventName: "plugin.writing-assistant.hideComposer",
            payload: [:]
        )
    }

    private func toggleComposer() {
        host?.emit(
            eventName: "plugin.writing-assistant.toggleComposer",
            payload: ["position": ["x": 0, "y": 0]]
        )
    }
}
