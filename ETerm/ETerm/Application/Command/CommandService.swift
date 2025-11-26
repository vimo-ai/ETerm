//
//  CommandService.swift
//  ETerm
//
//  应用层 - 命令服务协议

import Foundation

/// 命令服务 - 命令注册和执行的统一接口
///
/// 该协议定义了插件系统中命令管理的核心能力：
/// - 注册/注销命令
/// - 执行命令
/// - 查询命令
protocol CommandService: AnyObject {
    /// 注册命令
    /// - Parameter command: 要注册的命令
    func register(_ command: Command)

    /// 注销命令
    /// - Parameter id: 要注销的命令 ID
    func unregister(_ id: CommandID)

    /// 执行命令
    /// - Parameters:
    ///   - id: 命令 ID
    ///   - context: 执行上下文
    func execute(_ id: CommandID, context: CommandContext)

    /// 检查命令是否存在
    /// - Parameter id: 命令 ID
    /// - Returns: 是否存在
    func exists(_ id: CommandID) -> Bool

    /// 获取所有已注册的命令
    /// - Returns: 命令列表
    func allCommands() -> [Command]
}
