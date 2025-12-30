//
//  PluginManagerView.swift
//  ETerm
//
//  插件管理视图 - 支持热插拔

import SwiftUI
import Combine

struct PluginManagerView: View {
    @ObservedObject private var pluginManager = PluginManager.shared

    private var plugins: [PluginInfo] {
        let frameworkPlugins = pluginManager.allPluginInfos()
        let bundlePlugins = PluginLoader.shared.allPluginInfos()
        let sdkPlugins = SDKPluginLoader.shared.allPluginInfos()
        return frameworkPlugins + bundlePlugins + sdkPlugins
    }

    private var enabledCount: Int {
        plugins.filter { $0.isEnabled }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("插件管理")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(enabledCount)/\(plugins.count) 已启用")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // 插件列表
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if plugins.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("暂无插件")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("插件可以扩展 ETerm 的功能")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(plugins) { plugin in
                            PluginItemView(plugin: plugin)
                        }
                    }
                }
                .padding()
            }
        }
    }
}

/// 插件项视图
struct PluginItemView: View {
    let plugin: PluginInfo
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var isToggling = false

    var body: some View {
        HStack(spacing: 16) {
            // 插件图标
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 24))
                .foregroundColor(plugin.isEnabled ? .accentColor : .secondary)
                .frame(width: 40, height: 40)
                .background(
                    (plugin.isEnabled ? Color.accentColor : Color.secondary)
                        .opacity(0.1)
                )
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plugin.name)
                        .font(.headline)
                        .foregroundColor(plugin.isEnabled ? .primary : .secondary)

                    // 依赖标签
                    if !plugin.dependencies.isEmpty {
                        Text("依赖: \(plugin.dependencies.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 12) {
                    Text("v\(plugin.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(plugin.id)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // 被依赖提示
                    if !plugin.dependents.isEmpty {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(plugin.dependents.count) 个插件依赖")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }

            Spacer()

            // 状态 + 开关
            HStack(spacing: 12) {
                // 状态指示
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 开关
                Toggle("", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { newValue in
                        togglePlugin(enabled: newValue)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isToggling)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .opacity(plugin.isEnabled ? 1.0 : 0.7)
    }

    private var statusColor: Color {
        if plugin.isLoaded {
            return .green
        } else if plugin.isEnabled {
            return .orange  // 启用但未加载（依赖问题）
        } else {
            return .gray
        }
    }

    private var statusText: String {
        if plugin.isLoaded {
            return "运行中"
        } else if plugin.isEnabled {
            return "等待依赖"
        } else {
            return "已禁用"
        }
    }

    private func togglePlugin(enabled: Bool) {
        isToggling = true

        // 判断插件类型并调用对应的管理器
        let pluginId = plugin.id

        Task { @MainActor in
            if enabled {
                // 尝试启用插件
                _ = await enablePluginByType(pluginId)
            } else {
                // 尝试禁用插件
                _ = disablePluginByType(pluginId)
            }

            // 延迟一点触发刷新，让 Toggle 动画完成
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

            // 使用动画触发 UI 刷新
            withAnimation(.easeInOut(duration: 0.2)) {
                pluginManager.objectWillChange.send()
            }
            isToggling = false
        }
    }

    /// 根据插件类型启用插件
    @MainActor
    private func enablePluginByType(_ pluginId: String) async -> Bool {
        // 1. 检查是否是内置插件
        if pluginManager.allPluginInfos().contains(where: { $0.id == pluginId }) {
            return pluginManager.enablePlugin(pluginId)
        }

        // 2. 检查是否是 SDK 插件
        if SDKPluginLoader.shared.allPluginInfos().contains(where: { $0.id == pluginId }) {
            return await SDKPluginLoader.shared.enablePlugin(pluginId)
        }

        // 3. 检查是否是 Bundle 插件
        if PluginLoader.shared.allPluginInfos().contains(where: { $0.id == pluginId }) {
            return PluginLoader.shared.enablePlugin(pluginId)
        }

        return false
    }

    /// 根据插件类型禁用插件
    @MainActor
    private func disablePluginByType(_ pluginId: String) -> Bool {
        // 1. 检查是否是内置插件
        if pluginManager.allPluginInfos().contains(where: { $0.id == pluginId }) {
            return pluginManager.disablePlugin(pluginId)
        }

        // 2. 检查是否是 SDK 插件
        if SDKPluginLoader.shared.allPluginInfos().contains(where: { $0.id == pluginId }) {
            return SDKPluginLoader.shared.disablePlugin(pluginId)
        }

        // 3. 检查是否是 Bundle 插件
        if PluginLoader.shared.allPluginInfos().contains(where: { $0.id == pluginId }) {
            return PluginLoader.shared.disablePlugin(pluginId)
        }

        return false
    }
}

// MARK: - Plugin 扩展

extension Plugin {
    var id: String {
        type(of: self).id
    }
}

#Preview {
    PluginManagerView()
        .frame(width: 600, height: 500)
}
