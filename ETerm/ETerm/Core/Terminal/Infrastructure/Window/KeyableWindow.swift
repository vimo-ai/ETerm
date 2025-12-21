//
//  KeyableWindow.swift
//  ETerm
//
//  自定义 NSWindow 子类，支持透明标题栏和原生全屏
//
//  设计说明：
//  - 使用 .titled 样式以支持 macOS 原生全屏功能
//  - 配合透明标题栏实现类似 borderless 的外观
//  - 内容延伸至标题栏区域（fullSizeContentView）
//

import AppKit

/// 支持全屏的透明标题栏窗口
final class KeyableWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 禁用 titlebar 区域的窗口拖动，让 PageBar 可以正确处理拖拽
    override var isMovable: Bool {
        get { false }
        set { }
    }

    // MARK: - 快捷键处理

    /// 在 Window 级别拦截快捷键，转发给命令系统
    ///
    /// 这样无论焦点在终端还是 View Tab，快捷键都能正常工作
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 只处理带修饰键的按键（快捷键）
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false else {
            return super.performKeyEquivalent(with: event)
        }

        // 如果焦点在文本输入框（如设置页面、搜索框），放行给系统处理
        if firstResponder is NSText {
            // 但 Escape 键需要我们处理（关闭搜索框等）
            if event.keyCode != 53 { // 53 = Escape
                return super.performKeyEquivalent(with: event)
            }
        }

        // 获取对应的 Coordinator
        guard let coordinator = WindowManager.shared.getCoordinator(for: windowNumber),
              let keyboardSystem = coordinator.keyboardSystem else {
            return super.performKeyEquivalent(with: event)
        }

        // 如果 InlineComposer 正在显示，只处理 Cmd+K（关闭）
        if coordinator.isComposerShowing {
            let keyStroke = KeyStroke.from(event)
            if keyStroke.matches(.cmd("k")) {
                coordinator.sendUIEvent(.hideComposer)
                coordinator.isComposerShowing = false
                return true
            }
            // 其他快捷键放行给 composer 文本框
            return super.performKeyEquivalent(with: event)
        }

        // 转发给命令系统
        let result = keyboardSystem.handleKeyDown(event)

        switch result {
        case .handled:
            return true
        case .passToIME:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// 创建配置好的透明标题栏窗口
    static func create(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.titled, .resizable, .miniaturizable, .closable, .fullSizeContentView],
        backing: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) -> KeyableWindow {
        let window = KeyableWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        // 🔑 关键：防止窗口关闭时自动释放导致 crash
        // 参考: https://lapcatsoftware.com/articles/working-without-a-nib-part-12.html
        window.isReleasedWhenClosed = false

        // 透明标题栏配置
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // 基础配置
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false

        // 启用全屏支持
        window.collectionBehavior = [.fullScreenPrimary]

        // 圆角
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true

        return window
    }
}
