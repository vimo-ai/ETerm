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
    @ObservedObject private var downloader = PluginDownloader.shared
    @State private var availablePlugins: [DownloadablePlugin] = []

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
                        downloader: downloader
                    )

                    DownloadablePluginItemView(
                        plugin: Self.memexKitPlugin,
                        downloader: downloader
                    )
                }
            } else {
                ForEach(availablePlugins) { plugin in
                    DownloadablePluginItemView(
                        plugin: plugin,
                        downloader: downloader
                    )
                }
            }

            // 错误提示
            if let error = downloader.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("关闭") {
                        downloader.clearError()
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
                name: "libai_cli_session_db",
                minVersion: "0.0.1-beta.1",
                path: "lib/libai_cli_session_db.dylib",
                sha256: nil,
                downloadUrl: "https://github.com/vimo-ai/ai-cli-session-db/releases/download/v0.0.1-beta.1/libai_cli_session_db.dylib"
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
                name: "libai_cli_session_db",
                minVersion: "0.0.1-beta.1",
                path: "lib/libai_cli_session_db.dylib",
                sha256: nil,
                downloadUrl: "https://github.com/vimo-ai/ai-cli-session-db/releases/download/v0.0.1-beta.1/libai_cli_session_db.dylib"
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
    @ObservedObject var downloader: PluginDownloader

    @State private var pluginStatus: PluginStatus = .notInstalled

    /// 当前插件是否正在下载
    private var isDownloading: Bool {
        downloader.isDownloading && downloader.downloadingPluginId == plugin.id
    }

    /// 当前插件是否安装失败
    private var hasInstallError: Bool {
        downloader.lastFailedPluginId == plugin.id && downloader.errorMessage != nil
    }

    var body: some View {
        HStack(spacing: 16) {
            // 图标
            Image(systemName: iconName)
                .font(.system(size: 24))
                .foregroundColor(iconColor)
                .frame(width: 40, height: 40)
                .background(iconColor.opacity(0.1))
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
                    // 当前下载文件名
                    if let fileName = downloader.currentFileName {
                        Text(fileName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 8) {
                        ProgressView(value: downloader.downloadProgress)
                            .frame(width: 80)
                        Text("\(Int(downloader.downloadProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }

                    // 取消按钮
                    Button("取消") {
                        downloader.cancelDownload()
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            } else if hasInstallError {
                // 安装失败，显示重试按钮
                Button("重试") {
                    downloader.startInstall(plugin)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                actionButton
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            refreshStatus()
        }
        .onChange(of: downloader.isDownloading) { _, isDownloading in
            // 下载完成后刷新安装状态
            if !isDownloading {
                refreshStatus()
            }
        }
    }

    // MARK: - 状态相关的视图属性

    /// 根据状态显示不同的操作按钮
    @ViewBuilder
    private var actionButton: some View {
        switch pluginStatus {
        case .notInstalled:
            Button("安装") {
                downloader.startInstall(plugin)
            }
            .buttonStyle(.borderedProminent)
            .disabled(downloader.isDownloading)

        case .installed:
            Label("已安装", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)

        case .updateAvailable(let from, let to):
            Button {
                downloader.startInstall(plugin)
            } label: {
                VStack(spacing: 2) {
                    Text("更新")
                    Text("\(from) → \(to)")
                        .font(.caption2)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(downloader.isDownloading)
        }
    }

    /// 图标名称
    private var iconName: String {
        switch pluginStatus {
        case .notInstalled:
            return "arrow.down.circle.fill"
        case .installed:
            return "checkmark.circle.fill"
        case .updateAvailable:
            return "arrow.up.circle.fill"
        }
    }

    /// 图标颜色
    private var iconColor: Color {
        switch pluginStatus {
        case .notInstalled:
            return .blue
        case .installed:
            return .green
        case .updateAvailable:
            return .orange
        }
    }

    /// 刷新插件状态
    private func refreshStatus() {
        pluginStatus = VersionManager.shared.getPluginStatus(
            id: plugin.id,
            remoteVersion: plugin.version
        )
    }
}

#Preview {
    DownloadablePluginsView()
        .frame(width: 500)
        .padding()
}
