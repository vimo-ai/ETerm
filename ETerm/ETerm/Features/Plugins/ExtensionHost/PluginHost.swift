//
//  PluginHost.swift
//  ETerm
//
//  统一的插件宿主接口
//  主程序通过此接口调用插件，不关心底层是主进程模式还是隔离模式

import Foundation
import SwiftUI
import ETermKit

/// 插件宿主协议
///
/// 主程序使用的统一接口，屏蔽 `main` 和 `isolated` 两种运行模式的差异。
@MainActor
protocol PluginHost: AnyObject {

    /// 插件 ID
    var id: String { get }

    /// 插件 Manifest
    var manifest: PluginManifest { get }

    // MARK: - UI

    /// 获取侧边栏视图
    func sidebarView(for tabId: String) -> AnyView?

    /// 获取底部停靠视图
    func bottomDockView(for id: String) -> AnyView?

    /// 获取信息面板视图
    func infoPanelView(for id: String) -> AnyView?

    /// 获取气泡内容视图
    func bubbleView(for id: String) -> AnyView?

    /// 获取 MenuBar 视图
    func menuBarView() -> AnyView?

    // MARK: - 事件/命令

    /// 发送事件到插件
    func sendEvent(_ eventName: String, payload: [String: Any])

    /// 发送命令到插件
    func sendCommand(_ commandId: String)
}

// MARK: - 主进程模式适配器

/// 主进程模式插件宿主
///
/// 直接持有 Plugin 实例，所有调用都在主进程内完成。
final class MainModePluginHost: PluginHost {

    private let plugin: any ETermKit.Plugin
    let manifest: PluginManifest

    var id: String { manifest.id }

    init(plugin: any ETermKit.Plugin, manifest: PluginManifest) {
        self.plugin = plugin
        self.manifest = manifest
    }

    func sidebarView(for tabId: String) -> AnyView? {
        plugin.sidebarView(for: tabId)
    }

    func bottomDockView(for id: String) -> AnyView? {
        plugin.bottomDockView(for: id)
    }

    func infoPanelView(for id: String) -> AnyView? {
        plugin.infoPanelView(for: id)
    }

    func bubbleView(for id: String) -> AnyView? {
        plugin.bubbleView(for: id)
    }

    func menuBarView() -> AnyView? {
        plugin.menuBarView()
    }

    func sendEvent(_ eventName: String, payload: [String: Any]) {
        plugin.handleEvent(eventName, payload: payload)
    }

    func sendCommand(_ commandId: String) {
        plugin.handleCommand(commandId)
    }
}

// MARK: - 隔离模式适配器

/// 隔离模式插件宿主
///
/// 持有 ViewProvider（主进程）和 IPC 桥接，事件/命令通过 IPC 发送到子进程。
final class IsolatedModePluginHost: PluginHost {

    private let viewProvider: (any PluginViewProvider)?
    let manifest: PluginManifest

    var id: String { manifest.id }

    init(viewProvider: (any PluginViewProvider)?, manifest: PluginManifest) {
        self.viewProvider = viewProvider
        self.manifest = manifest
    }

    func sidebarView(for tabId: String) -> AnyView? {
        viewProvider?.view(for: tabId)
    }

    func bottomDockView(for id: String) -> AnyView? {
        viewProvider?.createBottomDockView(id: id)
    }

    func infoPanelView(for id: String) -> AnyView? {
        viewProvider?.createInfoPanelView(id: id)
    }

    func bubbleView(for id: String) -> AnyView? {
        viewProvider?.createBubbleContentView(id: id)
    }

    func menuBarView() -> AnyView? {
        viewProvider?.createMenuBarView()
    }

    func sendEvent(_ eventName: String, payload: [String: Any]) {
        // 通过 IPC 发送到子进程
        Task {
            await ExtensionHostManager.shared.getBridge()?.sendEvent(
                name: eventName,
                payload: payload,
                targetPluginId: manifest.id
            )
        }
    }

    func sendCommand(_ commandId: String) {
        // 通过 IPC 发送到子进程
        Task {
            do {
                try await ExtensionHostManager.shared.getBridge()?.sendCommand(
                    pluginId: manifest.id,
                    commandId: commandId
                )
            } catch {
                logError("[IsolatedModePluginHost] Failed to send command: \(error)")
            }
        }
    }
}
