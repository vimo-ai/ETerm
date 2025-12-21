//
//  CommandRecordingProxy.swift
//  ETerm
//
//  命令录制代理 - 劫持命令执行并自动录制事件
//
//  使用方式：
//  let result = recordingProxy.execute(.page(.reorder(order: ids)), on: terminalWindow)
//
//  职责：
//  - 代理 TerminalWindow.execute() 调用
//  - 根据命令类型自动录制对应的 SessionEvent
//  - 保持领域层纯净，不感知录制逻辑
//

import Foundation

/// 命令录制代理
///
/// 劫持 TerminalWindow 的命令执行，自动录制事件
/// 解耦录制逻辑，避免 Coordinator 臃肿
final class CommandRecordingProxy {

    // MARK: - Dependencies

    private let recorder: SessionRecorder

    // MARK: - Initialization

    init(recorder: SessionRecorder = .shared) {
        self.recorder = recorder
    }

    // MARK: - Command Execution

    /// 执行命令并自动录制
    ///
    /// - Parameters:
    ///   - command: 要执行的命令
    ///   - window: 目标 TerminalWindow
    /// - Returns: 命令执行结果
    func execute(_ command: WindowCommand, on window: TerminalWindow) -> CommandResult {
        let result = window.execute(command)

        // 只有成功的命令才录制
        if result.success {
            recordEvent(for: command, window: window)
        }

        return result
    }

    // MARK: - Event Recording

    /// 根据命令类型录制对应事件
    private func recordEvent(for command: WindowCommand, window: TerminalWindow) {
        guard let event = mapToSessionEvent(command, window: window) else {
            return
        }
        recorder.record(event)
    }

    /// 录制自定义事件（用于 Coordinator 级别的事件）
    ///
    /// 某些事件不通过命令管道触发（如 Panel 激活），需要手动录制
    func recordEvent(_ event: SessionEvent) {
        recorder.record(event)
    }

    /// 将 WindowCommand 映射为 SessionEvent
    private func mapToSessionEvent(_ command: WindowCommand, window: TerminalWindow) -> SessionEvent? {
        switch command {
        // MARK: Tab Commands
        case .tab(let tabCommand):
            return mapTabCommand(tabCommand, window: window)

        // MARK: Panel Commands
        case .panel(let panelCommand):
            return mapPanelCommand(panelCommand, window: window)

        // MARK: Page Commands
        case .page(let pageCommand):
            return mapPageCommand(pageCommand, window: window)

        // MARK: Window Commands
        case .window(let windowCommand):
            return mapWindowCommand(windowCommand, window: window)
        }
    }

    // MARK: - Tab Command Mapping

    private func mapTabCommand(_ command: TabCommand, window: TerminalWindow) -> SessionEvent? {
        switch command {
        case .switch(let panelId, let tabId):
            // 获取之前的 activeTabId
            let fromTabId = window.getPanel(panelId)?.activeTabId
            return .tabSwitch(panelId: panelId, fromTabId: fromTabId, toTabId: tabId)

        case .add(let panelId):
            // Tab 创建后获取新 Tab 信息
            if let panel = window.getPanel(panelId),
               let newTab = panel.activeTab {
                let contentType = newTab.isTerminal ? "terminal" : "view"
                return .tabCreate(panelId: panelId, tabId: newTab.tabId, contentType: contentType)
            }
            return nil

        case .addWithConfig(let panelId, _):
            // 与 .add 相同逻辑
            if let panel = window.getPanel(panelId),
               let newTab = panel.activeTab {
                let contentType = newTab.isTerminal ? "terminal" : "view"
                return .tabCreate(panelId: panelId, tabId: newTab.tabId, contentType: contentType)
            }
            return nil

        case .close(let panelId, let scope):
            if case .single(let tabId) = scope {
                return .tabClose(panelId: panelId, tabId: tabId)
            }
            // 批量关闭暂不录制详细事件
            return nil

        case .remove(let tabId, let panelId, _):
            // 移除 Tab（用于跨窗口移动），录制为 tabClose
            return .tabClose(panelId: panelId, tabId: tabId)

        case .reorder(let panelId, let order):
            return .tabReorder(panelId: panelId, tabIds: order)

        case .move:
            // Tab 移动暂不录制（复杂场景）
            return nil
        }
    }

    // MARK: - Panel Command Mapping

    private func mapPanelCommand(_ command: PanelCommand, window: TerminalWindow) -> SessionEvent? {
        switch command {
        case .split(let panelId, let direction, _):
            // 执行后，新 Panel 已被激活（在 executePanelSplit 中）
            // 所以 window.active.panelId 就是新创建的 Panel ID
            guard let newPanelId = window.active.panelId else {
                return nil
            }
            let directionStr = direction == .horizontal ? "horizontal" : "vertical"
            return .panelSplit(panelId: panelId, direction: directionStr, newPanelId: newPanelId)

        case .close(let panelId):
            return .panelClose(panelId: panelId)

        case .setActive(let panelId):
            let fromPanelId = window.active.panelId
            return .panelActivate(fromPanelId: fromPanelId, toPanelId: panelId)
        }
    }

    // MARK: - Page Command Mapping

    private func mapPageCommand(_ command: PageCommand, window: TerminalWindow) -> SessionEvent? {
        switch command {
        case .switch(let target):
            let fromPageId = window.active.pageId
            switch target {
            case .specific(let pageId):
                return .pageSwitch(fromPageId: fromPageId, toPageId: pageId)
            case .next, .previous:
                // 切换后获取当前 pageId
                if let toPageId = window.active.pageId {
                    return .pageSwitch(fromPageId: fromPageId, toPageId: toPageId)
                }
                return nil
            }

        case .create:
            // 创建后获取新 Page 信息
            if let newPage = window.pages.all.last {
                return .pageCreate(pageId: newPage.pageId, title: newPage.title)
            }
            return nil

        case .close(let scope):
            if case .single(let pageId) = scope {
                return .pageClose(pageId: pageId)
            }
            // 批量关闭暂不录制详细事件
            return nil

        case .reorder(let order):
            return .pageReorder(pageIds: order)

        case .move, .moveToEnd:
            // move 操作的结果是新的顺序，录制为 pageReorder
            let pageIds = window.pages.all.map { $0.pageId }
            return .pageReorder(pageIds: pageIds)
        }
    }

    // MARK: - Window Command Mapping

    private func mapWindowCommand(_ command: WindowOnlyCommand, window: TerminalWindow) -> SessionEvent? {
        switch command {
        case .smartClose:
            // smartClose 的具体操作会递归调用其他命令，那些命令会被单独录制
            // 这里不需要重复录制
            return nil
        }
    }
}
