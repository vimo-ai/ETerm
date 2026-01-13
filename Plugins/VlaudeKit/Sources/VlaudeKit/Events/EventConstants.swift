import Foundation

/**
 * Vlaude 事件常量定义
 *
 * 此文件是 Swift 端的事件名称定义
 * Server 端: vlaude/packages/vlaude-server/src/shared/events/constants.ts
 * Rust 端: vlaude/packages/vlaude-core/socket-client/src/events.rs
 *
 * 修改事件名后运行 ./scripts/check-vlaude-events.sh 验证三端一致性
 */

// @event-registry-start

/// Daemon → Server 上行事件
public enum DaemonEvents {
    // MARK: - 连接生命周期

    /// @payload { hostname: String, platform: String, version: String }
    public static let register = "daemon:register"
    /// @payload { success: Bool }
    public static let registered = "daemon:registered"
    /// @payload { timestamp: String }
    public static let online = "daemon:online"
    /// @payload { timestamp: String }
    public static let offline = "daemon:offline"
    /// @payload { timestamp: String, openSessions: [SessionInfo]? }
    public static let heartbeat = "daemon:heartbeat"

    // MARK: - 会话生命周期

    /// @payload { sessionId: String, projectPath: String, timestamp: String }
    public static let sessionStart = "daemon:sessionStart"
    /// @payload { sessionId: String, timestamp: String }
    public static let sessionEnd = "daemon:sessionEnd"
    /// @payload { sessionId: String, projectPath: String, timestamp: String }
    public static let sessionAvailable = "daemon:sessionAvailable"
    /// @payload { sessionId: String, timestamp: String }
    public static let sessionUnavailable = "daemon:sessionUnavailable"

    // MARK: - 数据响应

    /// @payload { projects: [Project], requestId: String? }
    public static let projectData = "daemon:projectData"
    /// @payload { sessions: [Session], projectPath: String?, requestId: String? }
    public static let sessionMetadata = "daemon:sessionMetadata"
    /// @payload { sessionId: String, projectPath: String, messages: [Message], total: Int, hasMore: Bool, requestId: String? }
    public static let sessionMessages = "daemon:sessionMessages"
    /// @payload { results: [SearchResult], requestId: String? }
    public static let searchResults = "daemon:searchResults"

    // MARK: - 实时通知

    /// @payload { sessionId: String, message: Message, timestamp: String }
    public static let newMessage = "daemon:newMessage"
    /// @payload { sessionId: String, metadata: SessionMetadata }
    public static let sessionUpdate = "daemon:sessionUpdate"
    /// @payload { sessions: [SessionSummary] }
    public static let sessionListUpdate = "daemon:sessionListUpdate"
    /// @payload { projectPath: String, metadata: ProjectMetadata? }
    public static let projectUpdate = "daemon:projectUpdate"
    /// @payload { projects: [ProjectSummary] }
    public static let projectListUpdate = "daemon:projectListUpdate"

    // MARK: - 新会话创建流程

    /// @payload { clientId: String, sessionId: String, projectPath: String, encodedDirName: String }
    public static let newSessionFound = "daemon:newSessionFound"
    /// @payload { clientId: String, projectPath: String }
    public static let newSessionNotFound = "daemon:newSessionNotFound"
    /// @payload { clientId: String, projectPath: String }
    public static let watchStarted = "daemon:watchStarted"
    /// @payload { clientId: String, sessionId: String, projectPath: String }
    public static let newSessionCreated = "daemon:newSessionCreated"

    // MARK: - 权限请求

    /// @payload { requestId: String, sessionId: String, clientId: String, toolName: String, input: Any, toolUseId: String, description: String }
    public static let permissionRequest = "daemon:permissionRequest"
    /// @payload { requestId: String, sessionId: String, clientId: String }
    public static let permissionTimeout = "daemon:permissionTimeout"
    /// @payload { requestId: String, message: String }
    public static let permissionExpired = "daemon:permissionExpired"
    /// @payload { toolUseId: String, sessionId: String, success: Bool, message: String? }
    /// ETerm 收到 iOS 审批后发送确认，通知 iOS 更新状态
    public static let approvalAck = "daemon:approvalAck"

    // MARK: - ETerm 状态

    /// @payload { deviceId: String, timestamp: String }
    public static let etermOnline = "daemon:etermOnline"
    /// @payload { deviceId: String, timestamp: String }
    public static let etermOffline = "daemon:etermOffline"
    /// @payload { sessionId: String, projectPath: String }
    public static let swiftActivity = "daemon:swiftActivity"

    // MARK: - 其他

    /// @payload { sessionId: String, clientId: String, error: SdkError }
    public static let sdkError = "daemon:sdkError"
    /// @payload { sessionId: String, metrics: Metrics, timestamp: String }
    public static let metricsUpdate = "daemon:metricsUpdate"
    /// @payload { sessionId: String, projectPath: String }
    public static let sessionDetailUpdate = "daemon:sessionDetailUpdate"
    /// @payload { sessionId: String, projectPath: String }
    public static let sessionRestored = "daemon:sessionRestored"
    /// @payload { sessionId: String, projectPath: String }
    public static let sessionDeleted = "daemon:sessionDeleted"

    // MARK: - 命令响应

    /// @payload { success: Bool, sessionId: String?, error: String?, requestId: String? }
    public static let sessionCreatedResult = "daemon:sessionCreatedResult"
    /// @payload { loading: Bool, requestId: String? }
    public static let checkLoadingResult = "daemon:checkLoadingResult"
    /// @payload { success: Bool, error: String?, requestId: String? }
    public static let sendMessageResult = "daemon:sendMessageResult"
}

/// Server → Daemon 下行事件
public enum ServerEvents {
    // MARK: - 数据请求

    /// @payload { limit: Int?, requestId: String? }
    public static let requestProjectData = "server:requestProjectData"
    /// @payload { projectPath: String?, limit: Int?, requestId: String? }
    public static let requestSessionMetadata = "server:requestSessionMetadata"
    /// @payload { sessionId: String, projectPath: String, limit: Int, offset: Int, order: String?, requestId: String? }
    public static let requestSessionMessages = "server:requestSessionMessages"
    /// @payload { query: String, projectPath: String?, requestId: String? }
    public static let requestSearch = "server:requestSearch"

    // MARK: - 会话监听

    /// @payload { sessionId: String, projectPath: String }
    public static let startWatching = "server:startWatching"
    /// @payload { sessionId: String, projectPath: String }
    public static let stopWatching = "server:stopWatching"
    /// @payload { sessionId: String, isViewing: Bool }
    public static let mobileViewing = "server:mobileViewing"

    // MARK: - 会话创建

    /// @payload { clientId: String, projectPath: String }
    public static let findNewSession = "server:findNewSession"
    /// @payload { clientId: String, projectPath: String }
    public static let watchNewSession = "server:watchNewSession"
    /// @payload { projectPath: String, sessionId: String }
    public static let sessionDiscovered = "server:sessionDiscovered"

    // MARK: - 远程控制

    /// @payload { projectPath: String, requestId: String? }
    public static let createSession = "server:createSession"
    /// @payload { projectPath: String, requestId: String? }
    public static let createSessionInEterm = "server:createSessionInEterm"
    /// @payload { sessionId: String, message: String, requestId: String? }
    public static let sendMessage = "server:sendMessage"
    /// @payload { sessionId: String, requestId: String? }
    public static let checkLoading = "server:checkLoading"
    /// @payload { sessionId: String, text: String }
    public static let injectToEterm = "server:injectToEterm"

    // MARK: - 权限响应

    /// @payload { requestId: String, sessionId: String, action: String }
    /// action: y=允许一次, n=拒绝, a=始终允许, 或自定义输入如 "n: 理由"
    public static let permissionResponse = "server:permissionResponse"

    // MARK: - iOS 客户端事件

    /// @payload { sessionId: String }
    public static let exitRemoteAllowed = "server:exitRemoteAllowed"
    /// @payload { sessionId: String, reason: String }
    public static let exitRemoteDenied = "server:exitRemoteDenied"
    /// @payload { sessionId: String }
    public static let sessionConfirmed = "server:sessionConfirmed"

    // MARK: - 其他

    /// @payload { sessionId: String }
    public static let resumeLocal = "server:resumeLocal"
    /// @payload { command: String, data: Any? }
    public static let command = "server:command"
    /// 无 payload
    public static let serverShutdown = "server-shutdown"
}

// @event-registry-end
