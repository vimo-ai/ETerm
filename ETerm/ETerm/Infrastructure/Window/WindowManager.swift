//
//  WindowManager.swift
//  ETerm
//
//  窗口管理器 - 管理多窗口生命周期
//
//  职责：
//  - 创建和销毁窗口
//  - 维护窗口列表
//  - 处理窗口间的协调（为后续 Page 拖动做准备）
//

import AppKit
import SwiftUI

/// 窗口管理器（单例）
final class WindowManager: NSObject {
    static let shared = WindowManager()

    /// 所有打开的窗口
    private(set) var windows: [KeyableWindow] = []

    /// 默认窗口尺寸
    private let defaultSize = NSSize(width: 900, height: 650)

    private override init() {
        super.init()
    }

    // MARK: - 窗口创建

    /// 创建新窗口
    @discardableResult
    func createWindow() -> KeyableWindow {
        let frame = calculateNewWindowFrame()

        let window = KeyableWindow.create(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .miniaturizable, .closable]
        )

        // 设置内容视图
        let contentView = ContentView()
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        // 重新配置圆角（因为替换了 contentView）
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true

        // 设置最小尺寸
        window.minSize = NSSize(width: 400, height: 300)

        // 监听窗口关闭
        window.delegate = self

        // 添加到列表
        windows.append(window)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)

        return window
    }

    /// 计算新窗口位置（级联效果）
    private func calculateNewWindowFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }

        let screenFrame = screen.visibleFrame

        // 如果没有窗口，居中显示
        if windows.isEmpty {
            let x = screenFrame.midX - defaultSize.width / 2
            let y = screenFrame.midY - defaultSize.height / 2
            return NSRect(x: x, y: y, width: defaultSize.width, height: defaultSize.height)
        }

        // 有窗口时，级联偏移
        if let lastWindow = windows.last {
            let lastFrame = lastWindow.frame
            let offset: CGFloat = 30

            var newX = lastFrame.origin.x + offset
            var newY = lastFrame.origin.y - offset

            // 确保不超出屏幕
            if newX + defaultSize.width > screenFrame.maxX {
                newX = screenFrame.origin.x + 50
            }
            if newY < screenFrame.origin.y {
                newY = screenFrame.maxY - defaultSize.height - 50
            }

            return NSRect(x: newX, y: newY, width: defaultSize.width, height: defaultSize.height)
        }

        return NSRect(origin: .zero, size: defaultSize)
    }

    // MARK: - 窗口关闭

    /// 关闭指定窗口
    func closeWindow(_ window: KeyableWindow) {
        window.close()
        removeWindow(window)
    }

    /// 从列表中移除窗口
    private func removeWindow(_ window: KeyableWindow) {
        windows.removeAll { $0 === window }

        // 如果所有窗口都关闭了，退出应用（可选行为）
        if windows.isEmpty {
            // NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - 窗口查询

    /// 获取当前 key window
    var keyWindow: KeyableWindow? {
        windows.first { $0.isKeyWindow }
    }

    /// 窗口数量
    var windowCount: Int {
        windows.count
    }
}

// MARK: - NSWindowDelegate

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? KeyableWindow else { return }
        removeWindow(window)
    }
}
