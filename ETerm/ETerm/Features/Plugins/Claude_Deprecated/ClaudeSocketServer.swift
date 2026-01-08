//
//  ClaudeSocketServer.swift
//  ETerm
//
//  Claude CLI Integration - Socket Server
//  接收来自 Claude Stop Hook 的通知
//

import Foundation
import ETermKit

/// Claude Hook 调用的事件
struct ClaudeResponseCompleteEvent: Codable {
    let event_type: String?  // "stop", "notification", "user_prompt_submit", "permission_request" 等
    let session_id: String
    let terminal_id: Int
    let prompt: String?  // 用户提交的问题（仅 user_prompt_submit 事件）

    // Notification 事件扩展字段
    let notification_type: String?  // "elicitation_dialog" 等（permission_prompt 由 PermissionRequest 处理）
    let message: String?  // 通知消息内容

    // PermissionRequest 事件字段（直接来自 hook，无需读 JSONL）
    let tool_name: String?  // 工具名称：Bash, Write, Edit, Task 等
    let tool_input: [String: AnyCodable]?  // 工具输入：{"command": "..."} 等（使用 ETermKit.AnyCodable）
    let tool_use_id: String?  // 工具调用 ID

    // 通用字段
    let transcript_path: String?  // JSONL 文件路径
    let cwd: String?  // 工作目录
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
        // 使用新的 socket 路径：~/.vimo/eterm/run/sockets/claude.sock
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
        // ETERM_SOCKET_DIR 指向 ~/.vimo/eterm/run/sockets

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

        // 循环读取数据（支持大 payload，如 Write 工具的文件内容）
        // 最大 1MB，防止恶意大数据
        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)  // 64KB 每次
        let maxSize = 1024 * 1024  // 1MB 上限

        while allData.count < maxSize {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 {
                break  // EOF 或错误
            }
            allData.append(contentsOf: buffer.prefix(bytesRead))
        }

        guard !allData.isEmpty else {
            return
        }

        // 解析 JSON
        do {
            let event = try JSONDecoder().decode(ClaudeResponseCompleteEvent.self, from: allData)

            // 在主线程处理事件
            DispatchQueue.main.async { [weak self] in
                self?.handleResponseComplete(event: event)
            }

        } catch {
            // 记录解码错误（便于调试）
            #if DEBUG
            if let json = String(data: allData.prefix(500), encoding: .utf8) {
                print("⚠️ [ClaudeSocketServer] JSON decode failed, preview: \(json.prefix(200))...")
            }
            #endif
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

        case "permission_request":
            // 权限请求事件（来自 PermissionRequest hook，包含完整工具信息）
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

            // 转换 tool_input 为 [String: Any]
            var toolInputDict: [String: Any] = [:]
            if let toolInput = event.tool_input {
                toolInputDict = toolInput.mapValues { $0.value }
            }

            // 发射权限请求事件（包含工具详情）
            EventBus.shared.emit(ClaudeEvents.PermissionPrompt(
                terminalId: event.terminal_id,
                sessionId: event.session_id,
                message: nil,  // PermissionRequest hook 没有 message
                toolName: event.tool_name ?? "Unknown",
                toolInput: toolInputDict,
                toolUseId: event.tool_use_id,
                transcriptPath: event.transcript_path,
                cwd: event.cwd
            ))

        case "notification":
            // 建立/更新映射关系
            ClaudeSessionMapper.shared.map(terminalId: event.terminal_id, sessionId: event.session_id)

            // 其他通知类型（permission_prompt 已在 hook 中过滤），发射等待用户输入事件
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
