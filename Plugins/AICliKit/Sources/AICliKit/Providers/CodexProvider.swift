//
//  CodexProvider.swift
//  AICliKit
//
//  Codex CLI Provider - 通过 Unix Socket 接收 Codex CLI Hook 事件
//
//  Codex CLI hooks 配置（~/.codex/config.toml）：
//  [notify]
//  agent-turn-complete = "echo '{...}' | nc -U ~/.vimo/eterm/sockets/codex.sock"
//
//  注意：Codex CLI 目前仅支持 agent-turn-complete 事件

import Foundation
import ETermKit

/// Codex Provider - 实现 AICliProvider 协议
///
/// 通过 Unix Domain Socket 接收 Codex CLI hooks 事件。
/// Codex CLI 仅支持 agent-turn-complete 事件（responseComplete）。
@MainActor
public final class CodexProvider: AICliProvider {
    public static let providerId = "codex"

    /// Codex 只支持 responseComplete
    public static let capabilities = AICliCapabilities.codex

    public var onEvent: ((AICliEvent) -> Void)?

    private var socketServer: CodexSocketServer?
    private var config: AICliProviderConfig?

    public var isRunning: Bool {
        socketServer?.socketPath != nil
    }

    public required init() {}

    public func start(config: AICliProviderConfig) {
        self.config = config

        socketServer = CodexSocketServer()
        socketServer?.onEvent = { [weak self] rawEvent in
            guard let self = self else { return }
            if let event = self.mapEvent(rawEvent) {
                self.onEvent?(event)
            }
        }

        let socketPath = config.socketDirectory + "/codex.sock"
        socketServer?.start(at: socketPath)
    }

    public func stop() {
        socketServer?.stop()
        socketServer = nil
    }

    // MARK: - Event Mapping

    /// 将 Codex 原始事件映射为标准 AICliEvent
    private func mapEvent(_ raw: CodexHookEvent) -> AICliEvent? {
        // Codex 目前只支持 agent-turn-complete
        guard raw.event_type == "agent-turn-complete" else {
            return nil
        }

        return AICliEvent(
            source: Self.providerId,
            type: .responseComplete,
            terminalId: raw.terminal_id,
            sessionId: raw.session_id,
            transcriptPath: raw.transcript_path,
            cwd: raw.cwd,
            payload: [:]
        )
    }
}

// MARK: - Codex Hook Event (原始格式)

/// Codex Hook 调用的原始事件
struct CodexHookEvent: Codable {
    let event_type: String
    let session_id: String
    let terminal_id: Int
    let transcript_path: String?
    let cwd: String?
}

// MARK: - Codex Socket Server (内部实现)

/// Socket Server - 接收来自 Codex Hook 的调用
final class CodexSocketServer {

    private var socketFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var acceptSource: DispatchSourceRead?

    private(set) var socketPath: String?

    /// 事件回调
    var onEvent: ((CodexHookEvent) -> Void)?

    init() {}

    /// 启动 Socket Server
    func start(at path: String) {
        // 确保目录存在
        let socketDir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: socketDir) {
            try? FileManager.default.createDirectory(
                atPath: socketDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // 清理旧的 socket 文件
        unlink(path)

        // 创建 Unix Domain Socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }

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

        // Bind
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

    private func startAcceptingConnections() {
        acceptQueue = DispatchQueue(label: "com.eterm.aicli.codex-socket")
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
            let event = try JSONDecoder().decode(CodexHookEvent.self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        } catch {
            // 解析失败，静默处理
        }
    }
}
