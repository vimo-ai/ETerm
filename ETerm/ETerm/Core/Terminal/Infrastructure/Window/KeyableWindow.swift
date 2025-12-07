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
