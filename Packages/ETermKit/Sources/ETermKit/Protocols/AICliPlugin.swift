// AICliPlugin.swift
// ETermKit
//
// AI CLI 插件协议 - 支持多种 AI CLI（Claude、Gemini、Codex、OpenCode）
//
// 设计原则：
// - 统一的事件类型和能力声明
// - 各 CLI 实现有的事件就实现，没有的静态声明不支持
// - 功能链路根据能力声明决定是否启用

import Foundation
import SwiftUI

// MARK: - 事件类型

/// AI CLI 标准事件类型
///
/// 所有 AI CLI 的事件都映射到这些标准类型。
/// 不同 CLI 支持的事件不同，通过 `AICliCapabilities` 声明。
public enum AICliEventType: String, Sendable, CaseIterable {
    /// 会话开始
    /// - Claude: session_start
    /// - Gemini: SessionStart
    /// - OpenCode: session.created
    /// - Codex: ❌ 不支持
    case sessionStart

    /// 会话结束
    /// - Claude: session_end
    /// - Gemini: SessionEnd
    /// - OpenCode: ❌ 不支持
    /// - Codex: ❌ 不支持
    case sessionEnd

    /// 用户输入提交
    /// - Claude: user_prompt_submit
    /// - Gemini: BeforeAgent
    /// - OpenCode: ❌ 不支持
    /// - Codex: ❌ 不支持
    case userInput

    /// AI 开始思考/处理
    /// - Claude: user_prompt_submit (同 userInput)
    /// - Gemini: BeforeModel
    /// - OpenCode: ❌ 不支持
    /// - Codex: ❌ 不支持
    case assistantThinking

    /// AI 响应完成
    /// - Claude: stop
    /// - Gemini: AfterAgent
    /// - OpenCode: session.idle
    /// - Codex: agent-turn-complete ✅ 唯一支持的事件
    case responseComplete

    /// 等待用户输入（权限确认、问题等）
    /// - Claude: notification
    /// - Gemini: Notification
    /// - OpenCode: ❌ 不支持
    /// - Codex: ❌ 不支持
    case waitingInput

    /// 权限请求
    /// - Claude: permission_request
    /// - Gemini: BeforeTool (decision)
    /// - OpenCode: permission.*
    /// - Codex: ❌ 不支持
    case permissionRequest

    /// 工具调用（执行前/后）
    /// - Claude: PreToolUse / PostToolUse
    /// - Gemini: BeforeTool / AfterTool
    /// - OpenCode: tool.execute.before / tool.execute.after
    /// - Codex: ❌ 不支持
    case toolUse
}

// MARK: - 事件结构

/// AI CLI 统一事件结构
///
/// 不同 CLI 的原始事件映射到此结构。
public struct AICliEvent: @unchecked Sendable {
    /// 数据来源（claude, gemini, codex, opencode）
    public let source: String

    /// 事件类型
    public let type: AICliEventType

    /// 终端 ID
    public let terminalId: Int

    /// 会话 ID
    public let sessionId: String

    /// 会话文件路径（用于 memex 索引）
    public let transcriptPath: String?

    /// 工作目录
    public let cwd: String?

    /// 时间戳（毫秒）
    public let timestamp: Int64

    /// CLI 特定的原始数据
    public let payload: [String: Any]

    public init(
        source: String,
        type: AICliEventType,
        terminalId: Int,
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payload: [String: Any] = [:]
    ) {
        self.source = source
        self.type = type
        self.terminalId = terminalId
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.timestamp = timestamp
        self.payload = payload
    }
}

// MARK: - 能力声明

/// AI CLI 能力声明
///
/// 静态声明插件支持的事件类型。
/// 功能链路根据此声明决定是否启用。
public struct AICliCapabilities: Sendable {
    public let sessionStart: Bool
    public let sessionEnd: Bool
    public let userInput: Bool
    public let assistantThinking: Bool
    public let responseComplete: Bool
    public let waitingInput: Bool
    public let permissionRequest: Bool
    public let toolUse: Bool

    public init(
        sessionStart: Bool = false,
        sessionEnd: Bool = false,
        userInput: Bool = false,
        assistantThinking: Bool = false,
        responseComplete: Bool = false,
        waitingInput: Bool = false,
        permissionRequest: Bool = false,
        toolUse: Bool = false
    ) {
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.userInput = userInput
        self.assistantThinking = assistantThinking
        self.responseComplete = responseComplete
        self.waitingInput = waitingInput
        self.permissionRequest = permissionRequest
        self.toolUse = toolUse
    }

    /// 检查是否支持指定事件
    public func supports(_ eventType: AICliEventType) -> Bool {
        switch eventType {
        case .sessionStart: return sessionStart
        case .sessionEnd: return sessionEnd
        case .userInput: return userInput
        case .assistantThinking: return assistantThinking
        case .responseComplete: return responseComplete
        case .waitingInput: return waitingInput
        case .permissionRequest: return permissionRequest
        case .toolUse: return toolUse
        }
    }

    /// 检查是否支持所有指定事件
    public func supportsAll(_ eventTypes: Set<AICliEventType>) -> Bool {
        eventTypes.allSatisfy { supports($0) }
    }

    /// 获取所有支持的事件类型
    public var supportedEvents: Set<AICliEventType> {
        var events = Set<AICliEventType>()
        if sessionStart { events.insert(.sessionStart) }
        if sessionEnd { events.insert(.sessionEnd) }
        if userInput { events.insert(.userInput) }
        if assistantThinking { events.insert(.assistantThinking) }
        if responseComplete { events.insert(.responseComplete) }
        if waitingInput { events.insert(.waitingInput) }
        if permissionRequest { events.insert(.permissionRequest) }
        if toolUse { events.insert(.toolUse) }
        return events
    }
}

// MARK: - 预定义能力

public extension AICliCapabilities {
    /// Claude Code - 全部支持
    static let claude = AICliCapabilities(
        sessionStart: true,
        sessionEnd: true,
        userInput: true,
        assistantThinking: true,
        responseComplete: true,
        waitingInput: true,
        permissionRequest: true,
        toolUse: true
    )

    /// Gemini CLI - 几乎全部支持
    static let gemini = AICliCapabilities(
        sessionStart: true,
        sessionEnd: true,
        userInput: true,
        assistantThinking: true,
        responseComplete: true,
        waitingInput: true,
        permissionRequest: true,
        toolUse: true
    )

    /// OpenCode - 部分支持
    static let opencode = AICliCapabilities(
        sessionStart: true,
        sessionEnd: false,
        userInput: false,
        assistantThinking: false,
        responseComplete: true,
        waitingInput: false,
        permissionRequest: true,
        toolUse: true
    )

    /// Codex CLI - 仅支持 responseComplete
    static let codex = AICliCapabilities(
        sessionStart: false,
        sessionEnd: false,
        userInput: false,
        assistantThinking: false,
        responseComplete: true,
        waitingInput: false,
        permissionRequest: false,
        toolUse: false
    )
}

// MARK: - 功能链路需求

/// 功能链路所需的事件集合
///
/// 定义各功能启用所需的最小事件集。
/// 插件能力不满足时，该功能不启用。
public enum AICliFeatureRequirements {
    /// memex 会话索引 - 只需要 responseComplete
    public static let memexIndexing: Set<AICliEventType> = [.responseComplete]

    /// Tab completed 装饰 - 只需要 responseComplete
    public static let tabCompleted: Set<AICliEventType> = [.responseComplete]

    /// Tab thinking 动画 - 需要 userInput + responseComplete
    public static let thinkingAnimation: Set<AICliEventType> = [.userInput, .responseComplete]

    /// Tab waiting 提醒 - 需要 waitingInput
    public static let waitingNotification: Set<AICliEventType> = [.waitingInput]

    /// 远程权限审批 - 需要 permissionRequest
    public static let remoteApproval: Set<AICliEventType> = [.permissionRequest]

    /// 工具拦截/监控 - 需要 toolUse
    public static let toolMonitoring: Set<AICliEventType> = [.toolUse]

    /// 会话生命周期管理 - 需要 sessionStart + sessionEnd
    public static let sessionLifecycle: Set<AICliEventType> = [.sessionStart, .sessionEnd]
}

// MARK: - AI CLI Provider 协议

/// AI CLI Provider 协议
///
/// 每个 CLI 实现一个 Provider，负责：
/// - 声明能力（支持哪些事件）
/// - 启动/停止 Hook 监听
/// - 将原始事件映射为标准 AICliEvent
///
/// Provider 由 AICliKit 插件统一管理，共享：
/// - SessionMapper（会话映射）
/// - TabDecorator（Tab 装饰）
/// - TitleGenerator（标题生成）
/// - EventBroadcaster（事件广播）
@MainActor
public protocol AICliProvider: AnyObject {
    /// Provider 标识（如 "claude", "gemini", "codex", "opencode"）
    static var providerId: String { get }

    /// 能力声明
    static var capabilities: AICliCapabilities { get }

    /// 事件回调
    var onEvent: ((AICliEvent) -> Void)? { get set }

    /// 初始化
    init()

    /// 启动 Hook 监听
    ///
    /// - Parameter config: 配置信息（socket 路径等）
    func start(config: AICliProviderConfig)

    /// 停止 Hook 监听
    func stop()

    /// 检查是否正在运行
    var isRunning: Bool { get }
}

/// Provider 配置
public struct AICliProviderConfig {
    /// Socket 目录路径
    public let socketDirectory: String

    /// 主应用桥接（用于访问 HostBridge 能力）
    public let hostBridge: (any HostBridge)?

    public init(socketDirectory: String, hostBridge: (any HostBridge)? = nil) {
        self.socketDirectory = socketDirectory
        self.hostBridge = hostBridge
    }
}

// MARK: - Provider 默认实现

public extension AICliProvider {
    /// 检查是否支持某个功能链路
    static func supportsFeature(_ requirements: Set<AICliEventType>) -> Bool {
        capabilities.supportsAll(requirements)
    }
}

// MARK: - AI CLI 插件协议

/// AI CLI 插件协议
///
/// 统一管理多个 AI CLI Provider 的插件协议。
///
/// 设计：
/// - 一个 AICliKit 插件
/// - 内部包含多个 Provider（Claude、Gemini、Codex、OpenCode）
/// - 共享核心逻辑（SessionMapper、TabDecorator 等）
///
/// 示例：
/// ```swift
/// @objc(AICliKitPlugin)
/// public final class AICliKitPlugin: NSObject, AICliKitProtocol {
///     public static var id = "com.eterm.aicli"
///
///     private var providers: [any AICliProvider] = []
///
///     public func activate(host: HostBridge) {
///         // 注册所有 Provider
///         providers = [
///             ClaudeProvider(),
///             GeminiProvider(),
///             CodexProvider(),
///             OpenCodeProvider()
///         ]
///         // 启动各 Provider
///         for provider in providers {
///             provider.onEvent = { [weak self] event in
///                 self?.handleEvent(event)
///             }
///             provider.start(config: ...)
///         }
///     }
/// }
/// ```
@MainActor
public protocol AICliKitProtocol: Plugin {
    /// 已注册的 Provider 列表
    var providers: [any AICliProvider] { get }

    /// 获取合并后的能力（所有 Provider 能力的并集）
    var combinedCapabilities: AICliCapabilities { get }

    /// 处理来自任意 Provider 的事件
    func handleEvent(_ event: AICliEvent)
}

// MARK: - 默认实现

public extension AICliKitProtocol {
    /// 合并所有 Provider 的能力
    var combinedCapabilities: AICliCapabilities {
        var caps = AICliCapabilities()
        for provider in providers {
            let providerCaps = type(of: provider).capabilities
            caps = AICliCapabilities(
                sessionStart: caps.sessionStart || providerCaps.sessionStart,
                sessionEnd: caps.sessionEnd || providerCaps.sessionEnd,
                userInput: caps.userInput || providerCaps.userInput,
                assistantThinking: caps.assistantThinking || providerCaps.assistantThinking,
                responseComplete: caps.responseComplete || providerCaps.responseComplete,
                waitingInput: caps.waitingInput || providerCaps.waitingInput,
                permissionRequest: caps.permissionRequest || providerCaps.permissionRequest,
                toolUse: caps.toolUse || providerCaps.toolUse
            )
        }
        return caps
    }

    /// 检查是否有任意 Provider 支持某功能
    func anyProviderSupports(_ requirements: Set<AICliEventType>) -> Bool {
        providers.contains { type(of: $0).capabilities.supportsAll(requirements) }
    }

    /// 获取支持指定功能的 Provider 列表
    func providersSupporting(_ requirements: Set<AICliEventType>) -> [any AICliProvider] {
        providers.filter { type(of: $0).capabilities.supportsAll(requirements) }
    }
}
