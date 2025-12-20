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
    let event_type: String?  // "stop" 或 "notification"
    let session_id: String
    let terminal_id: Int
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
        // 确保 /tmp/eterm 目录存在
        let etermDir = "/tmp/eterm"
        try? FileManager.default.createDirectory(atPath: etermDir, withIntermediateDirectories: true)

        // Socket 路径：/tmp/eterm/eterm-{pid}.sock
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = "\(etermDir)/eterm-\(pid).sock"

        // 清理旧的 socket 文件
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

        // 设置环境变量，供子进程继承
        setenv("ETERM_SOCKET_PATH", path, 1)

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
            unsetenv("ETERM_SOCKET_PATH")
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

            // 发送 session 开始通知
            NotificationCenter.default.post(
                name: .claudeSessionStart,
                object: nil,
                userInfo: [
                    "session_id": event.session_id,
                    "terminal_id": event.terminal_id
                ]
            )

        case "user_prompt_submit":
            // 用户提交问题，Claude 开始思考
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)
            print("🔵 [ClaudeSocket] user_prompt_submit received, terminal_id: \(event.terminal_id)")

            // 发送用户提交通知（用于显示"思考中"动画）
            NotificationCenter.default.post(
                name: .claudeUserPromptSubmit,
                object: nil,
                userInfo: [
                    "session_id": event.session_id,
                    "terminal_id": event.terminal_id
                ]
            )

        case "session_end":
            // 发送 session 结束通知
            NotificationCenter.default.post(
                name: .claudeSessionEnd,
                object: nil,
                userInfo: [
                    "session_id": event.session_id,
                    "terminal_id": event.terminal_id
                ]
            )

        case "stop":
            // 建立/更新映射关系
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)
            print("🟠 [ClaudeSocket] stop received, terminal_id: \(event.terminal_id)")

            // 发送响应完成通知
            NotificationCenter.default.post(
                name: .claudeResponseComplete,
                object: nil,
                userInfo: [
                    "session_id": event.session_id,
                    "terminal_id": event.terminal_id
                ]
            )

        default:
            // notification 或其他事件
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Claude 会话开始（用于设置"运行中"装饰）
    static let claudeSessionStart = Notification.Name("claudeSessionStart")
    /// 用户提交问题（用于设置"思考中"装饰）
    static let claudeUserPromptSubmit = Notification.Name("claudeUserPromptSubmit")
    /// Claude 响应完成（用于设置"完成"装饰）
    static let claudeResponseComplete = Notification.Name("claudeResponseComplete")
    /// Claude 会话结束（用于清除装饰）
    static let claudeSessionEnd = Notification.Name("claudeSessionEnd")
}
