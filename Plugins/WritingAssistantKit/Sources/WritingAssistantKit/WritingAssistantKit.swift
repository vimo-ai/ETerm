//
//  WritingAssistantKit.swift
//  WritingAssistantKit
//
//  写作助手插件入口
//

import Foundation

/// WritingAssistantKit - 写作助手插件
///
/// 提供 Cmd+K 快捷写作功能，帮助用户快速唤起写作助手界面。
///
/// ## 功能
///
/// - 通过 Cmd+K 快捷键切换写作助手界面
/// - 支持显示/隐藏/切换三种操作
///
/// ## 命令
///
/// - `writing.showComposer`: 显示写作助手
/// - `writing.hideComposer`: 隐藏写作助手
/// - `writing.toggleComposer`: 切换写作助手
public struct WritingAssistantKit {
    /// 库版本
    public static let version = "1.0.0"
}
