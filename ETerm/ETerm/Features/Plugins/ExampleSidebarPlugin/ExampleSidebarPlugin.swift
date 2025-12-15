//
//  ExampleSidebarPlugin.swift
//  ETerm
//
//  示例插件 - 演示如何注册侧边栏 Tab

import SwiftUI

/// 示例插件 - 注册侧边栏 Tab
final class ExampleSidebarPlugin: Plugin {
    static let id = "example-sidebar"
    static let name = "示例侧边栏插件"
    static let version = "1.0.0"

    func activate(context: PluginContext) {

        // 注册第一个 Tab
        let tab1 = SidebarTab(
            id: "example-tab-1",
            title: "示例功能 1",
            icon: "star.fill"
        ) {
            AnyView(ExampleView1())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: tab1)

        // 注册第二个 Tab
        let tab2 = SidebarTab(
            id: "example-tab-2",
            title: "示例功能 2",
            icon: "heart.fill"
        ) {
            AnyView(ExampleView2())
        }
        context.ui.registerSidebarTab(for: Self.id, pluginName: Self.name, tab: tab2)

    }

    func deactivate() {
    }
}

// MARK: - 示例视图

struct ExampleView1: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "star.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)

            Text("示例功能 1")
                .font(.title)
                .fontWeight(.bold)

            Text("这是一个由插件注册的侧边栏 Tab")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.vertical)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "checkmark.circle.fill", text: "支持自定义图标")
                FeatureRow(icon: "checkmark.circle.fill", text: "支持自定义标题")
                FeatureRow(icon: "checkmark.circle.fill", text: "支持任意 SwiftUI 视图")
            }
        }
        .padding(40)
    }
}

struct ExampleView2: View {
    @State private var counter = 0

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("示例功能 2")
                .font(.title)
                .fontWeight(.bold)

            Text("插件可以包含交互功能")
                .foregroundColor(.secondary)

            Divider()
                .padding(.vertical)

            Text("计数器: \(counter)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.accentColor)

            HStack(spacing: 16) {
                Button(action: { counter -= 1 }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 32))
                }
                .buttonStyle(.plain)

                Button(action: { counter += 1 }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 32))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.green)
            Text(text)
                .foregroundColor(.primary)
        }
    }
}
