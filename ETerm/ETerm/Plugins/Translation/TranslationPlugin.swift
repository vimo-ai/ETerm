//
//  TranslationPlugin.swift
//  ETerm
//
//  插件层 - 划词翻译插件

import Foundation
import AppKit

/// 划词翻译插件
///
/// 功能：
/// - 监听终端文本选中事件
/// - 触发翻译面板显示
/// - 提供翻译相关命令
final class TranslationPlugin: Plugin {
    static let id = "translation"
    static let name = "划词翻译"
    static let version = "1.0.0"

    // MARK: - 私有属性

    /// 选中事件订阅
    private var selectionSubscription: EventSubscription?

    /// 插件上下文（弱引用）
    private weak var context: PluginContext?

    // MARK: - 初始化

    required init() {}

    // MARK: - Plugin 协议

    func activate(context: PluginContext) {
        self.context = context

        // 注册命令
        registerCommands(context: context)

        // 订阅事件
        subscribeEvents(context: context)

        print("✅ \(Self.name) 已激活")
    }

    func deactivate() {
        // 取消订阅
        selectionSubscription?.unsubscribe()
        selectionSubscription = nil

        // 注销命令
        context?.commands.unregister("translation.show")
        context?.commands.unregister("translation.hide")

        print("🔌 \(Self.name) 已停用")
    }

    // MARK: - 注册命令

    private func registerCommands(context: PluginContext) {
        // 显示翻译命令
        context.commands.register(Command(
            id: "translation.show",
            title: "显示翻译",
            icon: "sparkles"
        ) { _ in
            // 显示翻译（如果有选中文本）
            // 此命令主要用于快捷键绑定
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

    // MARK: - 订阅事件

    private func subscribeEvents(context: PluginContext) {
        // 订阅选中结束事件
        selectionSubscription = context.events.subscribe(TerminalEvent.selectionEnd) { [weak self] (payload: SelectionEndPayload) in
            self?.onSelectionEnd(payload)
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

        // 异步显示翻译面板（避免阻塞事件发布者）
        DispatchQueue.main.async {
            TranslationController.shared.show(
                text: trimmed,
                at: payload.screenRect,
                in: view
            )
        }
    }
}
