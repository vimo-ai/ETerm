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
        let subscription = EventBus.shared.subscribe(
            CoreEvents.Terminal.DidEndSelection.self,
            options: .default
        ) { [weak self] event in
            self?.handleSelectionEnd(event)
        }
        subscriptions.append(subscription)

        // 监听插件发射的事件，分发给订阅的插件
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePluginEvent(_:)),
            name: NSNotification.Name("ETerm.PluginEvent"),
            object: nil
        )

        print("[SDKEventBridge] Setup complete")
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

        // 查找订阅了 terminal.didEndSelection 的 SDK 插件
        let subscribingPlugins = findSubscribingPlugins(for: "terminal.didEndSelection")

        if subscribingPlugins.isEmpty {
            // 没有 SDK 插件订阅，使用内置逻辑（兼容模式）
            handleSelectionWithBuiltin(text: text, rect: event.screenRect, view: view)
            return
        }

        // 有 SDK 插件订阅，转发事件
        Task {
            for pluginId in subscribingPlugins {
                await ExtensionHostManager.shared.sendEvent(
                    name: "terminal.didEndSelection",
                    payload: payload,
                    targetPluginId: pluginId
                )
            }
        }

        // 显示 hint（如果翻译模式开启，则直接展开）
        let isTranslationMode = TranslationModeStore.shared.isEnabled
        let controller = TranslationController.shared

        if isTranslationMode {
            // 翻译模式：直接展开
            controller.show(text: text, at: event.screenRect, in: view)
            controller.state.expand()
        } else {
            // 普通模式：显示 hint
            controller.show(text: text, at: event.screenRect, in: view)
        }
    }

    /// 内置逻辑处理（兼容模式）
    private func handleSelectionWithBuiltin(text: String, rect: NSRect, view: NSView) {
        let isTranslationMode = TranslationModeStore.shared.isEnabled
        let controller = TranslationController.shared

        if isTranslationMode {
            controller.translateImmediately(text: text, at: rect, in: view)
        } else {
            controller.show(text: text, at: rect, in: view)
        }
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
