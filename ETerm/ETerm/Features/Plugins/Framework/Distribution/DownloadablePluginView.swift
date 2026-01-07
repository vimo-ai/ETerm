//
//  DownloadablePluginView.swift
//  ETerm
//
//  可下载插件视图
//

import SwiftUI
import Combine

/// 可下载插件列表视图
struct DownloadablePluginsView: View {
    @StateObject private var downloader = PluginDownloader.shared
    @State private var availablePlugins: [DownloadablePlugin] = []
    @State private var downloadingPluginId: String?
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?
    @State private var lastFailedPluginId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Text("可下载插件")
                    .font(.headline)
                Spacer()
                Button(action: refreshPluginList) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(downloader.isDownloading)
            }

            if availablePlugins.isEmpty {
                // 硬编码的可下载插件（MVP 阶段）
                VStack(spacing: 12) {
                    DownloadablePluginItemView(
                        plugin: Self.vlaudeKitPlugin,
                        isDownloading: downloadingPluginId == Self.vlaudeKitPlugin.id,
                        progress: downloadProgress,
                        errorMessage: downloadingPluginId == nil ? errorMessage : nil,
                        lastFailedPluginId: lastFailedPluginId,
                        onInstall: { await installPlugin(Self.vlaudeKitPlugin) }
                    )

                    DownloadablePluginItemView(
                        plugin: Self.memexKitPlugin,
                        isDownloading: downloadingPluginId == Self.memexKitPlugin.id,
                        progress: downloadProgress,
                        errorMessage: downloadingPluginId == nil ? errorMessage : nil,
                        lastFailedPluginId: lastFailedPluginId,
                        onInstall: { await installPlugin(Self.memexKitPlugin) }
                    )
                }
            } else {
                ForEach(availablePlugins) { plugin in
                    DownloadablePluginItemView(
                        plugin: plugin,
                        isDownloading: downloadingPluginId == plugin.id,
                        progress: downloadProgress,
                        errorMessage: downloadingPluginId == nil ? errorMessage : nil,
                        lastFailedPluginId: lastFailedPluginId,
                        onInstall: { await installPlugin(plugin) }
                    )
                }
            }

            // 错误提示
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("关闭") {
                        errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private func refreshPluginList() {
        // MVP: 暂时使用硬编码列表
        // TODO: 从远程获取插件索引
    }

    private func installPlugin(_ plugin: DownloadablePlugin) async {
        downloadingPluginId = plugin.id
        downloadProgress = 0
        errorMessage = nil
        lastFailedPluginId = nil

        do {
            let result = try await downloader.installPlugin(plugin) { progress in
                Task { @MainActor in
                    downloadProgress = progress.progress
                }
            }

            if result.success {
                // 刷新插件列表
                PluginManager.shared.objectWillChange.send()
            }
        } catch let error as DownloadError {
            errorMessage = error.errorDescription
            lastFailedPluginId = plugin.id
        } catch {
            errorMessage = error.localizedDescription
            lastFailedPluginId = plugin.id
        }

        downloadingPluginId = nil
    }

    // MARK: - 硬编码的插件信息（MVP）

    static let vlaudeKitPlugin = DownloadablePlugin(
        id: "com.eterm.vlaude",
        name: "VlaudeKit",
        version: "0.0.1-beta.1",
        description: "从 iOS 查看和控制 Claude",
        size: 10 * 1024 * 1024, // ~10MB
        downloadUrl: "https://github.com/vimo-ai/ETerm/releases/download/vlaudekit-v0.0.1-beta.1/VlaudeKit.bundle.zip",
        sha256: nil,
        runtimeDeps: [
            RuntimeDependency(
                name: "libclaude_session_db",
                minVersion: "0.0.1-beta.1",
                path: "lib/libclaude_session_db.dylib",
                sha256: nil,
                downloadUrl: "https://github.com/vimo-ai/ai-cli-session-db/releases/download/v0.0.1-beta.1/libclaude_session_db.dylib"
            ),
            RuntimeDependency(
                name: "libsocket_client_ffi",
                minVersion: "0.0.1-beta.1",
                path: "lib/libsocket_client_ffi.dylib",
                sha256: nil,
                downloadUrl: "https://github.com/vimo-ai/vlaude/releases/download/socket-ffi-v0.0.1-beta.1/libsocket_client_ffi.dylib"
            )
        ]
    )

    static let memexKitPlugin = DownloadablePlugin(
        id: "com.eterm.memex",
        name: "MemexKit",
        version: "0.0.1-beta.1",
        description: "Claude 会话历史搜索",
        size: 123 * 1024 * 1024, // ~123MB
        downloadUrl: "https://github.com/vimo-ai/ETerm/releases/download/memexkit-v0.0.1-beta.1/MemexKit.bundle.zip",
        sha256: nil,
        runtimeDeps: [
            RuntimeDependency(
                name: "libclaude_session_db",
                minVersion: "0.0.1-beta.1",
                path: "lib/libclaude_session_db.dylib",
                sha256: nil,
                downloadUrl: "https://github.com/vimo-ai/ai-cli-session-db/releases/download/v0.0.1-beta.1/libclaude_session_db.dylib"
            ),
            RuntimeDependency(
                name: "memex",
                minVersion: "0.0.1-beta.1",
                path: "bin/memex",
                sha256: nil,
                downloadUrl: "https://github.com/vimo-ai/memex/releases/download/v0.0.1-beta.1/memex-darwin-arm64"
            )
        ]
    )
}

/// 可下载插件项视图
struct DownloadablePluginItemView: View {
    let plugin: DownloadablePlugin
    let isDownloading: Bool
    let progress: Double
    let errorMessage: String?
    let lastFailedPluginId: String?
    let onInstall: () async -> Void

    @State private var isInstalled = false

    /// 当前插件是否安装失败
    private var hasInstallError: Bool {
        lastFailedPluginId == plugin.id && errorMessage != nil
    }

    var body: some View {
        HStack(spacing: 16) {
            // 图标
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(plugin.name)
                    .font(.headline)

                if let desc = plugin.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("v\(plugin.version)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(plugin.formattedSize)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // 共享依赖提示
                    if let deps = plugin.runtimeDeps, !deps.isEmpty {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(deps.count) 个依赖")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            // 安装按钮/进度
            if isDownloading {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if hasInstallError {
                // 安装失败，显示重试按钮
                Button("重试") {
                    Task {
                        await onInstall()
                        isInstalled = VersionManager.shared.isPluginInstalled(plugin.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else if isInstalled || VersionManager.shared.isPluginInstalled(plugin.id) {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button("安装") {
                    Task {
                        await onInstall()
                        // 安装后重新检查 VersionManager，而不是盲目设为 true
                        isInstalled = VersionManager.shared.isPluginInstalled(plugin.id)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            isInstalled = VersionManager.shared.isPluginInstalled(plugin.id)
        }
    }
}

#Preview {
    DownloadablePluginsView()
        .frame(width: 500)
        .padding()
}
