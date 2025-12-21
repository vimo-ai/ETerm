//
//  WritingAssistantPlugin.swift
//  ETerm
//
//  写作助手插件
//

import Foundation
import CoreGraphics

/// 写作助手插件
///
/// 提供 Cmd+K 快捷写作功能
final class WritingAssistantPlugin: Plugin {
    static let id = "writing-assistant"
    static let name = "写作助手"
    static let version = "1.0.0"

    private weak var context: PluginContext?

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 注册显示命令
        context.commands.register(Command(
            id: "writing.showComposer",
            title: "显示写作助手",
            icon: "sparkles"
        ) { ctx in
            // 通过 UIEvent 显示 composer
            ctx.coordinator?.sendUIEvent(.showComposer(position: .zero))
        })

        // 注册隐藏命令
        context.commands.register(Command(
            id: "writing.hideComposer",
            title: "隐藏写作助手"
        ) { ctx in
            ctx.coordinator?.sendUIEvent(.hideComposer)
        })

        // 注册切换命令
        context.commands.register(Command(
            id: "writing.toggleComposer",
            title: "切换写作助手"
        ) { ctx in
            // 通过 UIEvent 切换 composer（位置由 View 层确定）
            ctx.coordinator?.sendUIEvent(.toggleComposer(position: .zero))
        })

        // 绑定快捷键 Cmd+K
        context.keyboard.bind(.cmd("k"), to: "writing.toggleComposer", when: nil)
    }

    func deactivate() {
        context?.commands.unregister("writing.showComposer")
        context?.commands.unregister("writing.hideComposer")
        context?.commands.unregister("writing.toggleComposer")
        context?.keyboard.unbind(.cmd("k"))
    }
}
