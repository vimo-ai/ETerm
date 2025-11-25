//
//  KeyableWindow.swift
//  ETerm
//
//  自定义 NSWindow 子类，解决 borderless 窗口无法接收键盘输入的问题
//
//  问题背景：
//  - macOS 的 borderless 窗口默认 canBecomeKey 返回 false
//  - 导致键盘事件无法发送到窗口
//  - 通过覆盖 canBecomeKey 和 canBecomeMain 解决
//

import AppKit

/// 可接收键盘输入的 Borderless 窗口
final class KeyableWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 创建配置好的 borderless 窗口
    static func create(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.borderless, .resizable, .miniaturizable, .closable],
        backing: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) -> KeyableWindow {
        let window = KeyableWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        // 基础配置
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false

        // 圆角
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true

        return window
    }
}
