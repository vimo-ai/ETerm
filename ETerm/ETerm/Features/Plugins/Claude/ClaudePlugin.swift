//
//  ClaudePlugin.swift
//  ETerm
//
//  Claude Code 集成插件
//  负责：接收 Claude Hook 回调，管理 session 映射

import Foundation

final class ClaudePlugin: Plugin {
    static let id = "claude"
    static let name = "Claude Integration"
    static let version = "1.0.0"

    private var socketServer: ClaudeSocketServer?

    required init() {}

    func activate(context: PluginContext) {
        // 启动 Socket Server（接收 Claude Hook）
        socketServer = ClaudeSocketServer.shared
        socketServer?.start()

    }

    func deactivate() {
        socketServer?.stop()
    }
}
