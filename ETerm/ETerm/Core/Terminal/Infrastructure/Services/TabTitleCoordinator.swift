//
//  TabTitleCoordinator.swift
//  ETerm
//
//  Tab 标题自动更新协调器
//
//  职责：
//  - 监听 Shell Integration 事件（CWD、Command）
//  - 智能更新 Tab 标题
//  - 区分 Shell 和应用程序状态
//
//  更新策略：
//  1. Shell 状态（无运行进程）
//     - 显示当前目录名（从 OSC 7 CWD）
//     - 示例："/Users/foo/projects/my-app" → "my-app"
//
//  2. 应用程序状态（有运行进程）
//     - 显示进程名
//     - 示例："vim", "cargo", "python"
//
//  事件来源：
//  - OSC 7: 工作目录变化
//  - OSC 133;C: 命令执行
//

import Foundation

/// Tab 标题自动更新协调器
///
/// 此服务监听终端事件并智能更新 Tab 标题
class TabTitleCoordinator {

    // MARK: - Dependencies

    /// 终端池（用于查询进程状态）
    private weak var terminalPool: TerminalPoolProtocol?

    /// Tab 标题更新回调（更新系统标题）
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - title: 新的系统标题
    private var onSystemTitleUpdate: ((Int, String) -> Void)?

    /// 插件标题清除回调（进程退出时自动调用）
    /// - Parameters:
    ///   - terminalId: 终端 ID
    private var onPluginTitleClear: ((Int) -> Void)?

    /// 进程状态缓存（用于检测状态变化）
    private var processStateCache: [Int: Bool] = [:]

    // MARK: - Initialization

    /// 初始化 Tab 标题协调器
    ///
    /// - Parameters:
    ///   - terminalPool: 终端池引用
    ///   - onSystemTitleUpdate: 系统标题更新回调
    ///   - onPluginTitleClear: 插件标题清除回调（进程退出时）
    init(
        terminalPool: TerminalPoolProtocol,
        onSystemTitleUpdate: @escaping (Int, String) -> Void,
        onPluginTitleClear: @escaping (Int) -> Void
    ) {
        self.terminalPool = terminalPool
        self.onSystemTitleUpdate = onSystemTitleUpdate
        self.onPluginTitleClear = onPluginTitleClear
    }

    /// 兼容旧接口（只传 onTitleUpdate）
    convenience init(terminalPool: TerminalPoolProtocol, onTitleUpdate: @escaping (Int, String) -> Void) {
        self.init(
            terminalPool: terminalPool,
            onSystemTitleUpdate: onTitleUpdate,
            onPluginTitleClear: { _ in }  // 空实现
        )
    }

    // MARK: - Event Handlers

    /// 处理当前工作目录变化（OSC 7）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - cwd: 新的工作目录路径
    func handleCurrentDirectoryChanged(terminalId: Int, cwd: String) {
        // CWD 变化时更新标题
        // 注意：此时可能还有进程在运行（如 cd 命令本身），所以延迟检查
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateTabTitle(for: terminalId)
        }
    }

    /// 处理命令执行（OSC 133;C）
    ///
    /// - Parameters:
    ///   - terminalId: 终端 ID
    ///   - command: 执行的命令
    func handleCommandExecuted(terminalId: Int, command: String) {
        // 命令执行时，立即更新标题为进程名
        // 注意：此时前台进程可能还未启动，所以稍微延迟
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateTabTitle(for: terminalId)
        }
    }

    // MARK: - Private Methods

    /// 更新 Tab 标题
    ///
    /// 根据当前终端状态智能选择标题：
    /// - 有运行进程 → 使用进程名
    /// - 无运行进程 → 使用目录名
    ///
    /// 自动恢复机制：
    /// - 当进程从"运行中"变为"已退出"时，自动清除 pluginTitle
    ///
    /// - Parameter terminalId: 终端 ID
    private func updateTabTitle(for terminalId: Int) {
        guard let terminalPool = terminalPool else { return }

        // 1. 检查是否有运行的进程
        let hasRunningProcess = terminalPool.hasRunningProcess(terminalId: terminalId)

        // 2. 检测进程状态变化（从有到无）→ 自动清除 pluginTitle
        let previousHasProcess = processStateCache[terminalId] ?? false
        processStateCache[terminalId] = hasRunningProcess

        if previousHasProcess && !hasRunningProcess {
            // 进程退出，清除插件标题
            onPluginTitleClear?(terminalId)
        }

        // 3. 确定系统标题
        let newSystemTitle: String

        if hasRunningProcess {
            // 3a. 有进程运行 → 使用进程名
            if let processName = terminalPool.getForegroundProcessName(terminalId: terminalId) {
                newSystemTitle = processName
            } else {
                // 降级：无法获取进程名，使用目录名
                newSystemTitle = extractDirectoryName(from: terminalId)
            }
        } else {
            // 3b. 无进程运行（纯 Shell） → 使用目录名
            newSystemTitle = extractDirectoryName(from: terminalId)
        }

        // 4. 更新系统标题
        onSystemTitleUpdate?(terminalId, newSystemTitle)
    }

    /// 从 CWD 中提取目录名
    ///
    /// - Parameter terminalId: 终端 ID
    /// - Returns: 目录名（如 "my-app"）或降级值
    private func extractDirectoryName(from terminalId: Int) -> String {
        guard let terminalPool = terminalPool else {
            return "Terminal"
        }

        // 优先使用 OSC 7 缓存的 CWD（更准确）
        if let cwd = terminalPool.getCachedCwd(terminalId: terminalId) {
            return extractLastPathComponent(from: cwd)
        }

        // 降级：使用 proc_pidinfo 查询 CWD
        if let cwd = terminalPool.getCwd(terminalId: terminalId) {
            return extractLastPathComponent(from: cwd)
        }

        // 最终降级：使用默认名称
        return "Terminal"
    }

    /// 提取路径的最后一个组件（目录名）
    ///
    /// - Parameter path: 完整路径
    /// - Returns: 最后的目录名
    private func extractLastPathComponent(from path: String) -> String {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = normalized.split(separator: "/")

        if let last = components.last, !last.isEmpty {
            return String(last)
        }

        // 特殊情况：根目录
        if normalized == "/" || normalized.isEmpty {
            return "~"
        }

        return "Terminal"
    }
}
