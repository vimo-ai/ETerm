//
//  CommandContext.swift
//  ETerm
//
//  应用层 - 命令执行上下文

import AppKit

/// 命令执行上下文
///
/// 提供命令执行时需要的环境信息和资源
struct CommandContext {
    /// 当前窗口协调器（弱引用，避免循环引用）
    weak var coordinator: TerminalWindowCoordinator?

    /// 当前窗口（弱引用，避免循环引用）
    weak var window: NSWindow?

    /// 命令参数（键值对，支持任意类型）
    var arguments: [String: Any]

    // MARK: - 初始化

    init(
        coordinator: TerminalWindowCoordinator? = nil,
        window: NSWindow? = nil,
        arguments: [String: Any] = [:]
    ) {
        self.coordinator = coordinator
        self.window = window
        self.arguments = arguments
    }

    // MARK: - 便捷访问

    /// 获取当前活跃的终端 ID
    var activeTerminalId: Int? {
        coordinator?.getActiveTerminalId()
    }

    /// 是否有文本选中
    var hasSelection: Bool {
        guard let coordinator = coordinator else { return false }
        let activePanelId = coordinator.activePanelId
        let panel = activePanelId.flatMap { coordinator.terminalWindow.getPanel($0) }
        let activeTab = panel?.activeTab
        return activeTab?.hasSelection() ?? false
    }

    /// 当前键盘模式
    var keyboardMode: KeyboardMode {
        // 暂时简单实现，根据是否有选中判断
        // 未来可以从 coordinator 获取精确的 mode
        return hasSelection ? .selection : .normal
    }
}
