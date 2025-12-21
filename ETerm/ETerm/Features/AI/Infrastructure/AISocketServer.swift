//
//  AISocketServer.swift
//  ETerm
//
//  Unix Domain Socket 服务器 - 为 Shell 层提供 AI 服务通信
//  使用 POSIX socket API 实现
//

import Foundation

// MARK: - 请求/响应模型

struct CandidateInfo: Decodable, Hashable {
    let cmd: String
    let freq: Int
}

struct AISocketRequest: Decodable {
    let id: String
    let sessionId: String
    let input: String
    let candidates: [CandidateInfo]
    let pwd: String?
    let lastCmd: String?
    let files: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case input
        case candidates
        case pwd
        case lastCmd = "last_cmd"
        case files
    }
}

struct AISocketResponse: Encodable {
    let id: String
    let index: Int
    let status: Status

    enum Status: String, Encodable {
        case ok
        case skip
        case unhealthy
    }
}

// MARK: - 请求处理协议

protocol AISocketRequestHandler: AnyObject {
    func handleRequest(_ request: AISocketRequest) async -> AISocketResponse
}

// MARK: - Socket 服务器

final class AISocketServer {
    static let shared = AISocketServer()

    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var acceptThread: Thread?
    private let queue = DispatchQueue(label: "com.eterm.ai.socket", qos: .userInteractive)

    weak var handler: AISocketRequestHandler?

    private let socketPath: String

    private init() {
        self.socketPath = ETermPaths.aiSocket
    }

    // MARK: - 生命周期

    func start() throws {
        guard !isRunning else { return }

        // 1. 确保目录存在并设置权限
        try ensureSocketDirectory()

        // 2. 清理旧 socket
        cleanupOldSocket()

        // 3. 创建 socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw AISocketError.socketCreationFailed(errno: errno)
        }

        // 4. 设置非阻塞和地址复用
        let flags = fcntl(serverSocket, F_GETFL, 0)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // 5. 绑定地址
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // 复制路径到 sun_path
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let buffer = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            socketPath.withCString { path in
                _ = strcpy(buffer, path)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        guard withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, addrLen)
            }
        }) == 0 else {
            close(serverSocket)
            throw AISocketError.bindFailed(errno: errno)
        }

        // 6. 设置 socket 文件权限（只有当前用户可访问）
        chmod(socketPath, 0o600)

        // 7. 开始监听
        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            throw AISocketError.listenFailed(errno: errno)
        }

        isRunning = true

        // 8. 启动接受连接线程
        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.name = "AISocketServer.Accept"
        acceptThread?.start()

        logInfo("AI Socket 服务已启动: \(socketPath)")
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        cleanupOldSocket()
        logInfo("AI Socket 服务已停止")
    }

    // MARK: - 私有方法

    private func ensureSocketDirectory() throws {
        let socketDir = (socketPath as NSString).deletingLastPathComponent

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: socketDir, isDirectory: &isDirectory)

        if !exists {
            try FileManager.default.createDirectory(
                atPath: socketDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else if isDirectory.boolValue {
            // 确保权限正确
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: socketDir
            )
        }
    }

    private func cleanupOldSocket() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptLoop() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        while isRunning {
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket >= 0 {
                queue.async { [weak self] in
                    self?.handleClient(socket: clientSocket)
                }
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.01)
            } else if isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func handleClient(socket clientSocket: Int32) {
        defer { close(clientSocket) }

        // 设置读取超时
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // 忽略 SIGPIPE，避免客户端关闭连接时崩溃
        var noSigPipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // 读取数据
        var buffer = [CChar](repeating: 0, count: 65536)
        let bytesRead = recv(clientSocket, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { return }

        buffer[bytesRead] = 0
        let text = String(cString: buffer)

        // 按换行符分割（支持多条消息）
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            processLine(line, clientSocket: clientSocket)
        }
    }

    private func processLine(_ line: String, clientSocket: Int32) {
        guard let lineData = line.data(using: .utf8) else { return }

        do {
            let request = try JSONDecoder().decode(AISocketRequest.self, from: lineData)

            guard let handler = handler else {
                sendResponse(AISocketResponse(id: request.id, index: 0, status: .skip), to: clientSocket)
                return
            }

            // 异步处理请求
            let semaphore = DispatchSemaphore(value: 0)
            var response: AISocketResponse?

            Task {
                response = await handler.handleRequest(request)
                semaphore.signal()
            }

            // 等待响应（最多 200ms）
            let waitResult = semaphore.wait(timeout: .now() + 0.2)

            if waitResult == .timedOut {
                sendResponse(AISocketResponse(id: request.id, index: 0, status: .skip), to: clientSocket)
            } else if let response = response {
                sendResponse(response, to: clientSocket)
            }

        } catch {
            sendResponse(AISocketResponse(id: "unknown", index: 0, status: .skip), to: clientSocket)
        }
    }

    private func sendResponse(_ response: AISocketResponse, to clientSocket: Int32) {
        do {
            var data = try JSONEncoder().encode(response)
            data.append(contentsOf: "\n".utf8)

            _ = data.withUnsafeBytes { ptr in
                send(clientSocket, ptr.baseAddress, data.count, 0)
            }
        } catch {
            logError("编码响应失败: \(error)")
        }
    }
}

// MARK: - 错误类型

enum AISocketError: LocalizedError {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let err):
            return "创建 Socket 失败: \(String(cString: strerror(err)))"
        case .bindFailed(let err):
            return "绑定 Socket 地址失败: \(String(cString: strerror(err)))"
        case .listenFailed(let err):
            return "监听 Socket 失败: \(String(cString: strerror(err)))"
        }
    }
}

// MARK: - Logging

private func logInfo(_ message: String) {
    // 日志已禁用
}

private func logError(_ message: String) {
    #if DEBUG
    print("[AISocketServer] ERROR: \(message)")
    #endif
}
