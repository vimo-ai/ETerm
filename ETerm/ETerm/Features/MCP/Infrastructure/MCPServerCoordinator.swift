//
//  MCPServerCoordinator.swift
//  ETerm
//
//  MCP Server 协调器 - HTTP 模式
//
//  基于 Network.framework 实现 MCP over HTTP
//  端口: 11218
//

import Foundation
import Network

/// MCP Server 协调器（单例）
///
/// 职责：
/// - 管理 HTTP MCP Server 生命周期
/// - 处理 JSON-RPC 请求
/// - 注册核心 Tools
///
/// 注意：网络处理在后台线程，只有 Tool 执行才跳到 MainActor
final class MCPServerCoordinator: @unchecked Sendable {
    static let shared = MCPServerCoordinator()

    private let port: UInt16 = 11218
    private var listener: NWListener?
    private var isRunning = false

    // Session 管理
    private var sessions: [String: Date] = [:]

    private init() {}

    // MARK: - Server Lifecycle

    /// 启动 HTTP MCP Server
    func start() {
        guard !isRunning else {
            logWarning("Server already running")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.handleConnection(connection)
                }
            }

            // 在后台队列处理网络，避免阻塞主线程
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            isRunning = true

        } catch {
            logError("Failed to start server: \(error)")
        }
    }

    /// 停止 MCP Server
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        sessions.removeAll()
        logInfo("Server stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logInfo("MCP Server running on http://localhost:\(port)")
        case .failed(let error):
            logError("Server failed: \(error)")
            isRunning = false
        case .cancelled:
            logInfo("Server cancelled")
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

        let dataStream = connection.dataStream()
        var buffer = Data()

        for await data in dataStream {
            buffer.append(data)

            // 尝试解析完整的 HTTP 请求
            while let request = extractCompleteRequest(from: &buffer) {
                await processRequest(data: request, connection: connection)
            }
        }

        connection.cancel()
    }

    /// 从缓冲区提取完整的 HTTP 请求
    /// 返回完整请求数据，并从缓冲区移除已提取的部分
    private func extractCompleteRequest(from buffer: inout Data) -> Data? {
        // 使用字节级别查找 \r\n\r\n 分隔符
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = buffer.range(of: separator) else {
            return nil // 还没收到完整的 headers
        }

        // 提取 headers 部分（字节）
        let headersData = buffer[..<separatorRange.lowerBound]
        guard let headersPart = String(data: headersData, encoding: .utf8) else {
            return nil
        }

        // 解析 Content-Length
        var contentLength = 0
        for line in headersPart.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
                break
            }
        }

        // 计算需要的总字节数（headers + separator + body）
        let headersEndByteIndex = separatorRange.upperBound
        let totalNeeded = headersEndByteIndex + contentLength

        // 检查是否收到了完整的请求
        guard buffer.count >= totalNeeded else {
            return nil // 还没收到完整的 body
        }

        // 提取完整请求
        let completeRequest = buffer.prefix(totalNeeded)
        buffer.removeFirst(totalNeeded)
        // 重要：重新创建 Data，确保后续操作的 indices 从 0 开始
        // Data 切片的 indices 会保留原始位置，导致 range(of:) 返回错误的偏移量
        buffer = Data(buffer)

        return Data(completeRequest)
    }

    // MARK: - Request Processing

    private func processRequest(data: Data, connection: NWConnection) async {
        // 使用字节级别查找 \r\n\r\n 分隔符
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"error\": \"Bad Request\"}")
            return
        }

        // 提取 headers 和 body（字节级别）
        let headersData = data[..<separatorRange.lowerBound]
        let bodyData = data[separatorRange.upperBound...]

        guard let headersString = String(data: headersData, encoding: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"error\": \"Bad Request\"}")
            return
        }

        // 提取请求行
        let headerLines = headersString.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"error\": \"Bad Request\"}")
            return
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"error\": \"Bad Request\"}")
            return
        }

        let httpMethod = String(requestParts[0])

        // 提取 Headers
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        switch httpMethod {
        case "POST":
            await handlePostRequest(bodyData: Data(bodyData), headers: headers, connection: connection)
        case "GET":
            handleGetRequest(headers: headers, connection: connection)
        case "DELETE":
            handleDeleteRequest(headers: headers, connection: connection)
        default:
            sendResponse(connection: connection, statusCode: 405, body: "{\"error\": \"Method Not Allowed\"}")
        }
    }

    // MARK: - POST (JSON-RPC)

    private func handlePostRequest(bodyData: Data, headers: [String: String], connection: NWConnection) async {
        guard !bodyData.isEmpty else {
            sendErrorResponse(connection: connection, id: nil, code: -32700, message: "Parse error: empty body")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            sendErrorResponse(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        guard let method = json["method"] as? String else {
            sendErrorResponse(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let requestId = json["id"] as? Int
        let params = json["params"] as? [String: Any]
        let sessionId = headers["mcp-session-id"]

        // 处理通知（无需响应）
        if requestId == nil || method.hasPrefix("notifications/") {
            sendResponse(connection: connection, statusCode: 202, body: "")
            return
        }

        do {
            let (result, newSessionId) = try await handleMethod(method: method, params: params, sessionId: sessionId)
            sendSuccessResponse(connection: connection, id: requestId, result: result, sessionId: newSessionId)
        } catch {
            sendErrorResponse(connection: connection, id: requestId, code: -32603, message: error.localizedDescription)
        }
    }

    // MARK: - GET (SSE, 暂不支持)

    private func handleGetRequest(headers: [String: String], connection: NWConnection) {
        let sessionId = headers["mcp-session-id"]
        if let sessionId = sessionId, sessions[sessionId] != nil {
            sendResponse(connection: connection, statusCode: 200, body: "", contentType: "text/event-stream", sessionId: sessionId)
        } else {
            sendResponse(connection: connection, statusCode: 404, body: "{\"error\": \"Session not found\"}")
        }
    }

    // MARK: - DELETE (关闭会话)

    private func handleDeleteRequest(headers: [String: String], connection: NWConnection) {
        if let sessionId = headers["mcp-session-id"] {
            sessions.removeValue(forKey: sessionId)
        }
        sendResponse(connection: connection, statusCode: 200, body: "", keepAlive: false)
    }

    // MARK: - JSON-RPC Method Handler

    private func handleMethod(method: String, params: [String: Any]?, sessionId: String?) async throws -> (result: [String: Any], sessionId: String?) {
        switch method {
        case "initialize":
            let newSessionId = UUID().uuidString
            sessions[newSessionId] = Date()

            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "serverInfo": [
                    "name": "eterm",
                    "version": "1.0.0"
                ],
                "capabilities": [
                    "tools": [:]
                ]
            ]
            return (result, newSessionId)

        case "tools/list":
            let tools: [[String: Any]] = [
                [
                    "name": "list_sessions",
                    "description": "List all ETerm windows, pages, panels, and tabs with their hierarchy and IDs",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:],
                        "required": []
                    ]
                ],
                [
                    "name": "switch_focus",
                    "description": "Switch focus to a specific page or tab. Use list_sessions first to get valid IDs.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string", "description": "Target type: 'page' or 'tab'"],
                            "windowNumber": ["type": "integer", "description": "Window number (from list_sessions)"],
                            "pageId": ["type": "string", "description": "Page UUID (required when type is 'page')"],
                            "panelId": ["type": "string", "description": "Panel UUID (required when type is 'tab')"],
                            "tabId": ["type": "string", "description": "Tab UUID (required when type is 'tab')"]
                        ],
                        "required": ["type", "windowNumber"]
                    ]
                ],
                [
                    "name": "send_input",
                    "description": "Send text input to a specific terminal. Use list_sessions to get terminalId.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "terminalId": ["type": "integer", "description": "Terminal ID (from list_sessions)"],
                            "text": ["type": "string", "description": "Text to send (use \\n for Enter key)"]
                        ],
                        "required": ["terminalId", "text"]
                    ]
                ]
            ]
            return (["tools": tools], nil)

        case "tools/call":
            guard let toolName = params?["name"] as? String else {
                throw MCPServerError.invalidParams("Missing tool name")
            }

            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            let content = try await callTool(name: toolName, arguments: arguments)

            return (["content": [["type": "text", "text": content]]], nil)

        default:
            throw MCPServerError.methodNotFound(method)
        }
    }

    // MARK: - Tool Execution

    private func callTool(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "list_sessions":
            // 需要访问 UI，在主线程执行
            return await MainActor.run {
                ListSessionsTool.executeAsJSON()
            }

        case "switch_focus":
            let target = try parseArguments(arguments)
            // 需要操作 UI，在主线程执行
            return await MainActor.run {
                let response = SwitchFocusTool.execute(target: target)
                return SwitchFocusTool.responseToJSON(response)
            }

        case "send_input":
            guard let terminalId = arguments["terminalId"] as? Int else {
                throw MCPServerError.invalidParams("Missing or invalid 'terminalId'")
            }
            guard let text = arguments["text"] as? String else {
                throw MCPServerError.invalidParams("Missing or invalid 'text'")
            }
            // 需要操作 UI，在主线程执行
            return await MainActor.run {
                let response = SendInputTool.execute(terminalId: terminalId, text: text)
                return SendInputTool.responseToJSON(response)
            }

        default:
            throw MCPServerError.toolNotFound(name)
        }
    }

    private func parseArguments(_ arguments: [String: Any]) throws -> MCPFocusTarget {
        guard let typeStr = arguments["type"] as? String,
              let targetType = MCPFocusTarget.TargetType(rawValue: typeStr) else {
            throw MCPServerError.invalidParams("Missing or invalid 'type' parameter")
        }

        guard let windowNumber = arguments["windowNumber"] as? Int else {
            throw MCPServerError.invalidParams("Missing or invalid 'windowNumber' parameter")
        }

        return MCPFocusTarget(
            type: targetType,
            windowNumber: windowNumber,
            pageId: arguments["pageId"] as? String,
            panelId: arguments["panelId"] as? String,
            tabId: arguments["tabId"] as? String
        )
    }

    // MARK: - Response Helpers

    private func sendSuccessResponse(connection: NWConnection, id: Int?, result: [String: Any], sessionId: String? = nil) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id {
            response["id"] = id
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: response),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendResponse(connection: connection, statusCode: 200, body: jsonString, contentType: "application/json", sessionId: sessionId)
        }
    }

    private func sendErrorResponse(connection: NWConnection, id: Int?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id = id {
            response["id"] = id
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: response),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendResponse(connection: connection, statusCode: 200, body: jsonString, contentType: "application/json")
        }
    }

    private func sendResponse(
        connection: NWConnection,
        statusCode: Int,
        body: String,
        contentType: String = "application/json",
        keepAlive: Bool = true,
        sessionId: String? = nil
    ) {
        var headerLines = [
            "HTTP/1.1 \(statusCode) OK",
            "Content-Type: \(contentType); charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Connection: \(keepAlive ? "keep-alive" : "close")"
        ]

        if let sessionId = sessionId {
            headerLines.append("Mcp-Session-Id: \(sessionId)")
        }

        let responseString = headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body

        if let responseData = responseString.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                if !keepAlive {
                    connection.cancel()
                }
            })
        }
    }

    // MARK: - Logging

    private func logInfo(_ message: String) {
        // 日志已禁用
    }

    private func logWarning(_ message: String) {
        #if DEBUG
        print("[MCP][WARN] \(message)")
        #endif
    }

    private func logError(_ message: String) {
        #if DEBUG
        print("[MCP][ERROR] \(message)")
        #endif
    }
}

// MARK: - Errors

enum MCPServerError: Error, LocalizedError {
    case invalidParams(String)
    case methodNotFound(String)
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let msg): return "Invalid params: \(msg)"
        case .methodNotFound(let method): return "Method not found: \(method)"
        case .toolNotFound(let tool): return "Tool not found: \(tool)"
        }
    }
}

// MARK: - NWConnection AsyncStream Extension

extension NWConnection {
    func dataStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            func scheduleReceive() {
                self.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if error != nil {
                        continuation.finish()
                        return
                    }

                    if let data = data, !data.isEmpty {
                        continuation.yield(data)
                    }

                    if isComplete && (data == nil || data!.isEmpty) {
                        continuation.finish()
                    } else {
                        scheduleReceive()
                    }
                }
            }

            scheduleReceive()
        }
    }
}
