//
//  TerminalPoolProtocol.swift
//  ETerm
//
//  终端池协议
//
//  定义终端池的基本接口，支持多种实现：
//  - MockTerminalPool: 测试环境的模拟实现
//  - TerminalPoolWrapper: 生产环境的真实实现
//

import Foundation

/// 终端池协议
///
/// 定义终端池的核心功能：创建、销毁、查询终端实例。
protocol TerminalPoolProtocol: AnyObject {
    /// 创建新终端
    ///
    /// - Parameters:
    ///   - cols: 列数
    ///   - rows: 行数
    ///   - shell: Shell 程序路径
    /// - Returns: 终端 ID，失败返回 -1
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int

    /// 关闭终端
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    @discardableResult
    func closeTerminal(_ terminalId: Int) -> Bool

    /// 获取终端数量
    ///
    /// - Returns: 当前存活的终端数量
    func getTerminalCount() -> Int
}
