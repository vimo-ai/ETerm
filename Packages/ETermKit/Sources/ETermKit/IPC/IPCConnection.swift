// IPCConnection.swift
// ETermKit
//
// IPC 连接管理 - Unix Domain Socket + Length-prefixed framing

import Foundation

/// IPC 连接状态
public enum IPCConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    public static func == (lhs: IPCConnectionState, rhs: IPCConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected): return true
        case (.connecting, .connecting): return true
        case (.connected, .connected): return true
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}

/// IPC 连接配置
public struct IPCConnectionConfig: Sendable {
    /// Socket 路径
    public let socketPath: String

    /// 请求超时时间（秒）
    public let requestTimeout: TimeInterval

    /// 心跳间隔（秒），0 表示禁用
    public let heartbeatInterval: TimeInterval

    /// 重连延迟（秒）
    public let reconnectDelay: TimeInterval

    /// 最大消息大小（字节）
    public let maxMessageSize: Int

    public init(
        socketPath: String,
        requestTimeout: TimeInterval = 30,
        heartbeatInterval: TimeInterval = 10,
        reconnectDelay: TimeInterval = 1,
        maxMessageSize: Int = 10 * 1024 * 1024  // 10MB
    ) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
        self.heartbeatInterval = heartbeatInterval
        self.reconnectDelay = reconnectDelay
        self.maxMessageSize = maxMessageSize
    }

    /// 默认 socket 路径
    public static func defaultSocketPath(processId: Int32? = nil) -> String {
        let pid = processId ?? getpid()
        return "/tmp/eterm-plugin-\(pid).sock"
    }
}

/// IPC 连接错误
public enum IPCConnectionError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case connectFailed(Int32)
    case readFailed(Int32)
    case writeFailed(Int32)
    case messageTooLarge(Int)
    case invalidMessageLength
    case timeout
    case protocolVersionMismatch(String, String)
    case connectionClosed
    case socketPathTooLong(Int, Int)  // (actual, max)
}

/// Unix socket path 最大长度 (macOS: 104, Linux: 108)
private let maxSocketPathLength = 104 - 1  // 减 1 为 null 终止符预留空间

/// IPC 连接
///
/// 提供 Unix Domain Socket 上的双向通信能力。
/// 使用 4 字节 length-prefixed framing 进行消息分帧。
///
/// 消息格式：
/// ```
/// +----------------+------------------+
/// | Length (4B BE) | JSON Message     |
/// +----------------+------------------+
/// ```
public actor IPCConnection {

    // MARK: - Properties

    private let config: IPCConnectionConfig
    private var socketFD: Int32 = -1
    private var state: IPCConnectionState = .disconnected

    /// 待处理的请求（等待响应）
    private var pendingRequests: [UUID: CheckedContinuation<IPCMessage, Error>] = [:]

    /// 消息处理回调
    private var messageHandler: ((IPCMessage) async -> Void)?

    // MARK: - Init

    public init(config: IPCConnectionConfig) {
        self.config = config
    }

    deinit {
        if socketFD >= 0 {
            close(socketFD)
        }
    }

    // MARK: - Public API

    /// 获取当前状态
    public func getState() -> IPCConnectionState {
        return state
    }

    /// 设置消息处理器
    public func setMessageHandler(_ handler: @escaping (IPCMessage) async -> Void) {
        self.messageHandler = handler
    }

    /// 作为客户端连接到服务端
    public func connect() async throws {
        guard case .disconnected = state else { return }

        // 检查 socket 路径长度
        let pathLength = config.socketPath.utf8.count
        guard pathLength <= maxSocketPathLength else {
            throw IPCConnectionError.socketPathTooLong(pathLength, maxSocketPathLength)
        }

        state = .connecting

        // 创建 socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            let err = errno
            state = .error("Socket creation failed: \(err)")
            throw IPCConnectionError.socketCreationFailed(err)
        }

        // 设置非阻塞
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        // 连接
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = config.socketPath.withCString { cstr in
                strcpy(ptr, cstr)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result < 0 {
            let connectErrno = errno
            if connectErrno == EINPROGRESS {
                // 非阻塞连接进行中，需等待完成并验证结果
                try await waitForConnect()
            } else {
                close(socketFD)
                socketFD = -1
                state = .error("Connect failed: \(connectErrno)")
                throw IPCConnectionError.connectFailed(connectErrno)
            }
        }

        state = .connected
        // 注意：不在这里启动 receiveLoop，避免阻塞 actor
        // 调用者应先设置 messageHandler，再调用 startReceiving()
    }

    /// 作为服务端监听连接
    public func listen() async throws -> IPCConnection {
        // 检查 socket 路径长度
        let pathLength = config.socketPath.utf8.count
        guard pathLength <= maxSocketPathLength else {
            throw IPCConnectionError.socketPathTooLong(pathLength, maxSocketPathLength)
        }

        // 删除旧的 socket 文件
        unlink(config.socketPath)

        // 创建 socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCConnectionError.socketCreationFailed(errno)
        }

        // 绑定
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = config.socketPath.withCString { cstr in
                strcpy(ptr, cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            let err = errno
            close(socketFD)
            throw IPCConnectionError.bindFailed(err)
        }

        // 监听
        guard Darwin.listen(socketFD, 1) >= 0 else {
            let err = errno
            close(socketFD)
            throw IPCConnectionError.listenFailed(err)
        }

        // 接受连接
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            let err = errno
            close(socketFD)
            throw IPCConnectionError.acceptFailed(err)
        }

        // 创建客户端连接对象
        let clientConnection = IPCConnection(config: config)
        await clientConnection.setSocketFD(clientFD)

        return clientConnection
    }

    /// 发送消息（不等待响应）
    public func send(_ message: IPCMessage) async throws {
        guard socketFD >= 0, case .connected = state else {
            throw IPCConnectionError.notConnected
        }

        let data = try message.toJSONData()
        try await writeFrame(data)
    }

    /// 发送请求并等待响应
    public func request(_ message: IPCMessage) async throws -> IPCMessage {
        guard socketFD >= 0, case .connected = state else {
            throw IPCConnectionError.notConnected
        }

        // 发送请求
        try await send(message)

        // 等待响应（带超时）
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[message.id] = continuation

            // 设置超时
            Task {
                try await Task.sleep(nanoseconds: UInt64(config.requestTimeout * 1_000_000_000))
                if let cont = pendingRequests.removeValue(forKey: message.id) {
                    cont.resume(throwing: IPCConnectionError.timeout)
                }
            }
        }
    }

    /// 断开连接
    public func disconnect() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        state = .disconnected

        // 取消所有待处理请求
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: IPCConnectionError.connectionClosed)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Private

    /// 等待非阻塞连接完成并验证结果
    private func waitForConnect() async throws {
        // 使用 poll 等待 socket 可写（表示连接完成或失败）
        var pfd = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(config.requestTimeout * 1000)

        let pollResult = poll(&pfd, 1, timeoutMs)

        if pollResult < 0 {
            let err = errno
            close(socketFD)
            socketFD = -1
            state = .error("Poll failed: \(err)")
            throw IPCConnectionError.connectFailed(err)
        }

        if pollResult == 0 {
            // 超时
            close(socketFD)
            socketFD = -1
            state = .error("Connect timeout")
            throw IPCConnectionError.timeout
        }

        // poll 返回后，用 getsockopt(SO_ERROR) 检查实际连接结果
        var soError: Int32 = 0
        var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
        let optResult = getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen)

        if optResult < 0 {
            let err = errno
            close(socketFD)
            socketFD = -1
            state = .error("getsockopt failed: \(err)")
            throw IPCConnectionError.connectFailed(err)
        }

        if soError != 0 {
            close(socketFD)
            socketFD = -1
            state = .error("Connect failed: \(soError)")
            throw IPCConnectionError.connectFailed(soError)
        }

        // soError == 0 表示连接成功
    }

    /// 设置已连接的 socket FD（供 IPCServer 使用）
    internal func setSocketFD(_ fd: Int32) {
        self.socketFD = fd
        self.state = .connected

        // 设置非阻塞
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // 注意：不在这里启动 receiveLoop，避免阻塞 actor
        // 调用者应先设置 messageHandler，再调用 startReceiving()
    }

    /// 启动接收循环
    ///
    /// 应在设置完 messageHandler 后调用。
    /// 这避免了 receiveLoop 阻塞导致 setMessageHandler 无法执行的问题。
    public func startReceiving() {
        Task {
            await receiveLoop()
        }
    }

    /// 接收循环
    private func receiveLoop() async {
        while socketFD >= 0, case .connected = state {
            do {
                let message = try await readMessage()
                await handleReceivedMessage(message)
            } catch {
                if case .connectionClosed = error as? IPCConnectionError {
                    state = .disconnected
                    break
                }
                // 其他错误继续尝试
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    /// 处理收到的消息
    private func handleReceivedMessage(_ message: IPCMessage) async {
        // 检查是否是响应消息
        if message.type == .response || message.type == .error {
            if let continuation = pendingRequests.removeValue(forKey: message.id) {
                continuation.resume(returning: message)
                return
            }
        }

        // 调用消息处理器
        await messageHandler?(message)
    }

    /// 写入一帧数据
    private func writeFrame(_ data: Data) async throws {
        guard data.count <= config.maxMessageSize else {
            throw IPCConnectionError.messageTooLarge(data.count)
        }

        // 构造帧：4 字节长度（大端）+ 数据
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)

        // 循环写入，处理部分写入和 EAGAIN
        try await writeExact(frame)
    }

    /// 精确写入指定数据（在后台线程执行阻塞 I/O）
    private func writeExact(_ data: Data) async throws {
        let fd = self.socketFD

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                var totalWritten = 0
                let count = data.count

                while totalWritten < count {
                    let remaining = count - totalWritten
                    let bytesWritten = data.withUnsafeBytes { buffer in
                        write(fd, buffer.baseAddress!.advanced(by: totalWritten), remaining)
                    }

                    if bytesWritten < 0 {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK {
                            // 使用 poll 等待可写
                            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            let pollResult = poll(&pfd, 1, 1000) // 1 秒超时
                            if pollResult < 0 {
                                continuation.resume(throwing: IPCConnectionError.writeFailed(errno))
                                return
                            }
                            continue
                        }
                        continuation.resume(throwing: IPCConnectionError.writeFailed(err))
                        return
                    } else if bytesWritten == 0 {
                        continuation.resume(throwing: IPCConnectionError.connectionClosed)
                        return
                    }

                    totalWritten += bytesWritten
                }

                continuation.resume()
            }
        }
    }

    /// 读取一条消息
    private func readMessage() async throws -> IPCMessage {
        // 读取长度（4 字节）
        let lengthData = try await readExact(4)
        let length = lengthData.withUnsafeBytes { buffer in
            UInt32(bigEndian: buffer.load(as: UInt32.self))
        }

        guard length > 0, length <= config.maxMessageSize else {
            throw IPCConnectionError.invalidMessageLength
        }

        // 读取消息体
        let messageData = try await readExact(Int(length))
        let message = try IPCMessage.from(jsonData: messageData)

        // 验证协议版本
        try validateProtocolVersion(message.protocolVersion)

        return message
    }

    /// 验证协议版本兼容性
    private func validateProtocolVersion(_ version: String) throws {
        // 解析主版本号
        let currentParts = IPCProtocolVersion.split(separator: ".").compactMap { Int($0) }
        let messageParts = version.split(separator: ".").compactMap { Int($0) }

        guard currentParts.count >= 1, messageParts.count >= 1 else {
            throw IPCConnectionError.protocolVersionMismatch(version, IPCProtocolVersion)
        }

        // 主版本号必须一致
        if currentParts[0] != messageParts[0] {
            throw IPCConnectionError.protocolVersionMismatch(version, IPCProtocolVersion)
        }

        // 次版本号：消息版本不能高于当前版本
        let currentMinor = currentParts.count > 1 ? currentParts[1] : 0
        let messageMinor = messageParts.count > 1 ? messageParts[1] : 0
        if messageMinor > currentMinor {
            throw IPCConnectionError.protocolVersionMismatch(version, IPCProtocolVersion)
        }
    }

    /// 精确读取指定字节数（在后台线程执行阻塞 I/O）
    private func readExact(_ count: Int) async throws -> Data {
        let fd = self.socketFD

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = Data(count: count)
                var totalRead = 0

                while totalRead < count {
                    let remaining = count - totalRead
                    let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                        read(fd, ptr.baseAddress!.advanced(by: totalRead), remaining)
                    }

                    if bytesRead < 0 {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK {
                            // 使用 poll 等待可读
                            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                            let pollResult = poll(&pfd, 1, 1000) // 1 秒超时
                            if pollResult < 0 {
                                continuation.resume(throwing: IPCConnectionError.readFailed(errno))
                                return
                            }
                            continue
                        }
                        continuation.resume(throwing: IPCConnectionError.readFailed(err))
                        return
                    } else if bytesRead == 0 {
                        continuation.resume(throwing: IPCConnectionError.connectionClosed)
                        return
                    }

                    totalRead += bytesRead
                }

                continuation.resume(returning: buffer)
            }
        }
    }
}

// MARK: - Convenience Extensions

extension IPCConnection {

    /// 创建客户端连接
    public static func client(socketPath: String) async throws -> IPCConnection {
        let config = IPCConnectionConfig(socketPath: socketPath)
        let connection = IPCConnection(config: config)
        try await connection.connect()
        return connection
    }

    /// 创建服务端并等待连接
    /// - Note: 如需支持重连，请使用 `IPCServer` 类
    public static func server(socketPath: String) async throws -> IPCConnection {
        let config = IPCConnectionConfig(socketPath: socketPath)
        let listener = IPCConnection(config: config)
        return try await listener.listen()
    }
}

// MARK: - IPC Server (支持重连)

/// IPC 服务端
///
/// 提供可重复接受连接的服务端能力。
/// 与 `IPCConnection.listen()` 不同，此类可以持续接受新连接。
public actor IPCServer {

    private let config: IPCConnectionConfig
    private var listenerFD: Int32 = -1
    private var isListening = false

    public init(config: IPCConnectionConfig) {
        self.config = config
    }

    deinit {
        if listenerFD >= 0 {
            close(listenerFD)
        }
    }

    /// 开始监听
    public func start() async throws {
        guard !isListening else { return }

        // 检查 socket 路径长度
        let pathLength = config.socketPath.utf8.count
        guard pathLength <= maxSocketPathLength else {
            throw IPCConnectionError.socketPathTooLong(pathLength, maxSocketPathLength)
        }

        // 删除旧的 socket 文件
        unlink(config.socketPath)

        // 创建 socket
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw IPCConnectionError.socketCreationFailed(errno)
        }

        // 绑定
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = config.socketPath.withCString { cstr in
                strcpy(ptr, cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenerFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            let err = errno
            close(listenerFD)
            listenerFD = -1
            throw IPCConnectionError.bindFailed(err)
        }

        // 监听（backlog 设为 5 支持多个待处理连接）
        guard Darwin.listen(listenerFD, 5) >= 0 else {
            let err = errno
            close(listenerFD)
            listenerFD = -1
            throw IPCConnectionError.listenFailed(err)
        }

        isListening = true
    }

    /// 接受下一个连接
    ///
    /// 可以多次调用以接受多个客户端连接，支持客户端重连。
    public func acceptConnection() async throws -> IPCConnection {
        guard isListening, listenerFD >= 0 else {
            throw IPCConnectionError.notConnected
        }

        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(listenerFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            throw IPCConnectionError.acceptFailed(errno)
        }

        let clientConnection = IPCConnection(config: config)
        await clientConnection.setSocketFD(clientFD)

        return clientConnection
    }

    /// 停止监听
    public func stop() {
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
        isListening = false
        unlink(config.socketPath)
    }
}
