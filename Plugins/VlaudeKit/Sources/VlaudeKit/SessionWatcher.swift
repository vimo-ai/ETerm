//
//  SessionWatcher.swift
//  VlaudeKit
//
//  DispatchSource 文件监听 + 增量解析 + 目录监听（等待文件创建）
//
//  职责：
//  - 使用 GCD DispatchSource 监听 transcript 文件变化
//  - 增量读取新消息（只读取 lastOffset 之后的内容）
//  - 通知 delegate 处理新消息
//  - 目录监听：文件不存在时，监听目录等待文件创建
//

import Foundation

// MARK: - SessionWatcherDelegate

protocol SessionWatcherDelegate: AnyObject {
    /// 收到新消息
    /// - Parameters:
    ///   - watcher: SessionWatcher 实例
    ///   - sessionId: 会话 ID
    ///   - messages: 新消息列表
    ///   - transcriptPath: JSONL 文件路径（用于解析结构化内容）
    func sessionWatcher(
        _ watcher: SessionWatcher,
        didReceiveMessages messages: [RawMessage],
        for sessionId: String,
        transcriptPath: String
    )
}

// MARK: - WatchedSession

/// 单个会话的监听状态
private final class WatchedSession {
    let sessionId: String
    let transcriptPath: String
    var fileDescriptor: Int32
    var dispatchSource: DispatchSourceFileSystemObject?
    var lastOffset: UInt64
    var lastMessageUUID: String?
    /// 每个 session 专属的串行队列，避免并发竞态
    let processingQueue: DispatchQueue

    init(sessionId: String, transcriptPath: String) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.fileDescriptor = -1
        self.dispatchSource = nil
        self.lastOffset = 0
        self.lastMessageUUID = nil
        self.processingQueue = DispatchQueue(
            label: "com.eterm.vlaudekit.session.\(sessionId)",
            qos: .utility
        )
    }
}

// MARK: - PendingSession

/// 等待文件创建的会话
private struct PendingSession {
    let sessionId: String
    let transcriptPath: String
    /// 实际监听的目录（可能是父目录）
    var watchedDirectoryPath: String
    let createdAt: Date
}

// MARK: - DirectoryWatch

/// 目录监听状态
private struct DirectoryWatch {
    let directoryPath: String
    var fileDescriptor: Int32
    var dispatchSource: DispatchSourceFileSystemObject?

    init(directoryPath: String, fileDescriptor: Int32 = -1, dispatchSource: DispatchSourceFileSystemObject? = nil) {
        self.directoryPath = directoryPath
        self.fileDescriptor = fileDescriptor
        self.dispatchSource = dispatchSource
    }
}

// MARK: - SessionWatcher

final class SessionWatcher {
    weak var delegate: SessionWatcherDelegate?

    /// 正在监听的会话
    private var watchedSessions: [String: WatchedSession] = [:]

    /// 等待文件创建的会话（sessionId -> PendingSession）
    private var pendingSessions: [String: PendingSession] = [:]

    /// 目录监听（directoryPath -> DirectoryWatch）
    private var directoryWatches: [String: DirectoryWatch] = [:]

    /// 监听队列
    private let watchQueue = DispatchQueue(label: "com.eterm.vlaudekit.sessionwatcher", qos: .utility)

    /// Session 读取器
    private let sessionReader = SessionReader()

    /// 并发保护
    private let lock = NSLock()

    /// 超时时间（秒）
    private let pendingTimeout: TimeInterval = 30.0

    /// 超时检查定时器
    private var timeoutTimer: DispatchSourceTimer?

    // MARK: - Public API

    /// 开始监听会话文件
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - transcriptPath: JSONL 文件路径
    ///   - fromBeginning: 是否从文件开头开始推送（用于延迟启动场景）
    func startWatching(sessionId: String, transcriptPath: String, fromBeginning: Bool = false) {
        lock.lock()

        // 避免重复监听
        if watchedSessions[sessionId] != nil {
            lock.unlock()
            return
        }

        // 检查是否已在待监听队列
        if pendingSessions[sessionId] != nil {
            lock.unlock()
            return
        }

        // 检查文件是否存在
        let fileExists = FileManager.default.fileExists(atPath: transcriptPath)

        if !fileExists {
            // 文件不存在，找到最近存在的父目录进行监听
            let watchDir = findNearestExistingDirectory(for: transcriptPath)

            let pending = PendingSession(
                sessionId: sessionId,
                transcriptPath: transcriptPath,
                watchedDirectoryPath: watchDir,
                createdAt: Date()
            )
            pendingSessions[sessionId] = pending
            lock.unlock()

            // 启动目录监听（在锁外执行，避免死锁）
            startDirectoryWatching(directoryPath: watchDir)

            // 启动超时检查
            startTimeoutCheckerIfNeeded()
            return
        }

        lock.unlock()

        // 文件存在，直接启动文件监听
        startFileWatching(sessionId: sessionId, transcriptPath: transcriptPath, fromBeginning: fromBeginning)
    }

    /// 启动文件监听（内部方法）
    private func startFileWatching(sessionId: String, transcriptPath: String, fromBeginning: Bool) {
        lock.lock()
        defer { lock.unlock() }

        // 再次检查避免重复
        if watchedSessions[sessionId] != nil { return }

        let session = WatchedSession(sessionId: sessionId, transcriptPath: transcriptPath)

        if fromBeginning {
            session.lastOffset = 0
            session.lastMessageUUID = nil
        } else {
            // 获取初始文件大小作为 lastOffset
            if let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
               let size = attrs[.size] as? UInt64 {
                session.lastOffset = size
            }

            // 读取最后一条消息的 UUID 用于去重
            if let result = sessionReader.readMessages(
                sessionPath: transcriptPath,
                limit: 1,
                offset: 0,
                orderAsc: false
            ), let lastMsg = result.messages.first {
                session.lastMessageUUID = lastMsg.uuid
            }
        }

        // 打开文件描述符
        let fd = open(transcriptPath, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return }
        session.fileDescriptor = fd

        // 创建 DispatchSource
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: watchQueue
        )

        let sessionIdCapture = sessionId

        source.setEventHandler { [weak self] in
            self?.handleFileChange(sessionId: sessionIdCapture)
        }

        source.setCancelHandler { [weak self] in
            close(fd)
            self?.lock.lock()
            self?.watchedSessions.removeValue(forKey: sessionIdCapture)
            self?.lock.unlock()
        }

        session.dispatchSource = source
        watchedSessions[sessionId] = session

        source.resume()

        // 如果 fromBeginning，立即触发一次文件读取来推送已有消息
        if fromBeginning {
            // 在 watchQueue 中异步触发，避免阻塞
            watchQueue.async { [weak self] in
                self?.handleFileChange(sessionId: sessionIdCapture)
            }
        }
    }

    /// 停止监听会话文件
    /// - Parameter sessionId: 会话 ID
    func stopWatching(sessionId: String) {
        lock.lock()
        let session = watchedSessions[sessionId]
        // 同时清理 pending session
        pendingSessions.removeValue(forKey: sessionId)
        lock.unlock()

        session?.dispatchSource?.cancel()

        // 检查是否需要停止目录监听
        cleanupDirectoryWatchesIfNeeded()
    }

    /// 停止所有监听
    func stopAll() {
        lock.lock()
        let sessions = Array(watchedSessions.values)
        let dirWatches = Array(directoryWatches.values)
        pendingSessions.removeAll()
        timeoutTimer?.cancel()
        timeoutTimer = nil
        lock.unlock()

        for session in sessions {
            session.dispatchSource?.cancel()
        }

        for watch in dirWatches {
            watch.dispatchSource?.cancel()
        }
    }

    /// 检查是否正在监听指定会话
    func isWatching(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watchedSessions[sessionId] != nil
    }

    // MARK: - Directory Watching

    /// 找到最近存在的父目录
    /// - Parameter path: 文件或目录路径
    /// - Returns: 最近存在的父目录路径（最低到 ~/.claude/projects）
    private func findNearestExistingDirectory(for path: String) -> String {
        let fileManager = FileManager.default
        var currentPath = (path as NSString).deletingLastPathComponent

        // ~/.claude/projects 作为根目录（不能再往上）
        let claudeProjectsRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

        while !currentPath.isEmpty && currentPath != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: currentPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                return currentPath
            }

            // 已到达根目录，停止向上
            if currentPath == claudeProjectsRoot {
                break
            }

            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        // 如果连 ~/.claude/projects 都不存在，返回它（稍后会创建）
        return claudeProjectsRoot
    }

    /// 启动目录监听
    /// - Parameter directoryPath: 目录路径
    private func startDirectoryWatching(directoryPath: String) {
        lock.lock()

        // 检查是否已在监听该目录
        if directoryWatches[directoryPath] != nil {
            lock.unlock()
            return
        }

        // 检查目录是否存在
        var isDirectory: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory)

        if !dirExists || !isDirectory.boolValue {
            // 目录不存在，尝试创建（Claude 可能还没写入）
            do {
                try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
            } catch {
                lock.unlock()
                return
            }
        }

        // 打开目录文件描述符
        let fd = open(directoryPath, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else {
            lock.unlock()
            return
        }

        // 创建目录 DispatchSource
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],  // 目录内容变化
            queue: watchQueue
        )

        let dirPathCapture = directoryPath

        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange(directoryPath: dirPathCapture)
        }

        source.setCancelHandler { [weak self] in
            close(fd)
            self?.lock.lock()
            self?.directoryWatches.removeValue(forKey: dirPathCapture)
            self?.lock.unlock()
        }

        var watch = DirectoryWatch(directoryPath: directoryPath)
        watch.fileDescriptor = fd
        watch.dispatchSource = source
        directoryWatches[directoryPath] = watch

        lock.unlock()

        source.resume()
    }

    /// 处理目录变化事件
    /// - Parameter directoryPath: 目录路径
    private func handleDirectoryChange(directoryPath: String) {
        lock.lock()

        // 找出该目录下等待的 pending sessions（可能监听的是父目录）
        let pendingInDir = pendingSessions.values.filter { $0.watchedDirectoryPath == directoryPath }

        if pendingInDir.isEmpty {
            lock.unlock()
            return
        }

        // 检查每个 pending session 的文件是否已创建
        var sessionsToStart: [(sessionId: String, transcriptPath: String)] = []
        var sessionsToUpdateWatch: [(sessionId: String, pending: PendingSession)] = []

        for pending in pendingInDir {
            if FileManager.default.fileExists(atPath: pending.transcriptPath) {
                // 文件已创建，准备启动监听
                sessionsToStart.append((pending.sessionId, pending.transcriptPath))
                pendingSessions.removeValue(forKey: pending.sessionId)
            } else {
                // 文件还不存在，检查是否可以监听更近的目录
                let newWatchDir = findNearestExistingDirectory(for: pending.transcriptPath)
                if newWatchDir != pending.watchedDirectoryPath {
                    // 可以切换到更近的目录
                    var updatedPending = pending
                    updatedPending.watchedDirectoryPath = newWatchDir
                    sessionsToUpdateWatch.append((pending.sessionId, updatedPending))
                }
            }
        }

        // 更新需要切换监听目录的 sessions
        for (sessionId, updatedPending) in sessionsToUpdateWatch {
            pendingSessions[sessionId] = updatedPending
        }

        lock.unlock()

        // 启动文件监听（在锁外执行）
        for session in sessionsToStart {
            // fromBeginning=true，从文件开头读取所有消息
            startFileWatching(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath,
                fromBeginning: true
            )
        }

        // 启动新目录监听（在锁外执行）
        for (_, updatedPending) in sessionsToUpdateWatch {
            startDirectoryWatching(directoryPath: updatedPending.watchedDirectoryPath)
        }

        // 检查是否还需要继续监听该目录
        cleanupDirectoryWatchesIfNeeded()
    }

    /// 启动超时检查定时器（如果尚未启动）
    private func startTimeoutCheckerIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        // 已有定时器在运行
        if timeoutTimer != nil {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)  // 每5秒检查一次

        timer.setEventHandler { [weak self] in
            self?.checkPendingSessionTimeouts()
        }

        timeoutTimer = timer
        timer.resume()
    }

    /// 检查 pending sessions 是否超时
    private func checkPendingSessionTimeouts() {
        let now = Date()

        lock.lock()

        var expiredSessionIds: [String] = []

        for (sessionId, pending) in pendingSessions {
            let elapsed = now.timeIntervalSince(pending.createdAt)
            if elapsed > pendingTimeout {
                expiredSessionIds.append(sessionId)
            }
        }

        for sessionId in expiredSessionIds {
            pendingSessions.removeValue(forKey: sessionId)
        }

        // 如果没有更多 pending sessions，停止定时器
        if pendingSessions.isEmpty {
            timeoutTimer?.cancel()
            timeoutTimer = nil
        }

        lock.unlock()

        // 清理不再需要的目录监听
        if !expiredSessionIds.isEmpty {
            cleanupDirectoryWatchesIfNeeded()
        }
    }

    /// 清理不再需要的目录监听
    private func cleanupDirectoryWatchesIfNeeded() {
        lock.lock()

        // 找出仍有 pending session 的目录
        let activeDirectories = Set(pendingSessions.values.map { $0.watchedDirectoryPath })

        // 找出不再需要的目录监听
        var watchesToCancel: [DispatchSourceFileSystemObject] = []

        for (dirPath, watch) in directoryWatches {
            if !activeDirectories.contains(dirPath) {
                if let source = watch.dispatchSource {
                    watchesToCancel.append(source)
                }
            }
        }

        lock.unlock()

        // 取消不需要的监听（在锁外执行）
        for source in watchesToCancel {
            source.cancel()
        }
    }

    // MARK: - Private Methods

    /// 处理文件变化事件
    /// 使用 per-session 串行队列避免并发竞态
    private func handleFileChange(sessionId: String) {
        // 短锁：只获取 session 引用
        lock.lock()
        guard let session = watchedSessions[sessionId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        // 在 session 专属串行队列上处理，天然避免并发
        session.processingQueue.async { [weak self] in
            self?.processFileChange(session: session)
        }
    }

    /// 实际处理文件变化（在 session 专属队列上执行）
    private func processFileChange(session: WatchedSession) {
        let sessionId = session.sessionId

        // 检查是否仍在监听（防止 stop 后继续回调）
        lock.lock()
        let isActive = watchedSessions[sessionId] != nil
        lock.unlock()
        guard isActive else { return }

        // 检查新的文件大小
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: session.transcriptPath),
              let newSize = attrs[.size] as? UInt64 else { return }

        // 文件没有增长，跳过
        guard newSize > session.lastOffset else { return }

        // 读取新增的消息（session 是 class，直接修改）
        let newMessages = readNewMessages(session: session, newSize: newSize)

        // 通知 delegate（在主线程）
        if !newMessages.isEmpty {
            let path = session.transcriptPath
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.sessionWatcher(self, didReceiveMessages: newMessages, for: sessionId, transcriptPath: path)
            }
        }
    }

    /// 读取新增的消息
    /// - Parameters:
    ///   - session: 会话状态（class，直接修改属性）
    ///   - newSize: 新的文件大小
    /// - Returns: 新消息列表
    private func readNewMessages(session: WatchedSession, newSize: UInt64) -> [RawMessage] {
        // 读取所有消息，然后过滤出新的
        // 注意：FFI 不支持从特定 offset 读取，所以我们读取全部然后过滤
        guard let result = sessionReader.readMessages(
            sessionPath: session.transcriptPath,
            limit: 0,  // 读取全部
            offset: 0,
            orderAsc: true
        ) else {
            return []
        }

        // 找到 lastMessageUUID 之后的消息
        var newMessages: [RawMessage] = []
        var foundLast = session.lastMessageUUID == nil

        for msg in result.messages {
            if foundLast {
                newMessages.append(msg)
            } else if msg.uuid == session.lastMessageUUID {
                foundLast = true
            }
        }

        // 防御：如果 lastMessageUUID 在文件中找不到，返回所有消息
        if !foundLast && session.lastMessageUUID != nil {
            newMessages = result.messages
        }

        // 更新 lastOffset 和 lastMessageUUID
        session.lastOffset = newSize
        if let lastMsg = newMessages.last ?? result.messages.last {
            session.lastMessageUUID = lastMsg.uuid
        }

        return newMessages
    }

    deinit {
        stopAll()
    }
}
