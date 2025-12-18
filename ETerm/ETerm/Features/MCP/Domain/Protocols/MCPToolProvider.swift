//
//  MCPToolProvider.swift
//  ETerm
//
//  MCP Tool 提供者协议 - 插件扩展点
//
//  预留接口，供插件系统扩展 MCP 功能
//

import Foundation

/// MCP Tool 提供者协议
///
/// 插件实现此协议以向 MCP Server 注册自定义 Tools。
///
/// 示例用法（未来实现）:
/// ```swift
/// class TranslationPlugin: MCPToolProvider {
///     var providerId: String { "translation" }
///     var tools: [MCPToolDefinition] {
///         [
///             MCPToolDefinition(
///                 name: "translate",
///                 description: "Translate text",
///                 inputSchema: [...],
///                 handler: { params in ... }
///             )
///         ]
///     }
/// }
/// ```
protocol MCPToolProvider {
    /// 提供者 ID（用于命名空间，如 "translation"）
    var providerId: String { get }

    /// 提供的 Tools 定义
    var tools: [MCPToolDefinition] { get }
}

/// MCP Tool 定义
struct MCPToolDefinition {
    /// Tool 名称（会被加上 providerId 前缀，如 "translation.translate"）
    let name: String

    /// Tool 描述
    let description: String

    /// 输入参数 JSON Schema
    let inputSchema: [String: Any]

    /// Tool 处理器
    let handler: @Sendable (MCPToolInput) async throws -> MCPToolOutput
}

/// MCP Tool 输入
struct MCPToolInput: Sendable {
    /// 原始参数（JSON 解码后的字典）
    let arguments: [String: Any]

    /// 获取字符串参数
    func string(_ key: String) -> String? {
        arguments[key] as? String
    }

    /// 获取整数参数
    func int(_ key: String) -> Int? {
        arguments[key] as? Int
    }

    /// 获取布尔参数
    func bool(_ key: String) -> Bool? {
        arguments[key] as? Bool
    }
}

/// MCP Tool 输出
struct MCPToolOutput: Sendable {
    /// 输出内容（会被序列化为 JSON）
    let content: Any

    /// 是否为错误
    let isError: Bool

    /// 成功输出
    static func success(_ content: Any) -> MCPToolOutput {
        MCPToolOutput(content: content, isError: false)
    }

    /// 错误输出
    static func error(_ message: String) -> MCPToolOutput {
        MCPToolOutput(content: ["error": message], isError: true)
    }
}
