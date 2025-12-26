//
//  CommandInputController.swift
//  ETerm
//
//  命令输入控制器

import AppKit
import SwiftUI

/// 命令执行结果
enum CommandExecutionResult {
    case success(String)  // 成功，包含输出
    case failure(String)  // 失败，包含错误信息
}

/// 自定义 Panel - 允许成为 key window
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return false
    }
}

/// 命令输入控制器
///
/// 管理命令输入面板的显示和交互
final class CommandInputController {
    // MARK: - 回调

    private let onExecute: (String) -> Void
    private let onCancel: () -> Void

    // MARK: - 状态

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CommandInputView>?

    // MARK: - 初始化

    init(
        onExecute: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onExecute = onExecute
        self.onCancel = onCancel
    }

    // MARK: - 公共方法

    /// 显示输入面板
    ///
    /// - Parameters:
    ///   - windowFrame: 窗口 frame，用于定位面板（nil 则使用屏幕中心）
    ///   - cwd: 当前工作目录
    func show(windowFrame: CGRect?, cwd: String) {
        // 如果已显示，直接显示面板（输入框会自动聚焦）
        if let panel = panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // 创建输入视图
        let inputView = CommandInputView(
            cwd: cwd,
            onExecute: { [weak self] command in
                self?.onExecute(command)
            },
            onCancel: { [weak self] in
                self?.onCancel()
            }
        )

        // 创建 SwiftUI hosting view
        let hosting = NSHostingView(rootView: inputView)
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 80)
        self.hostingView = hosting

        // 创建自定义面板（允许成为 key window）
        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        newPanel.contentView = hosting
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .floating
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 关键：允许面板成为 key window
        newPanel.becomesKeyOnlyIfNeeded = false

        // 定位到当前窗口中心（如果有窗口 frame）或屏幕中心
        if let frame = windowFrame {
            let x = frame.midX - 250
            let y = frame.midY + 100  // 稍微偏上
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 250
            let y = screenFrame.midY + 100
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = newPanel

        // 先显示 panel
        newPanel.orderFront(nil)

        // 然后让它成为 key window（获得焦点）
        newPanel.makeKey()

        // 多次尝试聚焦，确保成功
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            newPanel.makeFirstResponder(hosting)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            newPanel.makeFirstResponder(hosting)
        }
    }

    /// 隐藏输入面板
    func hide() {
        panel?.close()
        panel = nil
        hostingView = nil
    }

    /// 显示执行结果
    func showResult(_ message: String, isError: Bool) {
        // 更新 SwiftUI 视图显示结果
        // 注意：这里需要通过 @Published 或 @Binding 更新视图
        // 暂时使用简单的通知方式
        NotificationCenter.default.post(
            name: .commandExecutionResult,
            object: nil,
            userInfo: ["message": message, "isError": isError]
        )
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let commandExecutionResult = Notification.Name("commandExecutionResult")
}
