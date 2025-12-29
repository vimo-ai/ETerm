//
//  MemexPlugin.swift
//  MemexKit
//
//  Claude 会话搜索插件 (HTTP 服务模式)
//
//  职责：
//  - 启动/停止 memex HTTP 服务
//  - 提供侧边栏搜索 UI
//  - MCP 服务通过 HTTP 端点提供
//

import Foundation
import AppKit
import SwiftUI
import ETermKit

@objc(MemexPlugin)
public final class MemexPlugin: NSObject, Plugin {
    public static var id = "com.eterm.memex"

    private weak var host: HostBridge?

    public override required init() {
        super.init()
    }

    // MARK: - Plugin Lifecycle

    public func activate(host: HostBridge) {
        self.host = host

        // 启动 memex HTTP 服务
        Task { @MainActor in
            do {
                try MemexService.shared.start()
            } catch {
                print("[MemexKit] Failed to start service: \(error.localizedDescription)")
            }
        }
    }

    public func deactivate() {
        // 同步停止服务（不能用 Task，否则 app 退出时可能来不及执行）
        MemexService.shared.stop()
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 处理 Claude 响应完成事件，触发精确索引
        guard eventName == "claude.responseComplete" else { return }
        guard let transcriptPath = payload["transcriptPath"] as? String else {
            print("[MemexKit] Missing transcriptPath in responseComplete event")
            return
        }

        // 异步调用索引 API（静默失败，不阻断主流程）
        Task {
            do {
                try await MemexService.shared.indexSession(path: transcriptPath)
                print("[MemexKit] Indexed session: \(transcriptPath)")
            } catch {
                print("[MemexKit] Failed to index session: \(error.localizedDescription)")
            }
        }
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        guard tabId == "memex" else { return nil }
        return AnyView(MemexView())
    }

    public func bottomDockView(for id: String) -> AnyView? {
        nil
    }

    public func infoPanelView(for id: String) -> AnyView? {
        nil
    }

    public func bubbleView(for id: String) -> AnyView? {
        nil
    }

    public func menuBarView() -> AnyView? {
        nil
    }

    public func pageBarView(for itemId: String) -> AnyView? {
        nil
    }

    public func windowBottomOverlayView(for id: String) -> AnyView? {
        nil
    }

    public func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
        nil
    }

    public func pageSlotView(for slotId: String, page: any PageSlotContext) -> AnyView? {
        nil
    }
}
