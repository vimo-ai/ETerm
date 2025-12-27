//
//  SDKEventBridge.swift
//  ETerm
//
//  事件桥接 - 将核心事件转发给 SDK 插件

import Foundation
import AppKit
import ETermKit

/// SDK 事件桥接
///
/// 职责：
/// - 监听核心事件（如 terminal.didEndSelection）
/// - 根据 manifest.subscribes 转发给订阅的 SDK 插件
/// - 协调 TranslationController 显示 hint/bubble
final class SDKEventBridge {

    static let shared = SDKEventBridge()

    private var subscriptions: [EventSubscription] = []
    private var selectionDebounce: DispatchWorkItem?

    private init() {}

    // MARK: - Setup

    /// 设置事件监听（在 SDK 插件加载完成后调用）
    func setup() {
        // 监听选中结束事件
        let selectionSub = EventBus.shared.subscribe(
            CoreEvents.Terminal.DidEndSelection.self,
            options: .default
        ) { [weak self] event in
            self?.handleSelectionEnd(event)
        }
        subscriptions.append(selectionSub)

        // 监听终端创建事件
        let createSub = EventBus.shared.subscribe(
            CoreEvents.Terminal.DidCreate.self,
            options: .default
        ) { [weak self] event in
            self?.handleTerminalCreate(event)
        }
        subscriptions.append(createSub)

        // 监听终端关闭事件
        let closeSub = EventBus.shared.subscribe(
            CoreEvents.Terminal.DidClose.self,
            options: .default
        ) { [weak self] event in
            self?.handleTerminalClose(event)
        }
        subscriptions.append(closeSub)

        // 监听 Tab 激活事件
        let tabActivateSub = EventBus.shared.subscribe(
            CoreEvents.Tab.DidActivate.self,
            options: .default
        ) { [weak self] event in
            self?.handleTabActivate(event)
        }
        subscriptions.append(tabActivateSub)

        // 监听插件发射的事件，分发给订阅的插件
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePluginEvent(_:)),
            name: NSNotification.Name("ETerm.PluginEvent"),
            object: nil
        )

        // 监听命令调用事件，转发给对应插件
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCommandInvoked(_:)),
            name: NSNotification.Name("ETerm.CommandInvoked"),
            object: nil
        )
    }

    // MARK: - Terminal Events

    private func handleTerminalCreate(_ event: CoreEvents.Terminal.DidCreate) {
        let payload: [String: Any] = [
            "terminalId": event.terminalId,
            "tabId": event.tabId
        ]
        dispatchEvent("terminal.didCreate", payload: payload)
    }

    private func handleTerminalClose(_ event: CoreEvents.Terminal.DidClose) {
        var payload: [String: Any] = [
            "terminalId": event.terminalId
        ]
        if let tabId = event.tabId {
            payload["tabId"] = tabId
        }
        dispatchEvent("terminal.didClose", payload: payload)
    }

    private func handleTabActivate(_ event: CoreEvents.Tab.DidActivate) {
        let payload: [String: Any] = [
            "terminalId": event.terminalId
        ]
        dispatchEvent("tab.didActivate", payload: payload)
    }

    /// 分发事件给订阅的 SDK 插件
    private func dispatchEvent(_ eventName: String, payload: [String: Any]) {
        let subscribingPluginIds = findSubscribingPlugins(for: eventName)
        for pluginId in subscribingPluginIds {
            if let plugin = SDKPluginLoader.shared.getMainModePlugin(pluginId) {
                plugin.handleEvent(eventName, payload: payload)
            }
        }
    }

    // MARK: - Plugin Event Dispatch

    @objc private func handlePluginEvent(_ notification: Notification) {
        guard let eventName = notification.userInfo?["eventName"] as? String,
              let payload = notification.userInfo?["payload"] as? [String: Any] else {
            return
        }

        // 查找订阅了此事件的插件并分发
        let subscribingPluginIds = findSubscribingPlugins(for: eventName)
        for pluginId in subscribingPluginIds {
            if let plugin = SDKPluginLoader.shared.getMainModePlugin(pluginId) {
                plugin.handleEvent(eventName, payload: payload)
            }
        }
    }

    @objc private func handleCommandInvoked(_ notification: Notification) {
        guard let pluginId = notification.userInfo?["pluginId"] as? String,
              let commandId = notification.userInfo?["commandId"] as? String else {
            return
        }

        let terminalId = notification.userInfo?["terminalId"] as? Int

        // 构建 payload
        var payload: [String: Any] = ["commandId": commandId]
        if let tid = terminalId {
            payload["terminalId"] = tid
        }

        // 转发给对应插件
        if let plugin = SDKPluginLoader.shared.getMainModePlugin(pluginId) {
            plugin.handleEvent("command.invoked", payload: payload)
        }
    }

    // MARK: - Event Handlers

    private func handleSelectionEnd(_ event: CoreEvents.Terminal.DidEndSelection) {
        let trimmedText = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // 防抖：0.3s 内重复选中只触发一次
        selectionDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processSelection(event)
        }
        selectionDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func processSelection(_ event: CoreEvents.Terminal.DidEndSelection) {
        guard let view = event.sourceView else { return }

        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "text": text
        ]

        // 1. 转发原始事件给订阅的插件（用于数据记录等）
        let subscribingPlugins = findSubscribingPlugins(for: "terminal.didEndSelection")
        for pluginId in subscribingPlugins {
            if let mainPlugin = SDKPluginLoader.shared.getMainModePlugin(pluginId) {
                mainPlugin.handleEvent("terminal.didEndSelection", payload: payload)
            } else {
                Task {
                    await ExtensionHostManager.shared.sendEvent(
                        name: "terminal.didEndSelection",
                        payload: payload,
                        targetPluginId: pluginId
                    )
                }
            }
        }

        // 2. 检查激活模式，自动触发匹配的 Action（如翻译模式）
        if let activeMode = getActiveMode(),
           let autoAction = SelectionActionRegistry.shared.getActionForMode(activeMode) {
            // 自动触发（传递位置信息）
            SelectionPopoverController.shared.triggerAction(autoAction.id, text: text, at: event.screenRect)
        }

        // 注：其他 Actions 通过右键菜单触发，不再自动显示 Popover
    }

    /// 获取当前激活的模式
    private func getActiveMode() -> String? {
        if TranslationModeStore.shared.isEnabled {
            return "translation"
        }
        return nil
    }

    /// 查找订阅了指定事件的 SDK 插件
    private func findSubscribingPlugins(for eventName: String) -> [String] {
        var result: [String] = []

        // 遍历已加载的 manifest，检查 subscribes
        for (pluginId, manifest) in SDKPluginLoader.shared.getLoadedManifests() {
            if manifest.subscribes.contains(eventName) {
                result.append(pluginId)
            }
        }

        return result
    }
}
