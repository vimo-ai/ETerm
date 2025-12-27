//
//  ClaudeSocketServer.swift
//  ETerm
//
//  Claude CLI Integration - Socket Server
//  接收来自 Claude Stop Hook 的通知
//

import Foundation

/// Claude Hook 调用的事件
struct ClaudeResponseCompleteEvent: Codable {
    let event_type: String?  // "stop", "notification", "user_prompt_submit" 等
    let session_id: String
    let terminal_id: Int
    let prompt: String?  // 用户提交的问题（仅 user_prompt_submit 事件）
}

/// Socket Server - 接收来自 Claude Hook 的调用
class ClaudeSocketServer {
    static let shared = ClaudeSocketServer()

    private var socketFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var acceptSource: DispatchSourceRead?

    private(set) var socketPath: String?

    private init() {}

    /// 启动 Socket Server
    func start() {
        // 使用新的 socket 路径：~/.eterm/run/sockets/claude.sock
        let path = ETermPaths.socketPath(for: "claude")

        // 确保目录存在（权限 0700）
        let socketDir = ETermPaths.sockets
        if !FileManager.default.fileExists(atPath: socketDir) {
            try? FileManager.default.createDirectory(
                atPath: socketDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // 清理旧的 socket 文件（崩溃恢复）
        unlink(path)

        // 创建 Unix Domain Socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            return
        }

        // 设置 socket 地址
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(socketFD)
            socketFD = -1
            return
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { cString in
                strcpy(ptr, cString)
            }
        }

        // Bind socket
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            close(socketFD)
            socketFD = -1
            return
        }

        // Listen
        guard listen(socketFD, 5) >= 0 else {
            close(socketFD)
            socketFD = -1
            return
        }

        socketPath = path

        // 环境变量由 ETermPaths.createDirectories() 统一设置
        // ETERM_SOCKET_DIR 指向 ~/.eterm/run/sockets

        // 开始接受连接
        startAcceptingConnections()
    }

    /// 停止 Socket Server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        if let path = socketPath {
            unlink(path)
        }

        socketPath = nil
    }

    // MARK: - Connection Handling

    private func startAcceptingConnections() {
        acceptQueue = DispatchQueue(label: "com.vimo.eterm.claude-socket-accept")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: acceptQueue!)

        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }

        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
            }
        }

        acceptSource?.resume()
    }

    private func acceptConnection() {
        var addr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            return
        }


        // 在后台线程读取数据
        DispatchQueue.global().async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer {
            close(fd)
        }

        // 读取数据（最多 8KB）
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count)

        guard bytesRead > 0 else {
            return
        }

        let data = Data(buffer.prefix(bytesRead))

        // 解析 JSON
        do {
            let event = try JSONDecoder().decode(ClaudeResponseCompleteEvent.self, from: data)

            // 在主线程处理事件
            DispatchQueue.main.async { [weak self] in
                self?.handleResponseComplete(event: event)
            }

        } catch {
            if let json = String(data: data, encoding: .utf8) {
            }
        }
    }

    // MARK: - Event Handling

    private func handleResponseComplete(event: ClaudeResponseCompleteEvent) {
        let eventType = event.event_type ?? "stop"

        switch eventType {
        case "session_start":
            // 建立映射关系
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

            // 发射 session 开始事件
            EventBus.shared.emit(ClaudeEvents.SessionStart(
                terminalId: event.terminal_id,
                sessionId: event.session_id
            ))

        case "user_prompt_submit":
            // 用户提交问题，Claude 开始思考
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

            // 发射用户提交事件
            EventBus.shared.emit(ClaudeEvents.PromptSubmit(
                terminalId: event.terminal_id,
                sessionId: event.session_id,
                prompt: event.prompt
            ))

        case "session_end":
            // 发射 session 结束事件
            EventBus.shared.emit(ClaudeEvents.SessionEnd(
                terminalId: event.terminal_id,
                sessionId: event.session_id
            ))

        case "stop":
            // 建立/更新映射关系
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

            // 发射响应完成事件
            EventBus.shared.emit(ClaudeEvents.ResponseComplete(
                terminalId: event.terminal_id,
                sessionId: event.session_id
            ))

        case "notification":
            // 建立/更新映射关系
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

            // 发射等待用户输入事件
            EventBus.shared.emit(ClaudeEvents.WaitingInput(
                terminalId: event.terminal_id,
                sessionId: event.session_id
            ))

        default:
            // 其他未知事件，只建立映射关系
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)
        }
    }
}
