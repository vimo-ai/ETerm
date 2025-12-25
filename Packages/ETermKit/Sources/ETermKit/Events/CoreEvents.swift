// CoreEvents.swift
// ETermKit
//
// 核心事件名称常量

import Foundation

/// 核心事件名称
///
/// 定义 ETerm 核心功能产生的所有事件。
/// 事件通过 IPC 传递给插件，payload 必须可序列化。
///
/// 事件命名规范：
/// - 核心事件: `core.<模块>.<动作>`
/// - 插件事件: `plugin.<pluginId>.<事件名>`
public enum CoreEventNames {

    // MARK: - App 生命周期

    /// 应用启动完成
    ///
    /// Payload: 无
    public static let appDidLaunch = "core.app.didLaunch"

    /// 应用即将退出
    ///
    /// Payload: 无
    public static let appWillTerminate = "core.app.willTerminate"

    // MARK: - Window 事件

    /// 窗口创建
    ///
    /// Payload:
    /// - `windowId`: String - 窗口 UUID
    public static let windowDidCreate = "core.window.didCreate"

    /// 窗口即将关闭
    ///
    /// Payload:
    /// - `windowId`: String - 窗口 UUID
    public static let windowWillClose = "core.window.willClose"

    /// 窗口成为主窗口
    ///
    /// Payload:
    /// - `windowId`: String - 窗口 UUID
    public static let windowDidBecomeKey = "core.window.didBecomeKey"

    // MARK: - Page 事件

    /// Page 创建
    ///
    /// Payload:
    /// - `pageId`: String - Page UUID
    /// - `windowId`: String - 所属窗口 UUID
    public static let pageDidCreate = "core.page.didCreate"

    /// Page 激活（切换到此 Page）
    ///
    /// Payload:
    /// - `pageId`: String - Page UUID
    public static let pageDidActivate = "core.page.didActivate"

    // MARK: - Panel 事件

    /// Panel 创建
    ///
    /// Payload:
    /// - `panelId`: String - Panel UUID
    /// - `pageId`: String - 所属 Page UUID
    public static let panelDidCreate = "core.panel.didCreate"

    /// Panel 分割
    ///
    /// Payload:
    /// - `panelId`: String - 原 Panel UUID
    /// - `newPanelId`: String - 新 Panel UUID
    /// - `direction`: String - "horizontal" 或 "vertical"
    public static let panelDidSplit = "core.panel.didSplit"

    // MARK: - Tab 事件

    /// Tab 创建
    ///
    /// Payload:
    /// - `tabId`: String - Tab UUID
    /// - `panelId`: String - 所属 Panel UUID
    /// - `terminalId`: Int - 关联的终端 ID
    public static let tabDidCreate = "core.tab.didCreate"

    /// Tab 激活（切换到此 Tab）
    ///
    /// Payload:
    /// - `tabId`: String - Tab UUID
    /// - `terminalId`: Int - 关联的终端 ID
    public static let tabDidActivate = "core.tab.didActivate"

    /// Tab 关闭
    ///
    /// Payload:
    /// - `tabId`: String - Tab UUID
    /// - `terminalId`: Int - 关联的终端 ID
    public static let tabDidClose = "core.tab.didClose"

    // MARK: - Terminal 事件

    /// 终端创建
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    /// - `tabId`: String - 所属 Tab UUID
    /// - `panelId`: String - 所属 Panel UUID
    /// - `cwd`: String - 初始工作目录
    public static let terminalDidCreate = "core.terminal.didCreate"

    /// 终端输出
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    /// - `data`: String - Base64 编码的输出数据
    ///
    /// 需要 capability: `terminal.read`
    public static let terminalDidOutput = "core.terminal.didOutput"

    /// 终端工作目录变更
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    /// - `oldCwd`: String - 旧工作目录
    /// - `newCwd`: String - 新工作目录
    public static let terminalDidChangeCwd = "core.terminal.didChangeCwd"

    /// 终端退出
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    /// - `exitCode`: Int - 退出码
    public static let terminalDidExit = "core.terminal.didExit"

    /// 终端获得焦点
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    public static let terminalDidFocus = "core.terminal.didFocus"

    /// 终端失去焦点
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    public static let terminalDidBlur = "core.terminal.didBlur"

    /// 终端尺寸变更
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    /// - `columns`: Int - 新列数
    /// - `rows`: Int - 新行数
    public static let terminalDidResize = "core.terminal.didResize"

    /// 终端响铃
    ///
    /// Payload:
    /// - `terminalId`: Int - 终端 ID
    public static let terminalDidBell = "core.terminal.didBell"

    // MARK: - Plugin 事件

    /// 插件激活
    ///
    /// Payload:
    /// - `pluginId`: String - 插件 ID
    public static let pluginDidActivate = "core.plugin.didActivate"

    /// 插件停用
    ///
    /// Payload:
    /// - `pluginId`: String - 插件 ID
    public static let pluginDidDeactivate = "core.plugin.didDeactivate"
}
