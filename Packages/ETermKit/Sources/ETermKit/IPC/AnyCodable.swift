// AnyCodable.swift
// ETermKit
//
// 可序列化的 Any 类型包装器

import Foundation

/// 可序列化的 Any 类型包装器
///
/// 用于在 IPC 消息中传递动态类型的数据。
/// 支持的类型：nil, Bool, Int, Double, String, Array, Dictionary
///
/// 注意：使用 @unchecked Sendable 因为存储的基本类型实际上都是 Sendable
public struct AnyCodable: @unchecked Sendable, Codable, Equatable {

    /// 包装的值
    public let value: Any

    /// 初始化
    public init(_ value: Any) {
        self.value = value
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported type for AnyCodable"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported type for AnyCodable: \(type(of: value))"
                )
            )
        }
    }

    // MARK: - Equatable

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull):
            return true
        case let (l as Bool, r as Bool):
            return l == r
        case let (l as Int, r as Int):
            return l == r
        case let (l as Double, r as Double):
            return l == r
        case let (l as String, r as String):
            return l == r
        case let (l as [Any], r as [Any]):
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { AnyCodable($0) == AnyCodable($1) }
        case let (l as [String: Any], r as [String: Any]):
            guard l.count == r.count else { return false }
            return l.keys.allSatisfy { key in
                guard let lv = l[key], let rv = r[key] else { return false }
                return AnyCodable(lv) == AnyCodable(rv)
            }
        default:
            return false
        }
    }
}

// MARK: - 便捷转换

extension AnyCodable {

    /// 将 [String: Any] 转换为 [String: AnyCodable]
    public static func wrap(_ dictionary: [String: Any]) -> [String: AnyCodable] {
        return dictionary.mapValues { AnyCodable($0) }
    }

    /// 将 [String: AnyCodable] 转换为 [String: Any]
    public static func unwrap(_ dictionary: [String: AnyCodable]) -> [String: Any] {
        return dictionary.mapValues { $0.value }
    }
}
