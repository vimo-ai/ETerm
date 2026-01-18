//
//  OpenCodeProvider.swift
//  AICliKit
//
//  OpenCode Provider - 通过 Unix Socket 接收 OpenCode Hook 事件
//
//  OpenCode 使用 Plugin 系统（JS/TS），通过 socket 发送事件：
//  - session.created → sessionStart
//  - session.idle → responseComplete
//  - permission.* → permissionRequest
//  - tool.execute.before/after → toolUse

import Foundation
import ETermKit

/// OpenCode Provider - 实现 AICliProvider 协议
///
/// 通过 Unix Domain Socket 接收 OpenCode plugin 事件。
@MainActor
public final class OpenCodeProvider: AICliProvider {
    public static let providerId = "opencode"

    public static let capabilities = AICliCapabilities.opencode

    public var onEvent: ((AICliEvent) -> Void)?

    private var socketServer: OpenCodeSocketServer?
    private var config: AICliProviderConfig?

    public var isRunning: Bool {
        socketServer?.socketPath != nil
    }

    public required init() {}

    public func start(config: AICliProviderConfig) {
        self.config = config

        socketServer = OpenCodeSocketServer()
        socketServer?.onEvent = { [weak self] rawEvent in
            guard let self = self else { return }
            if let event = self.mapEvent(rawEvent) {
                self.onEvent?(event)
            }
        }

        let socketPath = config.socketDirectory + "/opencode.sock"
        socketServer?.start(at: socketPath)
    }

    public func stop() {
        socketServer?.stop()
        socketServer = nil
    }

    // MARK: - Event Mapping

    /// 将 OpenCode 原始事件映射为标准 AICliEvent
    private func mapEvent(_ raw: OpenCodeHookEvent) -> AICliEvent? {
        let eventType: AICliEventType
        var payload: [String: Any] = [:]

        switch raw.event_type {
        case "session.created":
            eventType = .sessionStart

        case "session.idle":
            eventType = .responseComplete

        case let type where type.hasPrefix("permission."):
            eventType = .permissionRequest
            if let toolName = raw.tool_name {
                payload["toolName"] = toolName
            }
            if let toolInput = raw.tool_input {
                payload["toolInput"] = toolInput
            }

        case "tool.execute.before":
            eventType = .toolUse
            payload["phase"] = "before"
            if let toolName = raw.tool_name {
                payload["toolName"] = toolName
            }

        case "tool.execute.after":
            eventType = .toolUse
            payload["phase"] = "after"
            if let toolName = raw.tool_name {
                payload["toolName"] = toolName
            }

        default:
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

// MARK: - OpenCode Hook Event (原始格式)

/// OpenCode Hook 调用的原始事件
struct OpenCodeHookEvent: Codable {
    let event_type: String
    let session_id: String
    let terminal_id: Int
    let transcript_path: String?
    let cwd: String?

    // 工具相关字段
    let tool_name: String?
    let tool_input: [String: String]?
}

// MARK: - OpenCode Socket Server (内部实现)

/// Socket Server - 接收来自 OpenCode Plugin 的调用
final class OpenCodeSocketServer {

    private var socketFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var acceptSource: DispatchSourceRead?

    private(set) var socketPath: String?

    /// 事件回调
    var onEvent: ((OpenCodeHookEvent) -> Void)?

    init() {}

    /// 启动 Socket Server
    func start(at path: String) {
        let socketDir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: socketDir) {
            try? FileManager.default.createDirectory(
                atPath: socketDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        unlink(path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }

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

        chmod(path, 0o600)

        guard listen(socketFD, 5) >= 0 else {
            close(socketFD)
            socketFD = -1
            return
        }

        socketPath = path
        startAcceptingConnections()
    }

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

    private func startAcceptingConnections() {
        acceptQueue = DispatchQueue(label: "com.eterm.aicli.opencode-socket")
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

        guard clientFD >= 0 else { return }

        DispatchQueue.global().async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count)

        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))

        do {
            let event = try JSONDecoder().decode(OpenCodeHookEvent.self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        } catch {
            // 解析失败，静默处理
        }
    }
}
