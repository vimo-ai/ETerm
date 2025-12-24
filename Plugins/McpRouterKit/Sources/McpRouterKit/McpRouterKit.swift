//
//  McpRouterKit.swift
//  McpRouterKit
//
//  MCP Router Swift 桥接库
//  提供 ETerm 插件所需的所有公共 API
//

import Foundation

// MARK: - 公共导出

// 导出所有公共类型，供 ETerm 使用
public typealias MCPRouter = MCPRouterBridge

// 文档注释
/// McpRouterKit - MCP Router Swift 桥接库
///
/// 本库提供了 MCP Router Rust Core 的 Swift 桥接，用于在 ETerm 中集成 MCP Router 功能。
///
/// ## 主要组件
///
/// - `MCPRouterBridge`: Rust dylib 的 Swift 桥接层，提供完整的 FFI 调用封装
/// - `MCPServerConfig`: 服务器配置数据模型
/// - `MCPRouterStatus`: Router 运行状态
/// - `MCPRouterError`: 错误类型定义
///
/// ## 使用示例
///
/// ```swift
/// // 1. 初始化日志（应用启动时调用一次）
/// MCPRouterBridge.initLogging()
///
/// // 2. 创建 Router 实例
/// let router = try MCPRouterBridge()
///
/// // 3. 添加服务器
/// try router.addServer(.http(
///     name: "my-server",
///     url: "http://localhost:3000"
/// ))
///
/// // 4. 启动 HTTP 服务
/// try router.startServer(port: 19104)
///
/// // 5. 查询状态
/// let status = try router.getStatus()
/// print("Running: \(status.isRunning), Servers: \(status.serverCount)")
/// ```
///
/// ## dylib 加载路径
///
/// dylib 会按以下优先级搜索：
/// 1. App Bundle Frameworks 目录（生产环境）
/// 2. Swift Package Bundle Frameworks 目录（开发环境）
/// 3. Rust 项目 target/debug 目录（开发环境 fallback）
/// 4. 环境变量 `MCP_ROUTER_DYLIB_PATH`（自定义路径）
///
public struct McpRouterKit {
    /// 库版本
    public static let version = "1.0.0"

    /// 获取 Rust Core 版本
    public static var coreVersion: String {
        MCPRouterBridge.version
    }
}
