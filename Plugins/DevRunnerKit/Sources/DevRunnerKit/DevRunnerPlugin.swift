//
//  DevRunnerPlugin.swift
//  DevRunnerKit
//
//  DevRunner ETerm 插件 — 项目进程管理

import Foundation
import SwiftUI
import ETermKit

@objc(DevRunnerPlugin)
@MainActor
public final class DevRunnerPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.dev-runner"

    private var host: HostBridge?
    private var refreshTimer: Timer?

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 触发 bridge 初始化
        _ = DevRunnerBridge.shared

        // 每 2 秒刷新进程状态 + metrics
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }

        print("[DevRunner] Activated")
    }

    public func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        print("[DevRunner] Deactivated")
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "terminal.didClose":
            if let terminalId = payload["terminalId"] as? Int {
                print("[DevRunner] Terminal closed: \(terminalId)")
                // 清空关联的 terminalId，让 sidebar 显示重开按钮
                let bridge = DevRunnerBridge.shared
                for i in bridge.projectStates.indices {
                    if bridge.projectStates[i].terminalId == terminalId {
                        bridge.projectStates[i].terminalId = nil
                        break
                    }
                }
                refreshState()
            }
        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        default:
            break
        }
    }

    // MARK: - Terminal Integration

    /// 运行 target 并打开原生 Terminal Tab（shell tab + sendInput 模式）
    public func runAndOpenTerminal(state: inout ProjectState) throws {
        let target = state.selectedTarget ?? state.targets.first?.name ?? ""
        let result = try DevRunnerBridge.shared.startMonitored(
            projectPath: state.project.path,
            target: target
        )

        guard let host = self.host else {
            print("[DevRunner] 启动进程 \(result.processId), 但 host 不可用，无法创建终端 Tab")
            return
        }

        // 创建正常 shell tab
        guard let terminalId = host.createTerminalTab(cwd: result.cwd) else {
            print("[DevRunner] 创建终端 Tab 失败")
            return
        }
        state.terminalId = terminalId
        host.markTerminalKeepAlive(terminalId: terminalId)
        // 记录 daemon session ID，用于后续 reattach
        state.daemonSessionId = host.getDaemonSessionId(terminalId: terminalId)

        // 延迟 300ms 等 shell 初始化，然后发送包装命令
        let wrappedCommand = result.wrappedCommand
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            host.sendInput(terminalId: terminalId, text: wrappedCommand, pressEnter: true)
        }

        print("[DevRunner] 启动进程 \(result.processId), terminal=\(terminalId)")

        // 刷新进程列表
        DevRunnerBridge.shared.refreshProcesses()
        state.process = DevRunnerBridge.shared.processes.first { $0.processId == result.processId }
    }

    /// 重新打开终端（reattach daemon session）
    public func reopenTerminal(state: inout ProjectState) {
        guard let host = self.host else { return }
        // 设置 reattach hint，让 terminal_pool 优先 attach 到旧 daemon session
        if let sessionId = state.daemonSessionId {
            host.setReattachHint(sessionId: sessionId)
            print("[DevRunner] 设置 reattach hint: \(sessionId)")
        }
        guard let terminalId = host.createTerminalTab(cwd: state.project.path) else {
            print("[DevRunner] 重新打开终端失败")
            return
        }
        state.terminalId = terminalId
        host.markTerminalKeepAlive(terminalId: terminalId)
        // 更新 daemon session ID（可能是 reattach 的旧 session 或新建的）
        state.daemonSessionId = host.getDaemonSessionId(terminalId: terminalId)
        print("[DevRunner] 重新打开终端 \(terminalId), session=\(state.daemonSessionId ?? "none")")
    }

    /// 强制关闭终端（kill daemon session）
    public func forceCloseTerminal(terminalId: Int) {
        host?.closeTerminalForce(terminalId: terminalId)
    }

    /// 发送 Ctrl+C 到终端
    public func sendCtrlC(terminalId: Int) {
        host?.sendInput(terminalId: terminalId, text: "\u{03}", pressEnter: false)
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        switch tabId {
        case "dev-runner":
            return AnyView(DevRunnerSidebarView(bridge: DevRunnerBridge.shared, plugin: self))
        default:
            return nil
        }
    }

    public func bottomDockView(for id: String) -> AnyView? { nil }
    public func infoPanelView(for id: String) -> AnyView? { nil }
    public func bubbleView(for id: String) -> AnyView? { nil }
    public func menuBarView() -> AnyView? { nil }
    public func pageBarView(for itemId: String) -> AnyView? { nil }
    public func windowBottomOverlayView(for id: String) -> AnyView? { nil }
    public func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? { nil }
    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? { nil }

    // MARK: - Private

    private func refreshState() {
        let bridge = DevRunnerBridge.shared
        bridge.refreshProcesses()

        // 更新每个项目关联的进程和 metrics
        for i in bridge.projectStates.indices {
            let path = bridge.projectStates[i].project.path

            // 关联最新的 running 进程
            bridge.projectStates[i].process = bridge.processes.first(where: {
                $0.projectPath == path && $0.isRunning
            }) ?? bridge.processes.last(where: { $0.projectPath == path })

            // 获取 metrics
            if let pid = bridge.projectStates[i].process?.pid,
               bridge.projectStates[i].process?.isRunning == true {
                bridge.projectStates[i].metrics = try? bridge.getMetrics(pid: pid)
            } else {
                bridge.projectStates[i].metrics = nil
            }
        }
    }
}
