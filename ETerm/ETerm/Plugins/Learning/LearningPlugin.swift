//
//  LearningPlugin.swift
//  ETerm
//
//  学习插件 - 单词本和语法档案
//

import Foundation
import SwiftUI

/// 学习插件 - 提供单词本和语法档案功能
final class LearningPlugin: Plugin {
    static let id = "learning"
    static let name = "学习助手"
    static let version = "1.0.0"

    func activate(context: PluginContext) {
        print("🔌 [\(Self.name)] 激活中...")

        // 注册单词本 Tab
        let vocabularyTab = SidebarTab(
            id: "vocabulary",
            title: "单词本",
            icon: "book.fill"
        ) {
            AnyView(VocabularyView())
        }
        context.ui.registerSidebarTab(for: Self.id, tab: vocabularyTab)

        // 注册语法档案 Tab
        let grammarTab = SidebarTab(
            id: "grammar-archive",
            title: "语法档案",
            icon: "doc.text.fill"
        ) {
            AnyView(GrammarArchiveView())
        }
        context.ui.registerSidebarTab(for: Self.id, tab: grammarTab)

        print("✅ [\(Self.name)] 已注册 2 个侧边栏 Tab")
    }

    func deactivate() {
        print("🔌 [\(Self.name)] 停用")
    }
}
