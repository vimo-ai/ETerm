//
//  ClaudeProvider.swift
//  AICliKit
//
//  Claude Code Provider - 通过 vimo-agent 订阅 HookEvent
//

import Foundation
import ETermKit

/// Claude Provider - 实现 AICliProvider 协议
///
/// 通过 vimo-agent 订阅 HookEvent，将事件转换为标准 AICliEvent。
/// 支持从 context 提取 terminal_id 以关联正确的终端。
@MainActor
public final class ClaudeProvider: AICliProvider, AgentClientDelegate {
    public static let providerId = "claude"

    public static let capabilities = AICliCapabilities.claude

    public var onEvent: ((AICliEvent) -> Void)?

    private var agentClient: AgentClientBridge?
    private var config: AICliProviderConfig?

    public var isRunning: Bool {
        agentClient?.isConnected ?? false
    }

    public required init() {}

    public func start(config: AICliProviderConfig) {
        self.config = config

        // 在后台线程执行连接，避免阻塞主线程
        let pluginBundle = Bundle(for: Self.self)
        Task.detached(priority: .utility) { [weak self] in
            do {
                let client = try AgentClientBridge(component: "aiclikit", bundle: pluginBundle)

                // 连接到 vimo-agent（可能需要启动 agent，耗时操作）
                try client.connect()

                // 订阅 HookEvent
                try client.subscribeHookEvent()

                // 回到主线程设置状态
                await MainActor.run {
                    guard let self = self else { return }
                    client.delegate = self
                    self.agentClient = client
                    logInfo("[ClaudeProvider] started, subscribed to HookEvent")
                }

            } catch {
                await MainActor.run {
                    logError("[ClaudeProvider] failed to start: \(error)")
                }
            }
        }
    }

    public func stop() {
        agentClient?.disconnect()
        agentClient = nil
        logInfo("[ClaudeProvider] stopped")
    }

    // MARK: - AgentClientDelegate

    nonisolated func agentClient(_ client: AgentClientBridge, didReceiveHookEvent event: AgentHookEvent) {
        Task { @MainActor in
            if let aiCliEvent = self.mapHookEvent(event) {
                self.onEvent?(aiCliEvent)
            }
        }
    }

    nonisolated func agentClient(_ client: AgentClientBridge, didDisconnect error: Error?) {
        Task { @MainActor in
            logWarn("[ClaudeProvider] disconnected: \(error?.localizedDescription ?? "unknown")")
        }
    }

    // MARK: - Event Mapping

    /// 将 AgentHookEvent 映射为标准 AICliEvent
    private func mapHookEvent(_ event: AgentHookEvent) -> AICliEvent? {
        let eventType: AICliEventType
        var payload: [String: Any] = [:]

        // 事件类型映射（vimo-agent 使用 PascalCase）
        switch event.eventType {
        case "SessionStart":
            eventType = .sessionStart

        case "UserPromptSubmit":
            eventType = .userInput
            if let prompt = event.prompt {
                payload["prompt"] = prompt
            }

        case "Notification":
            eventType = .waitingInput

        case "Stop":
            eventType = .responseComplete

        case "SessionEnd":
            eventType = .sessionEnd

        case "PermissionRequest":
            eventType = .permissionRequest
            if let toolName = event.toolName {
                payload["toolName"] = toolName
            }
            if let toolInput = event.toolInput {
                payload["toolInput"] = toolInput.mapValues { $0.anyValue }
            }
            if let toolUseId = event.toolUseId {
                payload["toolUseId"] = toolUseId
            }

        default:
            // 未知事件类型，忽略
            logDebug("[ClaudeProvider] ignoring unknown event type: \(event.eventType)")
            return nil
        }

        // 从 context 提取 terminal_id（如果不存在则为 0）
        let terminalId = event.terminalId ?? 0

        return AICliEvent(
            source: Self.providerId,
            type: eventType,
            terminalId: terminalId,
            sessionId: event.sessionId,
            transcriptPath: event.transcriptPath,
            cwd: event.cwd,
            payload: payload
        )
    }
}
