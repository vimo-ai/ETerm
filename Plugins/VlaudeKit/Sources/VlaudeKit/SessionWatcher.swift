//
//  SessionWatcher.swift
//  VlaudeKit
//
//  DispatchSource 文件监听 + 增量解析
//
//  职责：
//  - 使用 GCD DispatchSource 监听 transcript 文件变化
//  - 增量读取新消息（只读取 lastOffset 之后的内容）
//  - 通知 delegate 处理新消息
//

import Foundation

// MARK: - SessionWatcherDelegate

protocol SessionWatcherDelegate: AnyObject {
    /// 收到新消息
    /// - Parameters:
    ///   - watcher: SessionWatcher 实例
    ///   - sessionId: 会话 ID
    ///   - messages: 新消息列表
    func sessionWatcher(
        _ watcher: SessionWatcher,
        didReceiveMessages messages: [RawMessage],
        for sessionId: String
    )
}

// MARK: - WatchedSession

/// 单个会话的监听状态
private struct WatchedSession {
    let sessionId: String
    let transcriptPath: String
    var fileDescriptor: Int32
    var dispatchSource: DispatchSourceFileSystemObject?
    var lastOffset: UInt64
    var lastMessageUUID: String?

    init(sessionId: String, transcriptPath: String) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.fileDescriptor = -1
        self.dispatchSource = nil
        self.lastOffset = 0
        self.lastMessageUUID = nil
    }
}

// MARK: - SessionWatcher

final class SessionWatcher {
    weak var delegate: SessionWatcherDelegate?

    /// 正在监听的会话
    private var watchedSessions: [String: WatchedSession] = [:]

    /// 监听队列
    private let watchQueue = DispatchQueue(label: "com.eterm.vlaudekit.sessionwatcher", qos: .utility)

    /// Session 读取器
    private let sessionReader = SessionReader()

    /// 并发保护
    private let lock = NSLock()

    // MARK: - Public API

    /// 开始监听会话文件
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - transcriptPath: JSONL 文件路径
    func startWatching(sessionId: String, transcriptPath: String) {
        lock.lock()
        defer { lock.unlock() }

        // 避免重复监听
        if watchedSessions[sessionId] != nil {
            print("[SessionWatcher] 已在监听: \(sessionId)")
            return
        }

        var session = WatchedSession(sessionId: sessionId, transcriptPath: transcriptPath)

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

        // 打开文件描述符
        let fd = open(transcriptPath, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else {
            print("[SessionWatcher] 无法打开文件: \(transcriptPath)")
            return
        }
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
            print("[SessionWatcher] 停止监听: \(sessionIdCapture)")
        }

        session.dispatchSource = source
        watchedSessions[sessionId] = session

        source.resume()
        print("[SessionWatcher] 开始监听: \(sessionId), offset=\(session.lastOffset)")
    }

    /// 停止监听会话文件
    /// - Parameter sessionId: 会话 ID
    func stopWatching(sessionId: String) {
        lock.lock()
        let session = watchedSessions[sessionId]
        lock.unlock()

        session?.dispatchSource?.cancel()
    }

    /// 停止所有监听
    func stopAll() {
        lock.lock()
        let sessions = Array(watchedSessions.values)
        lock.unlock()

        for session in sessions {
            session.dispatchSource?.cancel()
        }
    }

    /// 检查是否正在监听指定会话
    func isWatching(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watchedSessions[sessionId] != nil
    }

    // MARK: - Private Methods

    /// 处理文件变化事件
    private func handleFileChange(sessionId: String) {
        lock.lock()
        guard var session = watchedSessions[sessionId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        // 检查新的文件大小
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: session.transcriptPath),
              let newSize = attrs[.size] as? UInt64 else {
            return
        }

        // 文件没有增长，跳过
        guard newSize > session.lastOffset else {
            return
        }

        // 读取新增的消息
        let newMessages = readNewMessages(session: &session, newSize: newSize)

        // 更新状态
        lock.lock()
        if var updated = watchedSessions[sessionId] {
            updated.lastOffset = session.lastOffset
            updated.lastMessageUUID = session.lastMessageUUID
            watchedSessions[sessionId] = updated
        }
        lock.unlock()

        // 通知 delegate（在主线程）
        if !newMessages.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.sessionWatcher(self, didReceiveMessages: newMessages, for: sessionId)
            }
        }
    }

    /// 读取新增的消息
    /// - Parameters:
    ///   - session: 会话状态（会被修改）
    ///   - newSize: 新的文件大小
    /// - Returns: 新消息列表
    private func readNewMessages(session: inout WatchedSession, newSize: UInt64) -> [RawMessage] {
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
            print("[SessionWatcher] ⚠️ lastMessageUUID 未找到，返回全部消息")
            newMessages = result.messages
        }

        // 更新 lastOffset 和 lastMessageUUID
        session.lastOffset = newSize
        if let lastMsg = newMessages.last ?? result.messages.last {
            session.lastMessageUUID = lastMsg.uuid
        }

        if !newMessages.isEmpty {
            print("[SessionWatcher] 发现 \(newMessages.count) 条新消息: \(session.sessionId)")
        }

        return newMessages
    }

    deinit {
        stopAll()
    }
}
