//
//  EnglishLearningPlugin.swift
//  ETerm
//
//  统一的英语学习插件 - 包含翻译、单词本、语法档案功能
//

import Foundation
import AppKit
import SwiftUI
import Combine

/// 英语学习插件 - 提供翻译、单词本、语法档案等功能
final class EnglishLearningPlugin: Plugin {
    static let id = "english-learning"
    static let name = "英语学习"
    static let version = "1.0.0"

    // MARK: - 私有属性（翻译功能）

    /// 选中事件订阅
    private var selectionSubscription: EventSubscription?

    /// 划词翻译触发防抖
    private var selectionDebounce: DispatchWorkItem?

    /// 插件上下文（弱引用）
    private weak var context: PluginContext?

    /// 翻译模式状态
    private let translationMode = TranslationModeStore.shared

    // MARK: - 初始化

    required init() {}

    // MARK: - Plugin 协议

    func activate(context: PluginContext) {
        self.context = context

        print("🔌 [\(Self.name)] 激活中...")

        // 注册侧边栏 Tab
        registerSidebarTabs(context: context)

        // 注册翻译命令
        registerTranslationCommands(context: context)

        // 订阅翻译事件
        subscribeTranslationEvents(context: context)

        // 注册翻译内容到 InfoWindow
        registerInfoContent(context: context)

        print("✅ [\(Self.name)] 已激活")
    }

    func deactivate() {
        // 取消订阅
        selectionSubscription?.unsubscribe()
        selectionSubscription = nil
        selectionDebounce?.cancel()
        selectionDebounce = nil

        // 注销命令
        context?.commands.unregister("translation.show")
        context?.commands.unregister("translation.hide")

        print("🔌 [\(Self.name)] 已停用")
    }

    // MARK: - 注册侧边栏 Tab

    private func registerSidebarTabs(context: PluginContext) {
        // 1. 翻译配置
        let settingsTab = SidebarTab(
            id: "translation-settings",
            title: "翻译配置",
            icon: "gearshape.fill"
        ) {
            AnyView(TranslationPluginSettingsView())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: settingsTab)

        // 2. 单词本
        let vocabularyTab = SidebarTab(
            id: "vocabulary",
            title: "单词本",
            icon: "book.fill"
        ) {
            AnyView(VocabularyView())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: vocabularyTab)

        // 3. 语法档案
        let grammarTab = SidebarTab(
            id: "grammar-archive",
            title: "语法档案",
            icon: "doc.text.fill"
        ) {
            AnyView(GrammarArchiveView())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: grammarTab)

        print("✅ [\(Self.name)] 已注册 3 个侧边栏 Tab")
    }

    // MARK: - 注册翻译命令

    private func registerTranslationCommands(context: PluginContext) {
        // 显示翻译命令
        context.commands.register(Command(
            id: "translation.show",
            title: "显示翻译",
            icon: "sparkles"
        ) { _ in
            print("💬 translation.show 命令执行（当前无选中文本）")
        })

        // 隐藏翻译命令
        context.commands.register(Command(
            id: "translation.hide",
            title: "隐藏翻译"
        ) { _ in
            TranslationController.shared.hide()
        })
    }

    // MARK: - 订阅翻译事件

    private func subscribeTranslationEvents(context: PluginContext) {
        selectionSubscription = context.events.subscribe(TerminalEvent.selectionEnd) { [weak self] (payload: SelectionEndPayload) in
            self?.onSelectionEnd(payload)
        }
    }

    // MARK: - 注册信息窗口内容

    private func registerInfoContent(context: PluginContext) {
        context.ui.registerInfoContent(
            for: Self.id,
            id: "translation",
            title: "翻译"
        ) {
            AnyView(TranslationContentView(state: TranslationController.shared.state))
        }
    }

    // MARK: - 事件处理

    /// 处理选中结束事件
    private func onSelectionEnd(_ payload: SelectionEndPayload) {
        // 检查文本是否为空
        let trimmed = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let view = payload.sourceView else {
            return
        }

        // 异步显示翻译面板（避免阻塞事件发布者），并做 2s 防抖
        selectionDebounce?.cancel()
        let workItem = DispatchWorkItem {
            let controller = TranslationController.shared

            if self.translationMode.isEnabled {
                controller.translateImmediately(
                    text: trimmed,
                    at: payload.screenRect,
                    in: view
                )
            } else if controller.state.mode != .expanded {
                controller.show(
                    text: trimmed,
                    at: payload.screenRect,
                    in: view
                )
            }
        }
        selectionDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
}
