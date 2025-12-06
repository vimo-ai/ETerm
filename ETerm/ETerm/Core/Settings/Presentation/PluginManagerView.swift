//
//  PluginManagerView.swift
//  ETerm
//
//  插件管理视图

import SwiftUI

struct PluginManagerView: View {
    // 获取已加载的插件
    private var loadedPlugins: [Plugin] {
        PluginManager.shared.loadedPlugins()
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("插件管理")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(loadedPlugins.count) 个插件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // 插件列表
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loadedPlugins.isEmpty {
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
                        ForEach(loadedPlugins, id: \.id) { plugin in
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
    let plugin: Plugin

    var body: some View {
        HStack(spacing: 16) {
            // 插件图标
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(type(of: plugin).name)
                    .font(.headline)
                HStack(spacing: 12) {
                    Text("v\(type(of: plugin).version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(type(of: plugin).id)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 状态标识
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("已激活")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
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
