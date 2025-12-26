//
//  WritingPlugin.swift
//  WritingKit
//
//  写作助手插件 - Cmd+K 触发 InlineComposer 进行写作检查 (SDK main 模式)
//

import Foundation
import SwiftUI
import ETermKit

// MARK: - Plugin Entry

@objc(WritingPlugin)
@MainActor
public final class WritingPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.writing"

    private static let toggleCommandId = "writing.toggleComposer"
    private static let showCommandId = "writing.showComposer"
    private static let hideCommandId = "writing.hideComposer"

    private var host: HostBridge?

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host

        // 注册切换命令
        host.registerCommand(PluginCommand(
            id: Self.toggleCommandId,
            title: "切换写作助手",
            icon: "sparkles"
        ))

        // 注册显示命令
        host.registerCommand(PluginCommand(
            id: Self.showCommandId,
            title: "显示写作助手",
            icon: "sparkles"
        ))

        // 注册隐藏命令
        host.registerCommand(PluginCommand(
            id: Self.hideCommandId,
            title: "隐藏写作助手"
        ))

        // 绑定快捷键 Cmd+K 到切换命令
        host.bindKeyboard(.cmd("k"), to: Self.toggleCommandId)

        print("[WritingKit] Plugin activated, Cmd+K bound to toggleComposer")
    }

    public func deactivate() {
        // 解绑快捷键
        host?.unbindKeyboard(.cmd("k"))

        // 取消注册命令
        host?.unregisterCommand(commandId: Self.toggleCommandId)
        host?.unregisterCommand(commandId: Self.showCommandId)
        host?.unregisterCommand(commandId: Self.hideCommandId)

        print("[WritingKit] Plugin deactivated")
    }

    public func sidebarView(for tabId: String) -> AnyView? {
        // WritingKit 不提供侧边栏视图，Composer 是宿主层的 UI
        return nil
    }

    public func infoPanelView(for id: String) -> AnyView? {
        // WritingKit 不提供 InfoPanel 视图，Composer 是宿主层的 UI
        return nil
    }

    /// 处理事件
    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        guard eventName == "command.invoked",
              let commandId = payload["commandId"] as? String else {
            return
        }

        switch commandId {
        case Self.toggleCommandId:
            host?.toggleComposer()
        case Self.showCommandId:
            host?.showComposer()
        case Self.hideCommandId:
            host?.hideComposer()
        default:
            break
        }
    }
}
