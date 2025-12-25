// TerminalInfo.swift
// ETermKit
//
// 终端信息

import Foundation

/// 终端信息
///
/// 描述一个终端实例的状态和属性。
public struct TerminalInfo: Sendable, Codable, Equatable {

    /// 终端 ID
    ///
    /// 终端的唯一数字标识符
    public let terminalId: Int

    /// Tab ID
    ///
    /// 终端所属 Tab 的 UUID
    public let tabId: String

    /// Panel ID
    ///
    /// 终端所属 Panel 的 UUID
    public let panelId: String

    /// 当前工作目录
    public let cwd: String

    /// 终端列数
    public let columns: Int

    /// 终端行数
    public let rows: Int

    /// 是否为活跃终端
    public let isActive: Bool

    /// Shell 进程 PID
    public let pid: Int32?

    /// 初始化终端信息
    public init(
        terminalId: Int,
        tabId: String,
        panelId: String,
        cwd: String,
        columns: Int,
        rows: Int,
        isActive: Bool,
        pid: Int32?
    ) {
        self.terminalId = terminalId
        self.tabId = tabId
        self.panelId = panelId
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
        self.isActive = isActive
        self.pid = pid
    }
}
