//
//  OnboardingView.swift
//  ETerm
//
//  首次启动引导视图
//

import SwiftUI

/// 首次启动引导视图
struct OnboardingView: View {
    @StateObject private var downloader = PluginDownloader.shared
    @ObservedObject var onboardingManager = OnboardingManager.shared

    /// 选中的插件
    @State private var selectedPlugins: Set<String> = []

    /// 下载状态
    @State private var isDownloading = false
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadErrors: [String: String] = [:]
    @State private var completedPlugins: Set<String> = []

    /// 可下载插件列表
    private let downloadablePlugins: [DownloadablePlugin] = [
        DownloadablePluginsView.memexKitPlugin,
        DownloadablePluginsView.vlaudeKitPlugin
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 标题区域
            headerSection

            Divider()

            // 内容区域
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 就绪信息
                    readySection

                    Divider()
                        .padding(.vertical, 4)

                    // 可选下载区域
                    optionalDownloadSection
                }
                .padding(24)
            }

            Divider()

            // 底部按钮
            footerSection
        }
        .frame(width: 480, height: 420)
        .onAppear {
            updateInstalledState()
        }
    }

    // MARK: - 子视图

    /// 标题区域
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Text("ETerm 已准备就绪")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// 就绪信息
    private var readySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("终端功能已可用")
                    .font(.body)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("9 个内置插件已加载")
                    .font(.body)
            }
        }
        .padding(.leading, 4)
    }

    /// 可选下载区域
    private var optionalDownloadSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("可选功能（需下载）")
                .font(.headline)
                .foregroundColor(.secondary)

            ForEach(downloadablePlugins, id: \.id) { plugin in
                pluginRow(plugin)
            }

            // 提示信息
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("稍后可在 设置 → 插件 中安装")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    /// 插件行
    private func pluginRow(_ plugin: DownloadablePlugin) -> some View {
        let isInstalled = completedPlugins.contains(plugin.id) ||
                          VersionManager.shared.isPluginInstalled(plugin.id)
        let isPluginDownloading = isDownloading && selectedPlugins.contains(plugin.id) && !isInstalled
        let progress = downloadProgress[plugin.id] ?? 0
        let error = downloadErrors[plugin.id]

        return HStack(spacing: 12) {
            // 复选框或状态图标
            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .frame(width: 20)
            } else if isPluginDownloading {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20)
            } else {
                Button {
                    togglePlugin(plugin.id)
                } label: {
                    Image(systemName: selectedPlugins.contains(plugin.id) ? "checkmark.square.fill" : "square")
                        .foregroundColor(selectedPlugins.contains(plugin.id) ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .disabled(isDownloading)
            }

            // 插件信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plugin.name)
                        .font(.body)
                        .fontWeight(.medium)

                    if isInstalled {
                        Text("已安装")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                if let desc = plugin.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 下载进度
                if isPluginDownloading {
                    ProgressView(value: progress)
                        .frame(height: 4)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // 错误信息
                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            // 大小
            if !isInstalled && !isPluginDownloading {
                Text(plugin.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    /// 底部按钮区域
    private var footerSection: some View {
        HStack {
            // 跳过按钮
            Button("跳过") {
                onboardingManager.skipOnboarding()
            }
            .buttonStyle(.borderless)
            .disabled(isDownloading)

            Spacer()

            // 安装按钮
            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在安装...")
                        .foregroundColor(.secondary)
                }
            } else {
                Button("安装选中") {
                    Task {
                        await installSelectedPlugins()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPlugins.isEmpty || allSelectedInstalled())
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 操作

    private func togglePlugin(_ id: String) {
        if selectedPlugins.contains(id) {
            selectedPlugins.remove(id)
        } else {
            selectedPlugins.insert(id)
        }
    }

    private func updateInstalledState() {
        // 检查哪些插件已安装
        for plugin in downloadablePlugins {
            if VersionManager.shared.isPluginInstalled(plugin.id) {
                completedPlugins.insert(plugin.id)
            }
        }
    }

    private func allSelectedInstalled() -> Bool {
        selectedPlugins.allSatisfy { completedPlugins.contains($0) }
    }

    private func installSelectedPlugins() async {
        isDownloading = true
        downloadErrors.removeAll()

        for plugin in downloadablePlugins where selectedPlugins.contains(plugin.id) {
            // 跳过已安装的
            if completedPlugins.contains(plugin.id) {
                continue
            }

            downloadProgress[plugin.id] = 0

            do {
                let result = try await downloader.installPlugin(plugin) { progress in
                    Task { @MainActor in
                        downloadProgress[plugin.id] = progress
                    }
                }

                if result.success {
                    await MainActor.run {
                        completedPlugins.insert(plugin.id)
                        downloadProgress[plugin.id] = 1.0
                    }
                }
            } catch let error as PluginDownloadError {
                await MainActor.run {
                    downloadErrors[plugin.id] = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    downloadErrors[plugin.id] = error.localizedDescription
                }
            }
        }

        await MainActor.run {
            isDownloading = false

            // 如果全部安装成功，自动关闭
            if downloadErrors.isEmpty && !completedPlugins.isEmpty {
                // 延迟一点关闭，让用户看到完成状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onboardingManager.markOnboardingComplete()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
}
