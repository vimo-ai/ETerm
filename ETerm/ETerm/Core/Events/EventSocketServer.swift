//
//  EventSocketServer.swift
//  ETerm
//
//  事件网关 - Socket 服务器
//  每个 socket 对应一个事件过滤模式
//

import Foundation

/// 客户端连接
private final class EventConnection {
    let fd: Int32
    let queue: DispatchQueue
    var isValid: Bool = true
    /// 保持 DispatchSource 的强引用，防止被释放
    var readSource: DispatchSourceRead?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// 发送数据
    func send(_ data: Data) -> Bool {
        guard isValid else { return false }

        return data.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress else { return false }
            let result = Darwin.send(fd, pointer, data.count, 0)
            if result < 0 {
                isValid = false
                return false
            }
            return true
        }
    }

    /// 关闭连接
    func close() {
        guard isValid else { return }
        isValid = false
        readSource?.cancel()
        readSource = nil
        Darwin.close(fd)
    }
}

/// 事件 Socket 服务器
///
/// 每个服务器绑定一个 socket 文件，对应一个事件过滤模式。
/// 客户端连接后，服务器会推送匹配的事件。
final class EventSocketServer {

    /// Socket 文件路径
    let socketPath: String

    /// 事件匹配模式
    ///
    /// - "all": 匹配所有事件
    /// - "claude": 匹配所有 claude.* 事件
    /// - "terminal": 匹配所有 terminal.* 事件
    /// - "claude.responseComplete": 精确匹配
    let pattern: String

    private var socketFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var acceptSource: DispatchSourceRead?

    /// 已连接的客户端
    private var connections: [UUID: EventConnection] = [:]
    private let connectionsLock = NSLock()

    init(socketPath: String, pattern: String) {
        self.socketPath = socketPath
        self.pattern = pattern
    }

    // MARK: - Lifecycle

    /// 启动服务器
    func start() -> Bool {
        // 确保目录存在
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: socketDir) {
            try? FileManager.default.createDirectory(
                atPath: socketDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // 清理旧的 socket 文件
        unlink(socketPath)

        // 创建 Unix Domain Socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            return false
        }

        // 设置 socket 地址
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(socketFD)
            socketFD = -1
            return false
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { cString in
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
            return false
        }

        // 设置 socket 文件权限
        chmod(socketPath, 0o600)

        // Listen（backlog = 16，允许更多等待连接）
        guard listen(socketFD, 16) >= 0 else {
            close(socketFD)
            socketFD = -1
            return false
        }

        // 开始接受连接
        startAcceptingConnections()

        return true
    }

    /// 停止服务器
    func stop() {
        // 停止接受新连接
        acceptSource?.cancel()
        acceptSource = nil

        // 关闭所有客户端连接
        connectionsLock.lock()
        for (_, connection) in connections {
            connection.close()
        }
        connections.removeAll()
        connectionsLock.unlock()

        // 关闭服务器 socket
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        // 删除 socket 文件
        unlink(socketPath)
    }

    // MARK: - Connection Handling

    private func startAcceptingConnections() {
        acceptQueue = DispatchQueue(label: "com.eterm.event-socket.\(pattern)")

        acceptSource = DispatchSource.makeReadSource(
            fileDescriptor: socketFD,
            queue: acceptQueue!
        )

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

        // 设置非阻塞模式
        var flags = fcntl(clientFD, F_GETFL)
        flags |= O_NONBLOCK
        fcntl(clientFD, F_SETFL, flags)

        // 设置 SO_NOSIGPIPE 防止 SIGPIPE 信号（macOS）
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // 创建连接对象
        let connectionId = UUID()
        let queue = DispatchQueue(label: "com.eterm.event-connection.\(connectionId.uuidString)")
        let connection = EventConnection(fd: clientFD, queue: queue)

        // 添加到连接列表
        connectionsLock.lock()
        connections[connectionId] = connection
        connectionsLock.unlock()

        // 监听客户端断开
        monitorConnection(id: connectionId, connection: connection)
    }

    /// 监听客户端断开
    private func monitorConnection(id: UUID, connection: EventConnection) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: connection.fd,
            queue: connection.queue
        )

        // 保持强引用，防止 source 被释放导致 cancelHandler 触发
        connection.readSource = source

        source.setEventHandler { [weak self] in
            // 尝试读取，如果读到 0 字节说明客户端断开
            var buffer = [UInt8](repeating: 0, count: 1)
            let bytesRead = read(connection.fd, &buffer, 1)

            if bytesRead == 0 {
                // 客户端正常关闭连接
                self?.removeConnection(id: id)
                source.cancel()
            } else if bytesRead < 0 {
                // 检查是否是 EAGAIN/EWOULDBLOCK（无数据可读，正常情况）
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    // 真正的错误，关闭连接
                    self?.removeConnection(id: id)
                    source.cancel()
                }
                // EAGAIN/EWOULDBLOCK: 无数据，连接仍然有效
            }
            // bytesRead > 0: 忽略客户端发送的数据（事件 socket 是单向推送）
        }

        source.setCancelHandler { [weak self] in
            self?.removeConnection(id: id)
        }

        source.resume()
    }

    private func removeConnection(id: UUID) {
        connectionsLock.lock()
        if let connection = connections.removeValue(forKey: id) {
            connection.close()
        }
        connectionsLock.unlock()
    }

    // MARK: - Broadcasting

    /// 广播事件给所有连接
    ///
    /// - Parameter event: 事件
    func broadcast(_ event: GatewayEvent) {
        // 检查事件是否匹配
        guard shouldBroadcast(event: event.name) else {
            return
        }

        guard let jsonLine = event.toJSONLine(),
              let data = jsonLine.data(using: .utf8) else {
            return
        }

        // 获取所有连接的快照
        connectionsLock.lock()
        let activeConnections = connections.filter { $0.value.isValid }
        connectionsLock.unlock()

        // 向所有连接发送
        for (id, connection) in activeConnections {
            connection.queue.async { [weak self] in
                if !connection.send(data) {
                    self?.removeConnection(id: id)
                }
            }
        }
    }

    /// 检查事件是否匹配此 socket 的模式
    private func shouldBroadcast(event: String) -> Bool {
        switch pattern {
        case "all":
            return true

        case "claude":
            return event.hasPrefix("claude.")

        case "terminal":
            return event.hasPrefix("terminal.")

        default:
            // 精确匹配
            return event == pattern
        }
    }

    /// 当前连接数
    var connectionCount: Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections.count
    }
}
