//
//  GlobalConfigProvider.swift
//  ETerm
//
//  定义通用的全局配置 Provider 协议
//

import Foundation

protocol GlobalConfigProvider: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var descriptionText: String { get }
    var configPath: URL { get }

    func isInstalled() throws -> Bool
    func install(port: Int) throws
    func uninstall() throws
}

// MARK: - Claude Provider

struct ClaudeGlobalConfigProvider: GlobalConfigProvider {
    let id = "claude"
    let displayName = "Claude CLI"
    let descriptionText = "将 mcp-router 安装到 ~/.claude.json 的根配置，所有 Claude Code workspace 均可直接访问。"

    var configPath: URL {
        ClaudeConfigManager.configPath
    }

    func isInstalled() throws -> Bool {
        try ClaudeConfigManager.isInstalledToGlobal()
    }

    func install(port: Int) throws {
        try ClaudeConfigManager.installToGlobal(port: port)
    }

    func uninstall() throws {
        try ClaudeConfigManager.uninstallFromGlobal()
    }
}

// MARK: - Codex Provider

struct CodexGlobalConfigProvider: GlobalConfigProvider {
    let id = "codex"
    let displayName = "Codex"
    let descriptionText = "写入 ~/.codex/config.toml，令所有 Codex workspace 共享 mcp-router。"

    var configPath: URL {
        CodexConfigManager.configPath
    }

    func isInstalled() throws -> Bool {
        try CodexConfigManager.isInstalledToGlobal()
    }

    func install(port: Int) throws {
        try CodexConfigManager.installToGlobal(port: port)
    }

    func uninstall() throws {
        try CodexConfigManager.uninstallFromGlobal()
    }
}

// MARK: - All Providers

enum GlobalConfigProviders {
    static let all: [any GlobalConfigProvider] = [
        ClaudeGlobalConfigProvider(),
        CodexGlobalConfigProvider()
    ]
}
