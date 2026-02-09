//
//  VlaudePlugin.swift
//  VlaudeKit
//
//  Vlaude 远程控制插件 (SDK 版本)
//
//  职责：
//  - 直连 vlaude-server，上报 session 状态
//  - 接收注入请求，转发给终端
//  - 处理远程创建 Claude 会话请求
//  - Tab Slot 显示手机图标
//  - 实时监听会话文件变化，推送增量消息
//

import Foundation
import AppKit
import SwiftUI
import ETermKit
import SocketClientFFI
import SharedDbFFI

// MARK: - Cursor State（游标协议）

/// 读侧游标状态
///
/// 每个 session 维护独立游标，跟踪从 DB 已推送的消息数量。
/// 主游标是 messagesRead（DB offset），配合 session_db_list_messages 分页。
struct CursorState: Codable {
    /// 已推送消息数量（DB offset 游标）
    var messagesRead: Int
    /// JSONL 文件路径（notifyFileChange + 冷启动恢复用）
    var transcriptPath: String?

    /// 默认初始游标
    static var initial: CursorState {
        CursorState(messagesRead: 0, transcriptPath: nil)
    }
}

/// 游标持久化管理器
///
/// 原子写入：写临时文件 + rename，防止断电/崩溃导致游标损坏。
/// 存储位置：~/.vimo/plugins/vlaude/cursors.json
final class CursorStore {
    /// 游标文件路径
    private let filePath: String
    /// 内存中的游标状态
    private(set) var cursors: [String: CursorState] = [:]

    init() {
        let vimoRoot = ProcessInfo.processInfo.environment["VIMO_HOME"]
            ?? (NSHomeDirectory() + "/.vimo")
        let dir = vimoRoot + "/plugins/vlaude"
        self.filePath = dir + "/cursors.json"

        // 确保目录存在
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // 加载持久化游标
        load()
    }

    /// 从磁盘加载游标
    func load() {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = FileManager.default.contents(atPath: filePath),
              let decoded = try? JSONDecoder().decode([String: CursorState].self, from: data) else {
            cursors = [:]
            return
        }
        cursors = decoded
    }

    /// 原子写入游标到磁盘（temp file + rename）
    func save() {
        guard let data = try? JSONEncoder().encode(cursors) else { return }
        let tmpPath = filePath + ".tmp"
        let fileURL = URL(fileURLWithPath: filePath)
        let tmpURL = URL(fileURLWithPath: tmpPath)
        do {
            try data.write(to: tmpURL)
            if FileManager.default.fileExists(atPath: filePath) {
                // 原子替换（目标已存在）
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                // 首次保存：直接 rename
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            // 降级：直接覆盖写
            try? data.write(to: fileURL)
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }

    /// 获取指定 session 的游标
    func cursor(for sessionId: String) -> CursorState {
        cursors[sessionId] ?? .initial
    }

    /// 更新指定 session 的游标
    func update(_ sessionId: String, cursor: CursorState) {
        cursors[sessionId] = cursor
    }

    /// 清理指定 session 的游标
    func remove(_ sessionId: String) {
        cursors.removeValue(forKey: sessionId)
    }

    /// 清空所有游标
    func removeAll() {
        cursors.removeAll()
    }
}

// MARK: - Session File Watcher（per-session DispatchSource）

/// 单个 session 的 JSONL 文件监听器
///
/// 使用 DispatchSource vnode 监听 `.write` 事件，2 秒 debounce 合并连续写入。
/// 作为 AICliKit event 的保底机制：当事件未触发时（边缘场景）也能捕获变化。
/// 游标幂等保证双触发（AICliKit + file watch）不会重复推送。
final class SessionFileWatcher {
    let sessionId: String
    let path: String

    /// debounce + source 状态统一由 watchQueue 保护，消除 data race
    private var source: DispatchSourceFileSystemObject?
    private var debounceItem: DispatchWorkItem?  // 只在 watchQueue 上访问
    private let fileDescriptor: Int32
    private let onChange: (String, String) -> Void  // (sessionId, path)

    /// debounce 间隔（秒），合并 Claude Code 连续写入
    private static let debounceInterval: TimeInterval = 2.0

    /// 监听队列（utility QoS，避免阻塞主线程）
    /// 同时保护 debounceItem 的读写，消除与 stop() 的 data race
    private static let watchQueue = DispatchQueue(
        label: "com.eterm.vlaude.filewatcher",
        qos: .utility
    )

    /// 初始化文件监听器
    ///
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - path: JSONL 文件路径
    ///   - onChange: 文件变化回调（debounce 后，在主线程调用）
    init?(sessionId: String, path: String, onChange: @escaping (String, String) -> Void) {
        self.sessionId = sessionId
        self.path = path
        self.onChange = onChange

        // 打开文件描述符（只读，用于 vnode 监听）
        let fd = open(path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else {
            logWarn("[VlaudeKit] FileWatcher: 无法打开文件 \(path)")
            return nil
        }
        self.fileDescriptor = fd

        // 创建 DispatchSource 监听 .write 事件
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: Self.watchQueue
        )

        source.setEventHandler { [weak self] in
            self?.handleWriteEvent()
        }

        source.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = source
        source.resume()
    }

    deinit {
        stop()
    }

    /// 停止监听并释放资源
    ///
    /// source.cancel() 阻止新事件产生，debounceItem 异步取消避免同队列死锁。
    /// 即使 debounceItem 延迟取消，onChange 回调有 fileWatchers[sessionId] != nil 守卫。
    func stop() {
        // source.cancel() 是线程安全的，阻止后续事件
        if let source = source {
            source.cancel()
            self.source = nil
        }

        // S2: async 替代 sync，避免 deinit 从 watchQueue 调用时死锁
        let pendingItem = debounceItem
        debounceItem = nil
        Self.watchQueue.async {
            pendingItem?.cancel()
        }
    }

    /// 处理 vnode write 事件（在 watchQueue 上调用）
    private func handleWriteEvent() {
        // 取消前一个 debounce，重新计时
        debounceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 回到主线程触发回调（与 AICliKit event 汇合点一致）
            DispatchQueue.main.async {
                self.onChange(self.sessionId, self.path)
            }
        }
        debounceItem = item

        // 延迟 2 秒执行
        Self.watchQueue.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: item
        )
    }
}

@objc(VlaudePlugin)
public final class VlaudePlugin: NSObject, Plugin {
    public static var id = "com.eterm.vlaude"

    private weak var host: HostBridge?
    private var client: VlaudeClient?

    /// Session 文件路径映射：sessionId -> transcriptPath
    /// 注意：session ↔ terminal 映射由 ClaudeKit 的 ClaudeSessionMapper 维护
    private var sessionPaths: [String: String] = [:]

    /// 待上报的创建请求：terminalId -> (requestId, projectPath)
    private var pendingRequests: [Int: (requestId: String, projectPath: String)] = [:]

    /// Mobile 正在查看的 terminal ID 集合
    private var mobileViewingTerminals: Set<Int> = []

    /// 正在 loading（Claude 思考中）的 session 集合
    private var loadingSessions: Set<String> = []

    /// 待处理的 clientMessageId：sessionId -> clientMessageId
    /// 当收到 iOS 发送的消息注入请求时存储，推送 user 消息时携带并清除
    private var pendingClientMessageIds: [String: String] = [:]

    /// 待标记为 pending 的审批请求：toolUseId -> (sessionId, timestamp)
    /// 当收到 permissionPrompt 时存储，等待 Agent 推送消息后标记为 pending
    private var pendingApprovals: [String: (sessionId: String, timestamp: Int64)] = [:]

    /// Agent Client（用于接收 Agent 推送的事件）
    private var agentClient: AgentClientBridge?

    /// Session 消息读取器
    private let sessionReader = SessionReader()

    /// [V2 新链路] 游标持久化存储
    private let cursorStore = CursorStore()

    /// Shared database bridge (用于权限持久化)
    private var dbBridge: SharedDbBridge?

    /// 配置变更观察
    private var configObserver: NSObjectProtocol?

    /// 重连请求观察
    private var reconnectObserver: NSObjectProtocol?

    /// [V2] 文件监听器：sessionId -> SessionFileWatcher
    private var fileWatchers: [String: SessionFileWatcher] = [:]

    /// 防止同一 session 并发采集推送
    private var collectInFlight: Set<String> = []
    /// 待处理的采集请求（当调用进行中时，记录最新的 transcriptPath 等完成后重试）
    private var collectPending: [String: String] = [:]  // sessionId -> transcriptPath

    public override required init() {
        super.init()
    }

    // MARK: - Plugin Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 设置 Rust 日志回调（将日志转发到 LogManager）
        setupVlaudeLogCallback()

        // 初始化客户端（使用 Rust FFI）
        client = VlaudeClient()
        client?.delegate = self

        // 在后台线程初始化 AgentClient 和 SharedDbBridge（FFI 调用会阻塞）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.initAgentRPC()
            self?.initializeSharedDb()
        }

        // 监听配置变更
        configObserver = NotificationCenter.default.addObserver(
            forName: .vlaudeConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigChange()
            }
        }

        // 监听重连请求
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .vlaudeReconnectRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleReconnectRequest()
            }
        }

        // 如果配置有效，立即连接
        connectIfConfigured()

        // [V2] 冷启动全量扫描：补偿停机期间遗漏的消息
        performColdStartScan()
    }

    /// 初始化 SharedDbBridge（在后台线程调用，只读模式）
    ///
    /// 所有写入操作通过 AgentClient 进行，SharedDbBridge 仅用于查询。
    private nonisolated func initializeSharedDb() {
        do {
            let db = try SharedDbBridge()

            // 回到主线程设置状态
            DispatchQueue.main.async { [weak self] in
                self?.dbBridge = db
                logInfo("[VlaudeKit] SharedDbBridge 初始化成功")
            }
        } catch {
            DispatchQueue.main.async {
                logWarn("[VlaudeKit] SharedDbBridge 初始化失败: \(error)")
            }
        }
    }

    /// [V2] 初始化 Agent RPC 连接（仅连接，不订阅事件）
    private nonisolated func initAgentRPC() {
        DispatchQueue.main.sync { [weak self] in
            self?.agentClient?.disconnect()
            self?.agentClient = nil
        }

        do {
            let pluginBundle = Bundle(for: VlaudePlugin.self)
            let client = try AgentClientBridge(component: "vlaudekit", bundle: pluginBundle)
            try client.connect()
            // [V2] 不再订阅事件，不设置 delegate。仅保留 RPC 连接。

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.agentClient = client
                logInfo("[VlaudeKit] Agent RPC 已连接（仅 writeApproveResult + notifyFileChange）")
            }
        } catch {
            DispatchQueue.main.async {
                logWarn("[VlaudeKit] Agent RPC 初始化失败: \(error)")
            }
        }
    }

    public func deactivate() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = reconnectObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // [V2] 停止所有文件监听器
        removeAllFileWatchers()

        // [V2] 持久化游标
        cursorStore.save()

        // 断开 AgentClient
        agentClient?.disconnect()
        agentClient = nil

        client?.disconnect()
        client = nil

        // 更新状态
        VlaudeConfigManager.shared.updateConnectionStatus(.disconnected)

        // 映射由 ClaudeKit 维护，这里只清理 VlaudeKit 本地状态
        // sessionPaths 保留，重连后还能用
        pendingRequests.removeAll()
        mobileViewingTerminals.removeAll()
        loadingSessions.removeAll()
        pendingClientMessageIds.removeAll()
    }

    // MARK: - Configuration

    private func connectIfConfigured() {
        let config = VlaudeConfigManager.shared.config
        guard config.isValid else { return }
        VlaudeConfigManager.shared.updateConnectionStatus(.connecting)
        // FFI 连接操作会阻塞，在后台线程执行
        let client = self.client
        DispatchQueue.global(qos: .utility).async {
            client?.connect(config: config)
        }
    }

    private func handleConfigChange() {
        let config = VlaudeConfigManager.shared.config

        if config.isValid {
            VlaudeConfigManager.shared.updateConnectionStatus(.connecting)
            // FFI 连接操作会阻塞，在后台线程执行
            let client = self.client
            DispatchQueue.global(qos: .utility).async {
                client?.connect(config: config)
            }
        } else {
            client?.disconnect()
            VlaudeConfigManager.shared.updateConnectionStatus(.disconnected)
        }
    }

    private func handleReconnectRequest() {
        let config = VlaudeConfigManager.shared.config
        guard config.isValid else { return }
        VlaudeConfigManager.shared.updateConnectionStatus(.reconnecting)
        // FFI 连接操作会阻塞，在后台线程执行
        let client = self.client
        DispatchQueue.global(qos: .utility).async {
            client?.reconnect()
        }
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "aicli.sessionStart":
            handleClaudeSessionStart(payload)

        case "aicli.promptSubmit":
            handleClaudePromptSubmit(payload)

        case "aicli.responseComplete":
            handleClaudeResponseComplete(payload)

        case "aicli.sessionEnd":
            handleClaudeSessionEnd(payload)

        case "aicli.permissionRequest":
            handleClaudePermissionPrompt(payload)

        case "terminal.didClose":
            handleTerminalClosed(payload)

        default:
            break
        }
    }

    private func handleClaudeSessionStart(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String,
              let transcriptPath = payload["transcriptPath"] as? String else { return }

        // 映射由 ClaudeKit 的 ClaudeSessionMapper 维护，这里只保存 transcriptPath
        sessionPaths[sessionId] = transcriptPath

        // [V2] 尽早持久化 transcriptPath，确保冷启动恢复覆盖（S1 fix）
        // 即使后续没有触发 collectAndPushNewMessages，cursor 中也有路径记录
        var cursor = cursorStore.cursor(for: sessionId)
        if cursor.transcriptPath == nil {
            cursor.transcriptPath = transcriptPath
            cursorStore.update(sessionId, cursor: cursor)
            cursorStore.save()
        }

        // [V2] 安装文件监听器（保底机制）
        installFileWatcher(sessionId: sessionId, path: transcriptPath)

        // 发送 daemon:sessionStart 事件（更新 StatusManager，iOS 显示在线状态）
        let projectPath = payload["cwd"] as? String ?? ""
        client?.emitSessionStart(sessionId: sessionId, projectPath: projectPath, terminalId: terminalId)
    }

    private func handleClaudePromptSubmit(_ payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String else { return }
        // 标记为 loading
        loadingSessions.insert(sessionId)

        // [V3] 通知 agent 采集 → 从 DB 读取新消息 → 推送到 iOS
        if let transcriptPath = payload["transcriptPath"] as? String,
           !transcriptPath.isEmpty {
            collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
        } else if let transcriptPath = sessionPaths[sessionId] {
            collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
        }
    }

    private func handleClaudeResponseComplete(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else { return }

        // 清除 loading 状态
        loadingSessions.remove(sessionId)

        // 检查是否有旧的 sessionPaths 需要清理（session 改变的情况）
        // 先收集要清理的 sessionId，避免迭代时修改字典
        let sessionsToClean = sessionPaths.keys.filter { oldSessionId in
            oldSessionId != sessionId &&
            getTerminalId(for: oldSessionId) == terminalId
        }
        for oldSessionId in sessionsToClean {
            sessionPaths.removeValue(forKey: oldSessionId)
            removeFileWatcher(sessionId: oldSessionId)
            client?.emitSessionEnd(sessionId: oldSessionId)
        }

        // 更新 transcriptPath
        if let transcriptPath = payload["transcriptPath"] as? String {
            let isNewSession = sessionPaths[sessionId] == nil
            sessionPaths[sessionId] = transcriptPath

            // 如果是新 session，发送 daemon:sessionStart 事件 + 安装 watcher
            if isNewSession {
                let projectPath = payload["cwd"] as? String ?? ""
                client?.emitSessionStart(sessionId: sessionId, projectPath: projectPath, terminalId: terminalId)
                installFileWatcher(sessionId: sessionId, path: transcriptPath)
            }
        }

        // 检查是否有待上报的 requestId
        if let pending = pendingRequests.removeValue(forKey: terminalId) {
            let encodedDirName = payload["encodedDirName"] as? String
            let transcriptPath = payload["transcriptPath"] as? String

            client?.emitSessionCreatedResult(
                requestId: pending.requestId,
                success: true,
                sessionId: sessionId,
                encodedDirName: encodedDirName,
                transcriptPath: transcriptPath
            )
        }

        // [V3] 通知 agent 采集 → 从 DB 读取新消息 → 推送到 iOS
        if let transcriptPath = payload["transcriptPath"] as? String {
            collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
        }
    }

    private func handleClaudeSessionEnd(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String else { return }

        // 注意：ClaudeKit 先清理映射再 emit 事件，所以这里不能依赖 getSessionId()
        // 直接使用 payload 中的 sessionId 进行清理

        // [V3] 最终 drain：在清理前推送剩余消息
        if let transcriptPath = cursorStore.cursor(for: sessionId).transcriptPath
            ?? sessionPaths[sessionId] {
            collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
        }

        // 清理本地数据（映射由 ClaudeKit 维护）
        sessionPaths.removeValue(forKey: sessionId)
        pendingRequests.removeValue(forKey: terminalId)

        // [V2] 移除文件监听器
        removeFileWatcher(sessionId: sessionId)

        // [V2] 持久化游标（session 结束时保存，不删除，支持历史回看）
        cursorStore.save()

        // 发送 daemon:sessionEnd 事件（通知 StatusManager session 结束）
        client?.emitSessionEnd(sessionId: sessionId)
    }

    private func handleTerminalClosed(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int else {
            return
        }

        // 无论是否有 sessionId，都要清理 terminalId 相关的状态
        pendingRequests.removeValue(forKey: terminalId)
        mobileViewingTerminals.remove(terminalId)

        // 注意：ClaudeKit 可能已经清理了映射，所以不能依赖 getSessionId()
        // 从本地 sessionPaths 中查找属于这个 terminal 的 session
        // 需要遍历 sessionPaths，通过 getTerminalId 找到匹配的 session
        // 但 getTerminalId 也依赖 ClaudeKit 映射，所以这里需要用 payload 中的 sessionId（如果有）
        // 或者从 sessionPaths 中根据已知信息清理

        // 尝试从 payload 获取 sessionId
        if let sessionId = payload["sessionId"] as? String {
            // [V3] 最终 drain：终端关闭前推送剩余消息
            if let transcriptPath = cursorStore.cursor(for: sessionId).transcriptPath
                ?? sessionPaths[sessionId] {
                collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
            }
            sessionPaths.removeValue(forKey: sessionId)
            removeFileWatcher(sessionId: sessionId)
            client?.emitSessionEnd(sessionId: sessionId)
        } else {
            // payload 中没有 sessionId，尝试从 sessionPaths 中查找
            // 这种情况下映射可能还存在
            if let sessionId = getSessionId(for: terminalId) {
                // [V3] 最终 drain
                if let transcriptPath = cursorStore.cursor(for: sessionId).transcriptPath
                    ?? sessionPaths[sessionId] {
                    collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
                }
                sessionPaths.removeValue(forKey: sessionId)
                removeFileWatcher(sessionId: sessionId)
                client?.emitSessionEnd(sessionId: sessionId)
            }
        }
    }

    private func handleClaudePermissionPrompt(_ payload: [String: Any]) {
        guard let terminalId = payload["terminalId"] as? Int,
              let sessionId = payload["sessionId"] as? String,
              let toolName = payload["toolName"] as? String,
              let toolInput = payload["toolInput"] as? [String: Any] else {
            return
        }

        let toolUseId = payload["toolUseId"] as? String ?? ""

        // 1. 先存储到 pendingApprovals（等待 Agent 推送消息后标记为 pending）
        if !toolUseId.isEmpty {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            pendingApprovals[toolUseId] = (sessionId: sessionId, timestamp: now)
        }

        // 2. 推送权限请求给 iOS
        var toolUseInfo: [String: Any] = [
            "name": toolName,
            "input": toolInput
        ]

        if !toolUseId.isEmpty {
            toolUseInfo["id"] = toolUseId
        }

        client?.emitPermissionRequest(
            sessionId: sessionId,
            terminalId: terminalId,
            message: payload["message"] as? String,
            toolUse: toolUseInfo
        )

        // [V3] 通知 agent 采集 → 从 DB 读取新消息 → 推送到 iOS
        if let transcriptPath = payload["transcriptPath"] as? String,
           !transcriptPath.isEmpty {
            collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
        } else if let transcriptPath = sessionPaths[sessionId] {
            collectAndPushNewMessages(sessionId: sessionId, transcriptPath: transcriptPath)
        }
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令
    }

    // MARK: - ClaudeKit 服务调用

    /// 通过 ClaudeKit 服务查询 sessionId -> terminalId 映射
    private func getTerminalId(for sessionId: String) -> Int? {
        guard let host = host else { return nil }
        guard let result = host.callService(
            pluginId: "com.eterm.claude",
            name: "getTerminalId",
            params: ["sessionId": sessionId]
        ) else { return nil }
        return result["terminalId"] as? Int
    }

    /// 通过 ClaudeKit 服务查询 terminalId -> sessionId 映射
    private func getSessionId(for terminalId: Int) -> String? {
        guard let host = host else { return nil }
        guard let result = host.callService(
            pluginId: "com.eterm.claude",
            name: "getSessionId",
            params: ["terminalId": terminalId]
        ) else { return nil }
        return result["sessionId"] as? String
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        guard tabId == "vlaude-settings" else { return nil }
        return AnyView(VlaudeSettingsView())
    }

    public func bottomDockView(for id: String) -> AnyView? {
        nil
    }

    public func infoPanelView(for id: String) -> AnyView? {
        nil
    }

    public func bubbleView(for id: String) -> AnyView? {
        nil
    }

    public func menuBarView() -> AnyView? {
        nil
    }

    public func pageBarView(for itemId: String) -> AnyView? {
        nil
    }

    public func windowBottomOverlayView(for id: String) -> AnyView? {
        nil
    }

    public func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
        guard slotId == "vlaude-mobile-viewing" else { return nil }
        guard let terminalId = tab.terminalId else { return nil }
        guard mobileViewingTerminals.contains(terminalId) else { return nil }

        return AnyView(
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .help("Mobile 正在查看")
        )
    }

    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        nil
    }

    // MARK: - [V2] File Watcher Management

    /// 安装文件监听器（幂等：已存在则跳过）
    ///
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - path: JSONL 文件路径
    private func installFileWatcher(sessionId: String, path: String) {
        dispatchPrecondition(condition: .onQueue(.main))

        // 已有同路径的 watcher，跳过
        if let existing = fileWatchers[sessionId], existing.path == path {
            return
        }

        // 路径变更：先移除旧 watcher
        removeFileWatcher(sessionId: sessionId)

        // 创建新 watcher
        guard let watcher = SessionFileWatcher(
            sessionId: sessionId,
            path: path,
            onChange: { [weak self] watchedSessionId, watchedPath in
                guard let self = self else { return }
                // stop() 后 debounceItem 已入队的回调可能仍会触发，校验 watcher 是否仍存活
                guard self.fileWatchers[watchedSessionId] != nil else { return }
                self.collectAndPushNewMessages(sessionId: watchedSessionId, transcriptPath: watchedPath)
            }
        ) else {
            return
        }

        fileWatchers[sessionId] = watcher
        logInfo("[VlaudeKit] FileWatcher 已安装: \(sessionId)")
    }

    /// 移除指定 session 的文件监听器
    private func removeFileWatcher(sessionId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let watcher = fileWatchers.removeValue(forKey: sessionId) else { return }
        watcher.stop()
        logInfo("[VlaudeKit] FileWatcher 已移除: \(sessionId)")
    }

    /// 移除所有文件监听器（deactivate 时调用）
    private func removeAllFileWatchers() {
        dispatchPrecondition(condition: .onQueue(.main))
        for (_, watcher) in fileWatchers {
            watcher.stop()
        }
        fileWatchers.removeAll()
        logInfo("[VlaudeKit] 所有 FileWatcher 已移除")
    }

    // MARK: - [V3] Cold Start Scan

    /// 冷启动全量扫描：恢复持久化游标并补推遗漏消息
    ///
    /// 在 activate() 中调用，处理 VlaudeKit 停机期间的文件变化：
    /// 1. 遍历 cursors.json 中所有有 transcriptPath 的游标
    /// 2. 对每个 session 调用 collectAndPushNewMessages（通知 agent 采集 + 从 DB 读）
    /// 3. 为仍然存在的文件安装 file watcher
    private func performColdStartScan() {
        let cursors = cursorStore.cursors
        guard !cursors.isEmpty else { return }

        var sessionsToSync: [(sessionId: String, path: String)] = []

        for (sessionId, cursor) in cursors {
            guard let transcriptPath = cursor.transcriptPath else { continue }
            guard FileManager.default.fileExists(atPath: transcriptPath) else { continue }
            sessionsToSync.append((sessionId, transcriptPath))
        }

        guard !sessionsToSync.isEmpty else { return }

        for session in sessionsToSync {
            // 恢复 sessionPaths 映射
            sessionPaths[session.sessionId] = session.path

            // 通知 agent 采集 + 从 DB 读取 + 推送
            collectAndPushNewMessages(sessionId: session.sessionId, transcriptPath: session.path)

            // 安装 file watcher
            installFileWatcher(sessionId: session.sessionId, path: session.path)
        }

        logInfo("[VlaudeKit] 冷启动扫描: \(sessionsToSync.count) 个 session")
    }
}

// MARK: - VlaudeClientDelegate

extension VlaudePlugin: VlaudeClientDelegate {
    func vlaudeClientDidConnect(_ client: VlaudeClient) {
        // 更新连接状态
        VlaudeConfigManager.shared.updateConnectionStatus(.connected)

        // 连接成功后，上报所有已存在的 session（StatusManager 架构）
        // 遍历 sessionPaths，通过 ClaudeKit 服务查询 terminalId
        var reportedCount = 0
        for sessionId in sessionPaths.keys {
            guard let terminalId = getTerminalId(for: sessionId) else { continue }
            let projectPath = host?.getTerminalInfo(terminalId: terminalId)?.cwd ?? ""
            client.emitSessionStart(sessionId: sessionId, projectPath: projectPath, terminalId: terminalId)
            reportedCount += 1
        }

    }

    func vlaudeClientDidDisconnect(_ client: VlaudeClient) {
        // 如果正在重连中，不要覆盖状态（避免 .reconnecting -> .disconnected 闪烁）
        let currentStatus = VlaudeConfigManager.shared.connectionStatus
        if currentStatus != .reconnecting {
            VlaudeConfigManager.shared.updateConnectionStatus(.disconnected)
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveInject sessionId: String, text: String, clientMessageId: String?) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            return
        }

        // 存储 clientMessageId，等待 Agent 推送 user 消息后一起推送
        if let clientMsgId = clientMessageId {
            pendingClientMessageIds[sessionId] = clientMsgId
        }

        // 写入终端
        host?.writeToTerminal(terminalId: terminalId, data: text)

        // 延迟发送回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveMobileViewing sessionId: String, isViewing: Bool) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            return
        }

        // 更新状态
        if isViewing {
            mobileViewingTerminals.insert(terminalId)
        } else {
            mobileViewingTerminals.remove(terminalId)
        }

        // 触发 UI 刷新
        // SDK 插件通过 updateViewModel 触发刷新
        host?.updateViewModel(Self.id, data: ["mobileViewingChanged": true])
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?) {
        // 旧方式：不支持
    }

    // MARK: - 新 WebSocket 事件处理

    func vlaudeClient(_ client: VlaudeClient, didReceiveCreateSessionNew projectPath: String, prompt: String?, requestId: String) {
        guard let host = host else {
            client.emitSessionCreatedResult(requestId: requestId, success: false, error: "Host not available")
            return
        }

        // 1. 创建终端 Tab
        guard let terminalId = host.createTerminalTab(cwd: projectPath) else {
            client.emitSessionCreatedResult(requestId: requestId, success: false, error: "Failed to create terminal")
            return
        }

        // 2. 保存 pending 请求，等待 claude.responseComplete 事件
        pendingRequests[terminalId] = (requestId: requestId, projectPath: projectPath)

        // 3. 启动 Claude（延迟等待终端准备好）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            let command: String
            if let prompt = prompt, !prompt.isEmpty {
                // 转义 prompt 中的特殊字符
                let escapedPrompt = prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                command = "claude -p \"\(escapedPrompt)\""
            } else {
                command = "claude"
            }

            self.host?.writeToTerminal(terminalId: terminalId, data: command + "\n")
        }

        // 4. 设置超时（60秒），如果 session 没有创建则报告失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self else { return }

            // 如果还在 pending 中，说明超时了
            if self.pendingRequests[terminalId] != nil {
                self.pendingRequests.removeValue(forKey: terminalId)
                client.emitSessionCreatedResult(requestId: requestId, success: false, error: "Timeout waiting for session")
            }
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveSendMessage sessionId: String, text: String, projectPath: String?, clientId: String?, requestId: String) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            client.emitSendMessageResult(requestId: requestId, success: false, message: "Session not in ETerm")
            return
        }

        // 写入终端
        host?.writeToTerminal(terminalId: terminalId, data: text)

        // 延迟发送回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")
            client.emitSendMessageResult(requestId: requestId, success: true, via: "eterm")
        }
    }

    func vlaudeClient(_ client: VlaudeClient, didReceiveCheckLoading sessionId: String, projectPath: String?, requestId: String) {
        let isLoading = loadingSessions.contains(sessionId)
        client.emitCheckLoadingResult(requestId: requestId, loading: isLoading)
    }

    func vlaudeClient(_ client: VlaudeClient, didReceivePermissionResponse sessionId: String, action: String, toolUseId: String) {
        guard let terminalId = getTerminalId(for: sessionId) else {
            // 即使找不到终端，也发送失败的 ack
            if !toolUseId.isEmpty {
                client.emitApprovalAck(toolUseId: toolUseId, sessionId: sessionId, success: false, message: "终端未找到")
            }
            return
        }

        // 解析 action 为审批状态
        let status: ApprovalStatusC
        if action.hasPrefix("y") || action.hasPrefix("a") {
            status = Approved
        } else if action.hasPrefix("n") {
            status = Rejected
        } else {
            status = Rejected  // 默认拒绝
        }

        // 1. 写回 DB（通过 AgentClient，后台执行避免阻塞主线程）
        if let agentClient = agentClient, !toolUseId.isEmpty {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            DispatchQueue.global(qos: .utility).async {
                do {
                    try agentClient.writeApproveResult(
                        toolCallId: toolUseId,
                        status: status,
                        resolvedAt: now
                    )
                } catch {
                    print("[VlaudeKit] 更新审批状态失败: \(error)")
                }
            }
        }

        // 2. 写入终端（action 可以是 y/n/a 或 "n: 理由"）
        host?.writeToTerminal(terminalId: terminalId, data: action)

        // 延迟发送回车，然后发送 ack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.writeToTerminal(terminalId: terminalId, data: "\r")

            // 发送 approval-ack 通知 iOS
            if !toolUseId.isEmpty {
                client.emitApprovalAck(toolUseId: toolUseId, sessionId: sessionId, success: true)
            }
        }
    }
}

// MARK: - [V3] DB-Based Message Push

extension VlaudePlugin {
    /// [V3] 通知 agent 采集 → 从 DB 读取新消息 → 推送到 iOS
    ///
    /// 正确的数据流：Kit 通知 agent 采集 JSONL → agent 写 DB → Kit 从 DB 读 → 推 iOS
    /// 替代旧的 JSONL 直读链路，保证数据完整性（包含 stopReason、turn_duration 等）
    func collectAndPushNewMessages(sessionId: String, transcriptPath: String) {
        dispatchPrecondition(condition: .onQueue(.main))

        // 已有调用在执行中 → 标记 pending，等当前调用完成后自动重试
        if collectInFlight.contains(sessionId) {
            collectPending[sessionId] = transcriptPath
            return
        }
        collectInFlight.insert(sessionId)

        // 确保 sessionPaths 有记录
        if sessionPaths[sessionId] == nil {
            sessionPaths[sessionId] = transcriptPath
        }

        // 读取当前游标（main queue）
        let currentOffset = cursorStore.cursor(for: sessionId).messagesRead

        // 后台执行：notify agent + read DB
        let agentClient = self.agentClient
        let dbBridge = self.dbBridge

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 1. 通知 agent 采集（同步 RPC，阻塞直到采集完成）
            do {
                try agentClient?.notifyFileChange(path: transcriptPath)
            } catch {
                DispatchQueue.main.async {
                    logWarn("[VlaudeKit] notifyFileChange 失败: \(error)")
                }
                // 继续尝试读 DB（可能有之前采集的数据）
            }

            // 2. 从 DB 读取新消息
            guard let dbBridge = dbBridge else {
                DispatchQueue.main.async { [weak self] in
                    logWarn("[VlaudeKit] DB 未初始化，跳过推送")
                    guard let self = self else { return }
                    self.collectInFlight.remove(sessionId)
                    if let pendingPath = self.collectPending.removeValue(forKey: sessionId) {
                        self.collectAndPushNewMessages(sessionId: sessionId, transcriptPath: pendingPath)
                    }
                }
                return
            }

            let dbMessages: [SharedMessage]
            do {
                dbMessages = try dbBridge.listMessages(sessionId: sessionId, limit: 500, offset: currentOffset)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    logWarn("[VlaudeKit] DB 读取失败: \(error)")
                    guard let self = self else { return }
                    self.collectInFlight.remove(sessionId)
                    if let pendingPath = self.collectPending.removeValue(forKey: sessionId) {
                        self.collectAndPushNewMessages(sessionId: sessionId, transcriptPath: pendingPath)
                    }
                }
                return
            }

            guard !dbMessages.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.collectInFlight.remove(sessionId)
                    if let pendingPath = self.collectPending.removeValue(forKey: sessionId) {
                        self.collectAndPushNewMessages(sessionId: sessionId, transcriptPath: pendingPath)
                    }
                }
                return
            }

            // 3. 转换 SharedMessage → RawMessage（解析 raw 字段提取 V2 字段）
            let rawMessages = dbMessages.compactMap { msg -> RawMessage? in
                Self.convertToRawMessage(msg, sessionId: sessionId)
            }

            guard !rawMessages.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.collectInFlight.remove(sessionId)
                    if let pendingPath = self.collectPending.removeValue(forKey: sessionId) {
                        self.collectAndPushNewMessages(sessionId: sessionId, transcriptPath: pendingPath)
                    }
                }
                return
            }

            // 4. 回主线程推送 + 更新游标
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                defer {
                    self.collectInFlight.remove(sessionId)
                    // 如果有待处理的请求，立即重新触发
                    if let pendingPath = self.collectPending.removeValue(forKey: sessionId) {
                        self.collectAndPushNewMessages(sessionId: sessionId, transcriptPath: pendingPath)
                    }
                }

                let allPushed = self.processNewMessages(rawMessages, for: sessionId, transcriptPath: transcriptPath)

                if allPushed {
                    var cursor = self.cursorStore.cursor(for: sessionId)
                    cursor.messagesRead = currentOffset + dbMessages.count
                    cursor.transcriptPath = transcriptPath
                    self.cursorStore.update(sessionId, cursor: cursor)
                    self.cursorStore.save()
                } else {
                    logWarn("[VlaudeKit] 部分消息推送失败，游标不前进: \(sessionId)")
                    // 确保 transcriptPath 已持久化（冷启动恢复用）
                    var cursor = self.cursorStore.cursor(for: sessionId)
                    if cursor.transcriptPath == nil {
                        cursor.transcriptPath = transcriptPath
                        self.cursorStore.update(sessionId, cursor: cursor)
                        self.cursorStore.save()
                    }
                }
            }
        }
    }

    /// 将 DB 消息转换为 RawMessage（解析 raw JSONL 提取 V2 字段）
    private nonisolated static func convertToRawMessage(_ msg: SharedMessage, sessionId: String) -> RawMessage? {
        let messageType = msg.role == "human" ? 0 : 1

        // 从 raw 字段解析 V2 字段
        var requestId: String? = nil
        var stopReason: String? = nil
        var eventType: String? = nil
        var agentId: String? = nil

        if let raw = msg.raw,
           let rawData = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {

            requestId = json["requestId"] as? String
            agentId = json["agentId"] as? String

            // stop_reason 在 message.stop_reason（Claude Code JSONL 通常为 null，需推断）
            if let message = json["message"] as? [String: Any] {
                stopReason = message["stop_reason"] as? String

                // JSONL 不写 stop_reason，从 content 推断：有 tool_use → "tool_use"，否则 → "end_turn"
                if stopReason == nil, messageType == 1,
                   let content = message["content"] as? [[String: Any]] {
                    let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
                    stopReason = hasToolUse ? "tool_use" : "end_turn"
                }
            }

            // 推断 eventType
            if messageType == 0 {
                if json["toolUseResult"] != nil {
                    eventType = "tool_result"
                } else {
                    eventType = "user_text"
                }
            } else {
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    let types = content.compactMap { $0["type"] as? String }
                    if types.contains("tool_use") {
                        eventType = "tool_use"
                    } else if types.contains("thinking") {
                        eventType = "thinking"
                    } else {
                        eventType = types.first
                    }
                }
            }
        }

        return RawMessage(
            uuid: msg.uuid,
            sessionId: sessionId,
            messageType: messageType,
            content: msg.content,
            timestamp: msg.timestamp > 0 ? String(msg.timestamp) : nil,
            requestId: requestId,
            stopReason: stopReason,
            eventType: eventType,
            agentId: agentId
        )
    }
}

// MARK: - Message Processing

extension VlaudePlugin {
    /// 统一处理新消息（由 V2 增量读取调用）
    /// - Returns: 所有消息是否成功推送（用于游标协议：失败时不前进游标）
    @discardableResult
    func processNewMessages(
        _ messages: [RawMessage],
        for sessionId: String,
        transcriptPath: String
    ) -> Bool {
        var allSuccess = true
        for message in messages {
            // V2: 跳过空 text 占位符（Opus 4.6 产生的 "\n\n"）
            if message.messageType == 1, message.eventType == "text" {
                let blocks = ContentBlockParser.parseContentBlocks(
                    from: message.content, messageType: 1, eventType: message.eventType
                )
                let isEmpty = blocks?.allSatisfy { block in
                    if case .text(let t) = block {
                        return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return false
                } ?? true
                if isEmpty { continue }
            }

            // 检查是否有待标记为 pending 的审批请求
            // 从 message.content 中轻量级提取 tool_use id（不解析整个文件）
            if !pendingApprovals.isEmpty {
                let toolUseIds = extractToolUseIds(from: message.content)
                for toolCallId in toolUseIds {
                    if pendingApprovals[toolCallId] != nil {
                        // 标记为 pending（通过 AgentClient，后台执行避免阻塞主线程）
                        if let agentClient = agentClient {
                            DispatchQueue.global(qos: .utility).async {
                                do {
                                    try agentClient.writeApproveResult(
                                        toolCallId: toolCallId,
                                        status: Pending,
                                        resolvedAt: 0  // pending 状态时为 0
                                    )
                                } catch {
                                    logError("[VlaudeKit] 标记 pending 失败: \(error)")
                                }
                            }
                        }
                        // 移除已处理的待审批项
                        pendingApprovals.removeValue(forKey: toolCallId)
                    }
                }
            }

            // 对于 user 类型消息，携带 clientMessageId（如果有）
            var clientMsgId: String? = nil
            if message.type == "user" {
                // 取出并消费 clientMessageId（一次性使用）
                clientMsgId = pendingClientMessageIds.removeValue(forKey: sessionId)
            }

            // 解析结构化内容块（用于 iOS 正确渲染 tool_use 等）
            let contentBlocks = ContentBlockParser.parseContentBlocks(
                from: message.content,
                messageType: message.messageType,
                eventType: message.eventType
            )

            // 生成预览文本（用于列表页实时更新）
            let preview = ContentBlockParser.generatePreview(
                content: message.content,
                messageType: message.messageType
            )

            let pushed = client?.pushMessage(sessionId: sessionId, message: message, contentBlocks: contentBlocks, preview: preview, clientMessageId: clientMsgId) ?? false
            if !pushed { allSuccess = false }
        }
        return allSuccess
    }

    /// 从 message content 中轻量级提取 tool_use id（不读取文件）
    private func extractToolUseIds(from content: String) -> [String] {
        // tool_use 格式: {"type": "tool_use", "id": "toolu_xxx", ...}
        // 用正则提取 id，避免完整 JSON 解析
        var ids: [String] = []
        let pattern = #""type"\s*:\s*"tool_use"[^}]*"id"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ids
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        for match in matches {
            if let idRange = Range(match.range(at: 1), in: content) {
                ids.append(String(content[idRange]))
            }
        }
        return ids
    }
}


// MARK: - Rust Log Bridge

/// 设置 VlaudeKit Rust 日志回调
private func setupVlaudeLogCallback() {
    let callback: @convention(c) (VlaudeLogLevel, UnsafePointer<CChar>?) -> Void = { level, message in
        guard let message = message else { return }
        let text = String(cString: message)

        // 根据日志级别转发到 LogManager
        switch level {
        case DEBUG:
            LogManager.shared.debug(text)
        case INFO:
            LogManager.shared.info(text)
        case WARN:
            LogManager.shared.warn(text)
        case ERROR:
            LogManager.shared.error(text)
        default:
            LogManager.shared.info(text)
        }
    }

    vlaude_set_log_callback(callback)
}
