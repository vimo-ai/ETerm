//
//  ClaudeProvider.swift
//  AICliKit
//
//  Claude Code Provider - 通过 Unix Socket 接收 Claude Hook 事件
//

import Foundation
import ETermKit

/// Claude Provider - 实现 AICliProvider 协议
///
/// 通过 Unix Domain Socket 接收 Claude Code hooks 事件，
/// 将原始事件转换为标准 AICliEvent。
@MainActor
public final class ClaudeProvider: AICliProvider {
    public static let providerId = "claude"

    public static let capabilities = AICliCapabilities.claude

    public var onEvent: ((AICliEvent) -> Void)?

    private var socketServer: ClaudeSocketServer?
    private var config: AICliProviderConfig?

    public var isRunning: Bool {
        socketServer?.socketPath != nil
    }

    public required init() {}

    public func start(config: AICliProviderConfig) {
        self.config = config

        socketServer = ClaudeSocketServer()
        socketServer?.onEvent = { [weak self] rawEvent in
            guard let self = self else { return }
            if let event = self.mapEvent(rawEvent) {
                self.onEvent?(event)
            }
        }

        let socketPath = config.socketDirectory + "/claude.sock"
        socketServer?.start(at: socketPath)
    }

    public func stop() {
        socketServer?.stop()
        socketServer = nil
    }

    // MARK: - Event Mapping

    /// 将 Claude 原始事件映射为标准 AICliEvent
    private func mapEvent(_ raw: ClaudeHookEvent) -> AICliEvent? {
        let eventType: AICliEventType
        var payload: [String: Any] = [:]

        switch raw.event_type {
        case "session_start":
            eventType = .sessionStart

        case "user_prompt_submit":
            eventType = .userInput
            if let prompt = raw.prompt {
                payload["prompt"] = prompt
            }

        case "notification":
            eventType = .waitingInput

        case "stop":
            eventType = .responseComplete

        case "session_end":
            eventType = .sessionEnd

        case "permission_request":
            eventType = .permissionRequest
            if let toolName = raw.tool_name {
                payload["toolName"] = toolName
            }
            if let toolInput = raw.tool_input {
                payload["toolInput"] = toolInput.mapValues { $0.value }
            }
            if let toolUseId = raw.tool_use_id {
                payload["toolUseId"] = toolUseId
            }

        default:
            // 未知事件类型，忽略
            return nil
        }

        return AICliEvent(
            source: Self.providerId,
            type: eventType,
            terminalId: raw.terminal_id,
            sessionId: raw.session_id,
            transcriptPath: raw.transcript_path,
            cwd: raw.cwd,
            payload: payload
        )
    }
}

// MARK: - Claude Hook Event (原始格式)

/// Claude Hook 调用的原始事件
struct ClaudeHookEvent: Codable {
    let event_type: String?
    let session_id: String
    let terminal_id: Int
    let prompt: String?
    let transcript_path: String?
    let cwd: String?

    // 权限请求相关字段
    let tool_name: String?
    let tool_input: [String: AnyCodable]?
    let tool_use_id: String?
}

/// 用于解码任意 JSON 值
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}

// MARK: - Claude Socket Server (内部实现)

/// Socket Server - 接收来自 Claude Hook 的调用
final class ClaudeSocketServer {

    private var socketFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var acceptSource: DispatchSourceRead?

    private(set) var socketPath: String?

    /// 事件回调
    var onEvent: ((ClaudeHookEvent) -> Void)?

    init() {}

    /// 启动 Socket Server
    func start(at path: String) {
        // 确保目录存在（权限 0700）
        let socketDir = (path as NSString).deletingLastPathComponent
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

        // 设置 socket 文件权限（0600）
        chmod(path, 0o600)

        // Listen
        guard listen(socketFD, 5) >= 0 else {
            close(socketFD)
            socketFD = -1
            return
        }

        socketPath = path

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
        acceptQueue = DispatchQueue(label: "com.eterm.aicli.claude-socket")

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
            let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: data)

            // 在主线程处理事件
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }

        } catch {
            // 解析失败，静默处理
        }
    }
}
