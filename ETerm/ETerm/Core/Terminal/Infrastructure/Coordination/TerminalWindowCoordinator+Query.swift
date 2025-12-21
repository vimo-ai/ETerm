//
//  TerminalWindowCoordinator+Query.swift
//  ETerm
//
//  MARK: - Query Methods
//
//  职责：所有查询方法的统一入口
//  - 终端状态查询（CWD、进程状态）
//  - 激活终端/Tab 查询
//  - 键盘协议状态查询
//

import Foundation

// MARK: - Active Terminal Queries

extension TerminalWindowCoordinator {

    /// 获取当前激活的终端 ID
    func getActiveTerminalId() -> Int? {
        return terminalWindow.active.terminalId
    }

    /// 获取当前激活的 Tab 的工作目录
    func getActiveTabCwd() -> String? {
        guard let terminalId = getActiveTerminalId() else {
            return nil
        }

        // 使用终端池获取 CWD
        return getCwd(terminalId: Int(terminalId)) ?? NSHomeDirectory()
    }
}

// MARK: - CWD Queries

extension TerminalWindowCoordinator {

    /// 获取终端的当前工作目录（CWD）
    ///
    /// 优先使用 OSC 7 缓存的 CWD（更可靠，不受子进程影响），
    /// 如果缓存为空则 fallback 到 proc_pidinfo 系统调用。
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: CWD 路径，失败返回 nil
    func getCwd(terminalId: Int) -> String? {
        // 优先使用 OSC 7 缓存的 CWD（不受子进程如 vim、claude 影响）
        if let cachedCwd = terminalPool.getCachedCwd(terminalId: terminalId) {
            return cachedCwd
        }
        // Fallback 到 proc_pidinfo（shell 未配置 OSC 7 时使用）
        return terminalPool.getCwd(terminalId: terminalId)
    }

    /// 获取 Tab 的工作目录（统一接口，推荐使用）
    ///
    /// 通过 Registry 查询，支持所有状态的 Tab：
    /// - 已创建终端：查询运行时 CWD（OSC 7 > proc_pidinfo）
    /// - 分离终端：使用分离时捕获的 CWD
    /// - 待创建终端：使用注册的 CWD
    ///
    /// **重要**: 此方法总能返回有效值，不会返回 nil。
    ///
    /// - Parameters:
    ///   - tabId: Tab ID
    ///   - terminalId: Rust 终端 ID（可选）
    /// - Returns: 工作目录（保证有效）
    func getWorkingDirectory(tabId: UUID, terminalId: Int?) -> WorkingDirectory {
        return workingDirectoryRegistry.queryWorkingDirectory(tabId: tabId, terminalId: terminalId)
    }
}

// MARK: - Process State Queries

extension TerminalWindowCoordinator {

    /// 检查当前激活的终端是否有正在运行的子进程
    ///
    /// 返回 true 如果前台进程不是 shell 本身（如正在运行 vim, cargo, python 等）
    func hasActiveTerminalRunningProcess() -> Bool {
        guard let terminalId = getActiveTerminalId() else {
            return false
        }
        return terminalPool.hasRunningProcess(terminalId: Int(terminalId))
    }

    /// 检查当前激活的终端是否启用了 Bracketed Paste Mode
    ///
    /// 当启用时（应用程序发送了 \x1b[?2004h），粘贴时应该用转义序列包裹内容。
    /// 当未启用时，直接发送原始文本。
    func isActiveTerminalBracketedPasteEnabled() -> Bool {
        guard let terminalId = getActiveTerminalId() else {
            return false
        }
        return terminalPool.isBracketedPasteEnabled(terminalId: Int(terminalId))
    }

    /// 检查指定终端是否启用了 Kitty 键盘协议
    ///
    /// 应用程序通过发送 `CSI > flags u` 启用 Kitty 键盘模式。
    /// 启用后，终端应使用 Kitty 协议编码按键（如 Shift+Enter → `\x1b[13;2u`）。
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: true 表示使用 Kitty 协议，false 表示使用传统 Xterm 编码
    func isKittyKeyboardEnabled(terminalId: Int) -> Bool {
        return terminalPool.isKittyKeyboardEnabled(terminalId: terminalId)
    }

    /// 获取当前激活终端的前台进程名称
    func getActiveTerminalForegroundProcessName() -> String? {
        guard let terminalId = getActiveTerminalId() else {
            return nil
        }
        return terminalPool.getForegroundProcessName(terminalId: Int(terminalId))
    }

    /// 收集窗口中所有正在运行进程的信息
    ///
    /// 返回一个数组，包含所有正在运行非 shell 进程的 Tab 信息
    func collectRunningProcesses() -> [(tabTitle: String, processName: String)] {
        var processes: [(String, String)] = []

        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                guard let terminalId = tab.rustTerminalId else { continue }
                if terminalPool.hasRunningProcess(terminalId: Int(terminalId)),
                   let processName = terminalPool.getForegroundProcessName(terminalId: Int(terminalId)) {
                    processes.append((tab.title, processName))
                }
            }
        }

        return processes
    }
}
