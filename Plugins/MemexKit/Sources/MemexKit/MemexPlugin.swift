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
@MainActor
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
            try? MemexService.shared.start()
        }
    }

    public func deactivate() {
        // 同步停止服务（不能用 Task，否则 app 退出时可能来不及执行）
        MemexService.shared.stop()
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 处理 AI CLI 响应完成事件，触发精确采集和 Compact
        guard eventName == "aicli.responseComplete" else { return }
        guard let transcriptPath = payload["transcriptPath"] as? String else { return }

        // 从路径中提取 session ID（文件名不含扩展名）
        // 路径格式: ~/.claude/projects/{encoded-project-path}/{session-uuid}.jsonl
        let sessionId = (transcriptPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")

        // 异步调用采集和 Compact（静默失败，不阻断主流程）
        // 注意：MemexService 是 @MainActor，普通 Task 会回到主线程，必须用 DispatchQueue.global
        DispatchQueue.global(qos: .utility).async {
            // 1. 精确采集会话（Writer 直接写入数据库，FTS 通过触发器自动更新）
            //
            // **重要**: 必须由 Writer 直接调用 collectByPath，不能依赖 HTTP API 转发给 daemon。
            // 因为当 Kit 是 Writer 时，daemon 是 Reader，无法执行写入操作。
            // 之前的实现通过 HTTP 调用 daemon 的 /api/index，但忽略了 daemon 可能是 Reader 的情况，
            // 导致采集失败。daemon 的文件监控只是兜底机制（当 Kit 未运行时）。
            try? MemexService.shared.collectByPath(transcriptPath)

            // 2. 触发 Compact（L1 + L2，如果启用的话）
            Task {
                try? await MemexService.shared.triggerCompact(sessionId: sessionId)
            }
        }
    }

    public func handleCommand(_ commandId: String) {
        // 暂无命令
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        switch tabId {
        case "memex", "memex-status":
            return AnyView(MemexStatusView())
        case "memex-web":
            return AnyView(MemexWebOnlyView())
        default:
            return nil
        }
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
