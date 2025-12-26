// IPCMessage.swift
// ETermKit
//
// IPC 消息定义

import Foundation

/// IPC 协议版本
///
/// 用于确保主进程和 Extension Host 的通信兼容
public let IPCProtocolVersion = "1.0.0"

/// IPC 消息
///
/// 主进程与 Extension Host 之间通信的消息格式。
/// 所有消息都必须序列化为 JSON 传输。
public struct IPCMessage: Sendable, Codable, Equatable {

    /// 消息唯一标识符
    ///
    /// 用于关联请求和响应
    public let id: UUID

    /// 协议版本
    ///
    /// 不兼容版本拒绝处理
    public let protocolVersion: String

    /// 消息类型
    public let type: MessageType

    /// 目标/来源插件 ID
    ///
    /// 某些消息类型需要指定插件
    public let pluginId: String?

    /// 消息载荷
    public let payload: [String: AnyCodable]

    /// 时间戳
    public let timestamp: Date

    /// 初始化消息
    public init(
        id: UUID = UUID(),
        protocolVersion: String = IPCProtocolVersion,
        type: MessageType,
        pluginId: String? = nil,
        payload: [String: Any] = [:]
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.type = type
        self.pluginId = pluginId
        self.payload = AnyCodable.wrap(payload)
        self.timestamp = Date()
    }

    /// 获取原始 payload
    public var rawPayload: [String: Any] {
        return AnyCodable.unwrap(payload)
    }

    /// 消息类型
    public enum MessageType: String, Sendable, Codable {
        // MARK: - Host → Plugin

        /// 激活插件
        case activate

        /// 停用插件
        case deactivate

        /// 事件通知
        case event

        /// 命令调用
        case commandInvoke

        /// 服务调用请求
        case serviceCall

        /// 插件请求（Host → Plugin，需要响应）
        case pluginRequest

        // MARK: - Plugin → Host

        /// 更新 ViewModel
        case updateViewModel

        /// 设置 Tab 装饰
        case setTabDecoration

        /// 清除 Tab 装饰
        case clearTabDecoration

        /// 设置 Tab 标题
        case setTabTitle

        /// 清除 Tab 标题
        case clearTabTitle

        /// 写入终端
        case writeTerminal

        /// 获取终端信息
        case getTerminalInfo

        /// 获取所有终端
        case getAllTerminals

        /// 注册服务
        case registerService

        /// 调用服务
        case callService

        /// 发射事件
        case emit

        // MARK: - UI 控制 (Plugin → Host)

        /// 显示底部停靠视图
        case showBottomDock

        /// 隐藏底部停靠视图
        case hideBottomDock

        /// 切换底部停靠视图
        case toggleBottomDock

        /// 显示信息面板
        case showInfoPanel

        /// 隐藏信息面板
        case hideInfoPanel

        /// 显示选中气泡
        case showBubble

        /// 展开气泡
        case expandBubble

        /// 隐藏气泡
        case hideBubble

        // MARK: - 双向

        /// 握手消息（连接建立后发送，单向通知）
        case handshake

        /// 响应（成功）
        case response

        /// 响应（错误）
        case error
    }
}

// MARK: - 便捷构造

extension IPCMessage {

    /// 创建响应消息
    public static func response(
        to request: IPCMessage,
        payload: [String: Any] = [:]
    ) -> IPCMessage {
        return IPCMessage(
            id: request.id,
            type: .response,
            pluginId: request.pluginId,
            payload: payload
        )
    }

    /// 创建错误响应
    public static func error(
        to request: IPCMessage,
        code: String,
        message: String
    ) -> IPCMessage {
        return IPCMessage(
            id: request.id,
            type: .error,
            pluginId: request.pluginId,
            payload: [
                "errorCode": code,
                "errorMessage": message
            ]
        )
    }

    /// 创建事件消息
    public static func event(
        name: String,
        payload: [String: Any],
        targetPluginId: String? = nil
    ) -> IPCMessage {
        var eventPayload = payload
        eventPayload["eventName"] = name
        return IPCMessage(
            type: .event,
            pluginId: targetPluginId,
            payload: eventPayload
        )
    }
}

// MARK: - 序列化

extension IPCMessage {

    /// 序列化为 JSON Data
    public func toJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// 从 JSON Data 反序列化
    public static func from(jsonData: Data) throws -> IPCMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IPCMessage.self, from: jsonData)
    }

    /// 序列化为 JSON 字符串
    public func toJSONString() throws -> String {
        let data = try toJSONData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw IPCSerializationError.invalidEncoding
        }
        return string
    }

    /// 从 JSON 字符串反序列化
    public static func from(jsonString: String) throws -> IPCMessage {
        guard let data = jsonString.data(using: .utf8) else {
            throw IPCSerializationError.invalidEncoding
        }
        return try from(jsonData: data)
    }
}

/// IPC 序列化错误
public enum IPCSerializationError: Error, Sendable {
    case invalidEncoding
}
