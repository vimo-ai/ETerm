//
//  SessionRecorder+Integration.swift
//  ETerm
//
//  会话录制器集成 - 在关键交互点自动埋点
//
//  使用方式：
//  在 ETermApp.swift 中调用 SessionRecorder.shared.setupIntegration()
//

import Foundation
import AppKit

// MARK: - 自动集成

extension SessionRecorder {

    /// 设置自动集成（监听系统通知来录制事件）
    ///
    /// 调用此方法后，录制器会自动监听关键交互事件
    func setupIntegration() {
        setupNotificationObservers()
        setupSnapshotProvider()

        logInfo("[SessionRecorder] 集成已启用")
    }

    /// 设置通知监听
    private func setupNotificationObservers() {
        let center = NotificationCenter.default

        // 终端关闭通知
        center.addObserver(
            forName: .terminalDidClose,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let terminalId = notification.userInfo?["terminal_id"] as? Int else { return }
            self?.record(.terminalOutputEvent(
                terminalId: UUID(),  // 无法从 terminalId 获取 UUID，使用占位
                eventType: "closed"
            ), source: "TerminalPool")
        }

        // 活跃终端变化通知
        center.addObserver(
            forName: .activeTerminalDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.custom(
                name: "activeTerminalChanged",
                payload: [:]
            ), source: "UI")
        }

        // 窗口激活通知
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.record(.windowActivate(windowNumber: window.windowNumber), source: "AppKit")
        }

        // 窗口关闭通知
        center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.record(.windowClose(windowNumber: window.windowNumber), source: "AppKit")
        }

        // 窗口移动通知
        center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.record(.windowMove(
                windowNumber: window.windowNumber,
                frame: window.frame
            ), source: "AppKit")
        }

        // 窗口调整大小通知
        center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.record(.windowResize(
                windowNumber: window.windowNumber,
                frame: window.frame
            ), source: "AppKit")
        }
    }

    /// 设置状态快照提供器
    private func setupSnapshotProvider() {
        snapshotProvider = {
            // 从 WindowManager 获取状态
            let windowManager = WindowManager.shared
            let windows = windowManager.getAllCoordinators()

            var windowSnapshots: [WindowSnapshot] = []

            for coordinator in windows {
                let terminalWindow = coordinator.terminalWindow

                var pageSnapshots: [PageSnapshot] = []
                for page in terminalWindow.pages {
                    pageSnapshots.append(PageSnapshot(
                        pageId: page.pageId,
                        title: page.title,
                        panelCount: page.allPanels.count,
                        activePanelId: coordinator.activePanelId
                    ))
                }

                // 获取窗口编号需要访问 NSWindow，这里简化处理
                windowSnapshots.append(WindowSnapshot(
                    windowNumber: 0,  // 简化：无法直接获取
                    frame: .zero,     // 简化：无法直接获取
                    pageCount: terminalWindow.pageCount,
                    activePageId: terminalWindow.activePageId,
                    pages: pageSnapshots
                ))
            }

            // 构建焦点元素
            var focusedElement: FocusElement? = nil
            if let activeCoordinator = windows.first,
               let activePanelId = activeCoordinator.activePanelId,
               let panel = activeCoordinator.terminalWindow.getPanel(activePanelId),
               let activeTab = panel.activeTab {
                focusedElement = .terminal(panelId: activePanelId, tabId: activeTab.tabId)
            }

            return StateSnapshot(
                timestamp: Date(),
                windowCount: windows.count,
                windows: windowSnapshots,
                activeWindowNumber: nil,  // 简化
                focusedElement: focusedElement
            )
        }
    }
}

// MARK: - TerminalWindowCoordinator 扩展

extension TerminalWindowCoordinator {

    /// 录制 Page 创建事件
    func recordPageCreateEvent(pageId: UUID, title: String) {
        SessionRecorder.shared.recordPageCreate(pageId: pageId, title: title)
    }

    /// 录制 Page 关闭事件
    func recordPageCloseEvent(pageId: UUID) {
        SessionRecorder.shared.recordPageClose(pageId: pageId)
    }

    /// 录制 Page 切换事件
    func recordPageSwitchEvent(from: UUID?, to: UUID) {
        SessionRecorder.shared.recordPageSwitch(from: from, to: to)
    }

    /// 录制 Tab 创建事件
    func recordTabCreateEvent(panelId: UUID, tabId: UUID, contentType: String = "terminal") {
        SessionRecorder.shared.recordTabCreate(panelId: panelId, tabId: tabId, contentType: contentType)
    }

    /// 录制 Tab 关闭事件
    func recordTabCloseEvent(panelId: UUID, tabId: UUID) {
        SessionRecorder.shared.recordTabClose(panelId: panelId, tabId: tabId)
    }

    /// 录制 Tab 切换事件
    func recordTabSwitchEvent(panelId: UUID, from: UUID?, to: UUID) {
        SessionRecorder.shared.recordTabSwitch(panelId: panelId, from: from, to: to)
    }

    /// 录制焦点变化事件
    func recordFocusChangeEvent(from: FocusElement?, to: FocusElement) {
        SessionRecorder.shared.recordFocusChange(from: from, to: to)
    }

    /// 录制 Panel 激活事件
    func recordPanelActivateEvent(from: UUID?, to: UUID) {
        SessionRecorder.shared.recordPanelActivate(from: from, to: to)
    }
}

// MARK: - 便捷录制宏

/// 录制 Page 事件
func recordPageEvent(_ event: SessionEvent) {
    SessionRecorder.shared.record(event, source: "PageManager")
}

/// 录制 Tab 事件
func recordTabEvent(_ event: SessionEvent) {
    SessionRecorder.shared.record(event, source: "TabManager")
}

/// 录制 Panel 事件
func recordPanelEvent(_ event: SessionEvent) {
    SessionRecorder.shared.record(event, source: "PanelManager")
}

/// 录制焦点事件
func recordFocusEvent(_ event: SessionEvent) {
    SessionRecorder.shared.record(event, source: "FocusManager")
}

/// 录制快捷键事件
func recordShortcutEvent(commandId: String, context: String? = nil) {
    SessionRecorder.shared.recordShortcut(commandId: commandId, context: context)
}
