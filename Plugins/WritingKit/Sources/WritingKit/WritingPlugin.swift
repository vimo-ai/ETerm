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
    private static let showArchiveId = "writing.showArchive"

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

        // 注册语法档案命令
        host.registerCommand(PluginCommand(
            id: Self.showArchiveId,
            title: "语法档案",
            icon: "book"
        ))

        // 绑定快捷键 Cmd+K 到切换命令
        host.bindKeyboard(.cmd("k"), to: Self.toggleCommandId)
    }

    public func deactivate() {
        // 解绑快捷键
        host?.unbindKeyboard(.cmd("k"))

        // 取消注册命令
        host?.unregisterCommand(commandId: Self.toggleCommandId)
        host?.unregisterCommand(commandId: Self.showCommandId)
        host?.unregisterCommand(commandId: Self.hideCommandId)
        host?.unregisterCommand(commandId: Self.showArchiveId)
    }

    public func sidebarView(for tabId: String) -> AnyView? {
        switch tabId {
        case "grammar-archive":
            return AnyView(
                GrammarArchiveView()
                    .modelContainer(WritingDataStore.shared)
            )
        default:
            return nil
        }
    }

    public func infoPanelView(for id: String) -> AnyView? {
        guard id == "grammarArchive" else { return nil }
        return AnyView(
            GrammarArchiveView()
                .modelContainer(WritingDataStore.shared)
        )
    }

    /// 处理事件
    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        guard eventName == "command.invoked",
              let commandId = payload["commandId"] as? String else {
            return
        }

        switch commandId {
        case Self.toggleCommandId:
            host?.toggleBottomOverlay("composer")
        case Self.showCommandId:
            host?.showBottomOverlay("composer")
        case Self.hideCommandId:
            host?.hideBottomOverlay("composer")
        case Self.showArchiveId:
            host?.showInfoPanel("grammarArchive")
        default:
            break
        }
    }

    /// 提供 Composer 视图
    public func windowBottomOverlayView(for id: String) -> AnyView? {
        guard id == "composer", let host = host else { return nil }
        return AnyView(
            InlineComposerView(
                isShowing: .constant(true),
                inputHeight: .constant(0),
                onCancel: { [weak self] in
                    self?.host?.hideBottomOverlay("composer")
                },
                host: host
            )
        )
    }
}
