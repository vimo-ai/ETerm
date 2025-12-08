//
//  VlaudeDaemonClient.swift
//  ETerm
//
//  Socket.IO Client，连接 vlaude-daemon 的 /eterm namespace

import Foundation
import SocketIO

protocol VlaudeDaemonClientDelegate: AnyObject {
    func daemonClient(_ client: VlaudeDaemonClient, didReceiveInject sessionId: String, terminalId: Int, text: String)
    func daemonClient(_ client: VlaudeDaemonClient, didReceiveMobileViewing sessionId: String, isViewing: Bool)
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
        print("🔌 [VlaudeDaemonClient] 正在连接 daemon...")
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        isConnected = false
        print("🔌 [VlaudeDaemonClient] 已断开")
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket = socket else { return }

        // 连接成功
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            self?.isConnected = true
            print("✅ [VlaudeDaemonClient] 已连接到 daemon")
        }

        // 断开连接
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.isConnected = false
            print("🔌 [VlaudeDaemonClient] 连接已断开")
        }

        // 连接错误
        socket.on(clientEvent: .error) { data, _ in
            print("❌ [VlaudeDaemonClient] 连接错误: \(data)")
        }

        // 重连中
        socket.on(clientEvent: .reconnectAttempt) { data, _ in
            print("🔄 [VlaudeDaemonClient] 正在重连...")
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
    }

    // MARK: - Send Messages

    func reportSessionAvailable(sessionId: String, terminalId: Int) {
        guard isConnected else {
            print("⚠️ [VlaudeDaemonClient] 未连接，无法发送消息")
            return
        }

        socket?.emit("session:available", [
            "sessionId": sessionId,
            "terminalId": terminalId
        ])
    }

    func reportSessionUnavailable(sessionId: String) {
        guard isConnected else {
            print("⚠️ [VlaudeDaemonClient] 未连接，无法发送消息")
            return
        }

        socket?.emit("session:unavailable", [
            "sessionId": sessionId
        ])
    }
}
