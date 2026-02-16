//
//  TranslationPlugin.swift
//  TranslationKit
//
//  语言工具插件 - 提供翻译、单词本、写作助手、语法档案功能 (SDK main 模式)

import Foundation
import SwiftUI
import SwiftData
import ETermKit

// MARK: - Plugin Entry

@objc(TranslationPlugin)
@MainActor
public final class TranslationPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.translation"
    private static let translateActionId = "com.eterm.translation.translate"

    // Writing 命令 ID
    private static let toggleCommandId = "writing.toggleComposer"
    private static let showCommandId = "writing.showComposer"
    private static let hideCommandId = "writing.hideComposer"
    private static let showArchiveId = "writing.showArchive"

    private var host: HostBridge?
    private var actionObserver: NSObjectProtocol?

    /// 翻译防抖任务
    private var translationDebounce: DispatchWorkItem?

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host

        // 初始化 DataStore（触发懒加载）
        _ = EnglishLearningDataStore.shared

        // 配置 AIService
        AIService.shared.configure(host: host)

        // 配置 TranslationController
        TranslationController.shared.configure(host: host)

        // 注册翻译 Action
        let action = SelectionAction(
            id: Self.translateActionId,
            title: "翻译",
            icon: "character.bubble",
            priority: 100,
            autoTriggerOnMode: "translation"
        )
        host.registerSelectionAction(action)

        // 监听 Action 触发事件
        actionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.SelectionActionTriggered"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleActionTriggered(notification)
            }
        }

        // --- Writing 功能注册 ---

        // 注册写作助手命令
        host.registerCommand(PluginCommand(
            id: Self.toggleCommandId,
            title: "切换写作助手",
            icon: "sparkles"
        ))

        host.registerCommand(PluginCommand(
            id: Self.showCommandId,
            title: "显示写作助手",
            icon: "sparkles"
        ))

        host.registerCommand(PluginCommand(
            id: Self.hideCommandId,
            title: "隐藏写作助手"
        ))

        host.registerCommand(PluginCommand(
            id: Self.showArchiveId,
            title: "语法档案",
            icon: "book"
        ))

        // 绑定快捷键 Cmd+K 到切换命令
        host.bindKeyboard(.cmd("k"), to: Self.toggleCommandId)
    }

    public func deactivate() {
        // 取消防抖任务
        translationDebounce?.cancel()
        translationDebounce = nil

        // 取消注册 Action
        host?.unregisterSelectionAction(actionId: Self.translateActionId)

        // 移除观察者
        if let observer = actionObserver {
            NotificationCenter.default.removeObserver(observer)
            actionObserver = nil
        }

        // --- Writing 功能清理 ---
        host?.unbindKeyboard(.cmd("k"))
        host?.unregisterCommand(commandId: Self.toggleCommandId)
        host?.unregisterCommand(commandId: Self.showCommandId)
        host?.unregisterCommand(commandId: Self.hideCommandId)
        host?.unregisterCommand(commandId: Self.showArchiveId)
    }

    public func sidebarView(for tabId: String) -> AnyView? {
        switch tabId {
        case "translation-settings":
            return AnyView(TranslationPluginSettingsView())
        case "vocabulary":
            return AnyView(
                VocabularyView()
                    .modelContainer(EnglishLearningDataStore.shared)
            )
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
        switch id {
        case "translation":
            return AnyView(
                TranslationContentView(state: TranslationController.shared.state)
            )
        case "grammarArchive":
            return AnyView(
                GrammarArchiveView()
                    .modelContainer(WritingDataStore.shared)
            )
        default:
            return nil
        }
    }

    public func pageBarView(for itemId: String) -> AnyView? {
        switch itemId {
        case "translation-mode-toggle":
            return AnyView(TranslationModeToggleView())
        default:
            return nil
        }
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "translation.toggle":
            TranslationModeStore.shared.toggle()
        default:
            break
        }
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

    // MARK: - Private

    private func handleActionTriggered(_ notification: Notification) {
        guard let actionId = notification.userInfo?["actionId"] as? String,
              actionId == Self.translateActionId,
              let text = notification.userInfo?["text"] as? String else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 忽略空文本和单字符
        guard trimmed.count > 1 else { return }

        // 获取位置信息
        let screenRect = notification.userInfo?["screenRect"] as? NSRect ?? .zero

        // 取消之前的防抖任务
        translationDebounce?.cancel()

        // 2 秒防抖延迟
        let workItem = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            TranslationController.shared.handleTranslate(text: trimmed, at: screenRect)
        }
        translationDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
}
