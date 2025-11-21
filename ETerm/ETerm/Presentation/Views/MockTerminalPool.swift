//
//  MockTerminalPool.swift
//  ETerm
//
//  模拟终端池 - 用于测试环境
//
//  职责：
//  - 模拟终端的创建和销毁
//  - 跟踪终端生命周期
//  - 检测内存泄露
//

import Foundation

/// 模拟终端池
///
/// 在测试环境中模拟 TerminalPoolWrapper 的行为，
/// 确保终端生命周期管理逻辑正确。
class MockTerminalPool: TerminalPoolProtocol {
    // MARK: - State

    /// 下一个终端 ID
    private var nextTerminalId: Int = 1

    /// 存活的终端 ID 集合
    private var aliveTerminals: Set<Int> = []

    /// 创建的终端总数（用于统计）
    private var totalCreated: Int = 0

    /// 销毁的终端总数（用于统计）
    private var totalDestroyed: Int = 0

    // MARK: - Lifecycle

    init() {
    }

    deinit {
    }

    // MARK: - Terminal Management

    /// 创建新终端
    ///
    /// - Parameters:
    ///   - cols: 列数
    ///   - rows: 行数
    ///   - shell: Shell 路径
    /// - Returns: 终端 ID
    func createTerminal(cols: UInt16 = 80, rows: UInt16 = 24, shell: String = "/bin/zsh") -> Int {
        let terminalId = nextTerminalId
        nextTerminalId += 1

        aliveTerminals.insert(terminalId)
        totalCreated += 1

        return terminalId
    }

    /// 关闭终端
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否成功
    @discardableResult
    func closeTerminal(_ terminalId: Int) -> Bool {
        guard aliveTerminals.contains(terminalId) else {
            return false
        }

        aliveTerminals.remove(terminalId)
        totalDestroyed += 1

        return true
    }

    /// 获取终端数量
    ///
    /// - Returns: 存活的终端数量
    func getTerminalCount() -> Int {
        return aliveTerminals.count
    }

    /// 写入输入到指定终端（Mock 实现，不做实际操作）
    func writeInput(terminalId: Int, data: String) -> Bool {
        return aliveTerminals.contains(terminalId)
    }

    /// 检查终端是否存在
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 是否存在
    func isTerminalAlive(_ terminalId: Int) -> Bool {
        return aliveTerminals.contains(terminalId)
    }

    /// 获取所有存活的终端 ID
    ///
    /// - Returns: 终端 ID 数组
    func getAllTerminalIds() -> [Int] {
        return Array(aliveTerminals).sorted()
    }

    // MARK: - Statistics

    /// 打印统计信息
    func printStatistics() {
        // 调试用统计信息（已禁用）
    }
}
