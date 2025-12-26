//
//  SDKPluginPlaceholderView.swift
//  ETerm
//
//  SDK 插件占位视图 - 当 ViewProvider 未加载时显示

import SwiftUI

/// SDK 插件占位视图
///
/// 当插件没有提供 ViewProvider 或 ViewProvider 加载失败时显示
struct SDKPluginPlaceholderView: View {
    let pluginId: String
    let tabId: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(message)
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Plugin: \(pluginId)")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Tab: \(tabId)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    SDKPluginPlaceholderView(
        pluginId: "com.example.plugin",
        tabId: "settings",
        message: "ViewProvider not loaded"
    )
}
