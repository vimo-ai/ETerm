//
//  VlaudeDaemonClient.swift
//  ETerm
//
//  Socket.IO Client，连接 vlaude-daemon 的 /eterm namespace

import Foundation
import SocketIO

/// 输入命令类型
enum VlaudeInputCommand {
    case input(String)       // 文本输入
    case controlKey(String)  // 控制序列，直接写入终端

    /// 从字典解析
    static func from(dict: [String: Any]) -> VlaudeInputCommand? {
        if let text = dict["input"] as? String {
            return .input(text)
        }
        if let key = dict["controlKey"] as? String {
            return .controlKey(key)
        }
        return nil
    }

    /// 转换为终端输入序列
    var terminalSequence: String {
        switch self {
        case .input(let text):
            return text
        case .controlKey(let sequence):
            return sequence  // 直接返回，调用方传什么就写什么
        }
    }
}

protocol VlaudeDaemonClientDelegate: AnyObject {
    func daemonClient(_ client: VlaudeDaemonClient, didReceiveInject sessionId: String, terminalId: Int, text: String)
    func daemonClient(_ client: VlaudeDaemonClient, didReceiveMobileViewing sessionId: String, isViewing: Bool)
    func daemonClient(_ client: VlaudeDaemonClient, didReceiveCreateSession projectPath: String, prompt: String?, requestId: String?)
    func daemonClientDidConnect(_ client: VlaudeDaemonClient)
}

final class VlaudeDaemonClient {
    weak var delegate: VlaudeDaemonClientDelegate?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var isConnected = false

    private let daemonURL = URL(string: "http://localhost:10008")!

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }

        // 创建 SocketManager，配置 /eterm namespace
        manager = SocketManager(socketURL: daemonURL, config: [
            .log(false),
            .compress,
            .secure(false),
            .reconnects(true),
            .reconnectWait(5),
            .reconnectAttempts(-1)  // 无限重连
        ])

        socket = manager?.socket(forNamespace: "/eterm")

        setupEventHandlers()

        socket?.connect()
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        isConnected = false
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        // 连接成功
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            self.isConnected = true
            self.delegate?.daemonClientDidConnect(self)
        }

        // 断开连接
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.isConnected = false
        }

        // 连接错误
        socket.on(clientEvent: .error) { data, _ in
        }

        // 重连中
        socket.on(clientEvent: .reconnectAttempt) { data, _ in
        }

        // 业务事件：注入消息
        socket.on("session:inject") { [weak self] data, _ in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let terminalId = dict["terminalId"] as? Int,
                  let text = dict["text"] as? String else {
                return
            }
            self.delegate?.daemonClient(self, didReceiveInject: sessionId, terminalId: terminalId, text: text)
        }

        // 业务事件：Mobile 查看状态
        socket.on("mobile:viewing") { [weak self] data, _ in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let isViewing = dict["isViewing"] as? Bool else {
                return
            }
            self.delegate?.daemonClient(self, didReceiveMobileViewing: sessionId, isViewing: isViewing)
        }

        // 业务事件：创建新会话
        socket.on("session:create") { [weak self] data, _ in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let projectPath = dict["projectPath"] as? String else {
                return
            }
            let prompt = dict["prompt"] as? String
            let requestId = dict["requestId"] as? String
            self.delegate?.daemonClient(self, didReceiveCreateSession: projectPath, prompt: prompt, requestId: requestId)
        }
    }

    // MARK: - Send Messages

    func reportSessionAvailable(sessionId: String, terminalId: Int) {
        guard isConnected else {
            return
        }

        socket?.emit("session:available", [
            "sessionId": sessionId,
            "terminalId": terminalId
        ])
    }

    func reportSessionUnavailable(sessionId: String) {
        guard isConnected else {
            return
        }

        socket?.emit("session:unavailable", [
            "sessionId": sessionId
        ])
    }

    /// 上报会话创建完成（带 requestId）
    func reportSessionCreated(requestId: String, sessionId: String, projectPath: String) {
        guard isConnected else {
            return
        }


        socket?.emit("session:created", [
            "requestId": requestId,
            "sessionId": sessionId,
            "projectPath": projectPath
        ])
    }
}
