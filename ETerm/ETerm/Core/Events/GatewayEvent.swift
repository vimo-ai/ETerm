//
//  GatewayEvent.swift
//  ETerm
//
//  事件网关 - 事件数据结构
//

import Foundation

/// 网关事件
struct GatewayEvent {
    /// 事件名称（如 "claude.responseComplete"）
    let name: String

    /// 事件时间戳
    let timestamp: Date

    /// 事件载荷
    let payload: [String: Any]

    /// 转换为 JSON Line 字符串
    ///
    /// 格式：`{"event":"name","ts":1234567890,"payload":{...}}\n`
    func toJSONLine() -> String? {
        // 构建可序列化的字典
        var dict: [String: Any] = [
            "event": name,
            "ts": Int(timestamp.timeIntervalSince1970)
        ]

        // payload 需要确保可序列化
        if JSONSerialization.isValidJSONObject(payload) {
            dict["payload"] = payload
        } else {
            // 过滤不可序列化的值
            dict["payload"] = sanitizePayload(payload)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ) else {
            return nil
        }

        guard var jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        // 添加换行符
        jsonString.append("\n")
        return jsonString
    }

    /// 清理 payload，移除不可序列化的值
    private func sanitizePayload(_ dict: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]

        for (key, value) in dict {
            if let stringValue = value as? String {
                result[key] = stringValue
            } else if let intValue = value as? Int {
                result[key] = intValue
            } else if let doubleValue = value as? Double {
                result[key] = doubleValue
            } else if let boolValue = value as? Bool {
                result[key] = boolValue
            } else if let arrayValue = value as? [Any] {
                result[key] = sanitizeArray(arrayValue)
            } else if let dictValue = value as? [String: Any] {
                result[key] = sanitizePayload(dictValue)
            }
            // 其他类型忽略
        }

        return result
    }

    /// 清理数组
    private func sanitizeArray(_ array: [Any]) -> [Any] {
        return array.compactMap { element -> Any? in
            if let stringValue = element as? String {
                return stringValue
            } else if let intValue = element as? Int {
                return intValue
            } else if let doubleValue = element as? Double {
                return doubleValue
            } else if let boolValue = element as? Bool {
                return boolValue
            } else if let dictValue = element as? [String: Any] {
                return sanitizePayload(dictValue)
            } else if let arrayValue = element as? [Any] {
                return sanitizeArray(arrayValue)
            }
            return nil
        }
    }
}

// MARK: - Event Type

extension GatewayEvent {
    /// 事件类型
    enum EventType: String, CaseIterable {
        // Claude 相关
        case claudeSessionStart = "claude.sessionStart"
        case claudeResponseComplete = "claude.responseComplete"
        case claudeSessionEnd = "claude.sessionEnd"
        case claudeWaitingInput = "claude.waitingInput"
        case claudePromptSubmit = "claude.promptSubmit"

        // 终端相关
        case terminalCreated = "terminal.created"
        case terminalClosed = "terminal.closed"

        /// 获取事件类别（用于 socket 路径匹配）
        var category: String {
            return rawValue.components(separatedBy: ".").first ?? rawValue
        }

        /// 获取事件名称（不含类别）
        var shortName: String {
            let components = rawValue.components(separatedBy: ".")
            return components.dropFirst().joined(separator: ".")
        }
    }
}
