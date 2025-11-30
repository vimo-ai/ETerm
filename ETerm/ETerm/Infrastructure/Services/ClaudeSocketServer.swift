//
//  ClaudeSocketServer.swift
//  ETerm
//
//  Claude CLI Integration - Socket Server
//  接收来自 Claude Stop Hook 的通知
//

import Foundation

/// Claude Stop Hook 调用的事件
struct ClaudeResponseCompleteEvent: Codable {
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
            print("❌ [ClaudeSocket] Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // 设置 socket 地址
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            print("❌ [ClaudeSocket] Socket path too long")
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
            print("❌ [ClaudeSocket] Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        // Listen
        guard listen(socketFD, 5) >= 0 else {
            print("❌ [ClaudeSocket] Failed to listen: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        print("✅ [ClaudeSocket] Server started at: \(path)")
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
        print("🛑 [ClaudeSocket] Server stopped")
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
            print("❌ [ClaudeSocket] Failed to accept connection: \(String(cString: strerror(errno)))")
            return
        }

        print("📥 [ClaudeSocket] New connection accepted")

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
            print("⚠️ [ClaudeSocket] No data received")
            return
        }

        let data = Data(buffer.prefix(bytesRead))

        // 解析 JSON
        do {
            let event = try JSONDecoder().decode(ClaudeResponseCompleteEvent.self, from: data)
            print("✅ [ClaudeSocket] Received event: session=\(event.session_id), terminal=\(event.terminal_id)")

            // 在主线程处理事件
            DispatchQueue.main.async { [weak self] in
                self?.handleResponseComplete(event: event)
            }

        } catch {
            print("❌ [ClaudeSocket] Failed to decode JSON: \(error)")
            if let json = String(data: data, encoding: .utf8) {
                print("   Raw data: \(json)")
            }
        }
    }

    // MARK: - Event Handling

    private func handleResponseComplete(event: ClaudeResponseCompleteEvent) {
        print("🎯 [ClaudeSocket] Handling response complete: session=\(event.session_id), terminal=\(event.terminal_id)")

        // 建立映射关系
        ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

        // 发送通知（跨层级跳转逻辑可以监听这个通知）
        NotificationCenter.default.post(
            name: .claudeResponseComplete,
            object: nil,
            userInfo: [
                "session_id": event.session_id,
                "terminal_id": event.terminal_id
            ]
        )

        // 调试：打印所有映射
        ClaudeSessionMapper.shared.debugPrint()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let claudeResponseComplete = Notification.Name("claudeResponseComplete")
}
