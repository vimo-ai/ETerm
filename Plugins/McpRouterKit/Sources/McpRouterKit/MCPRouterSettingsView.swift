//
//  MCPRouterSettingsView.swift
//  ETerm
//
//  MCP Router 设置视图
//

import SwiftUI

/// MCP Router 设置主视图
struct MCPRouterSettingsView: View {
    @ObservedObject private var plugin: MCPRouterPlugin
    @StateObject private var serverListVM: MCPServerListViewModel

    @State private var selectedTab = 0

    init() {
        if let shared = MCPRouterPlugin.shared {
            self.plugin = shared
            _serverListVM = StateObject(wrappedValue: MCPServerListViewModel(bridge: shared.routerBridge))
        } else {
            let plugin = MCPRouterPlugin()
            self.plugin = plugin
            _serverListVM = StateObject(wrappedValue: MCPServerListViewModel(bridge: plugin.routerBridge))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标签栏
            HStack(spacing: 0) {
                TabButton(title: "基本", icon: "gear", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                TabButton(title: "服务器", icon: "server.rack", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                TabButton(title: "工作区", icon: "folder.badge.gearshape", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
                TabButton(title: "集成", icon: "link", isSelected: selectedTab == 3) {
                    selectedTab = 3
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // 内容区
            Group {
                switch selectedTab {
                case 0:
                    BasicSettingsView(plugin: plugin)
                case 1:
                    MCPServerListView(viewModel: serverListVM)
                case 2:
                    MCPWorkspaceConfigView()
                case 3:
                    GlobalConfigView()
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Basic Settings

private struct BasicSettingsView: View {
    @ObservedObject var plugin: MCPRouterPlugin

    @State private var portText: String = ""
    @State private var showCopiedToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 状态显示
            HStack {
                Circle()
                    .fill(plugin.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(plugin.statusMessage)
                    .font(.subheadline)
                Spacer()
                Text("v\(plugin.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // 端点 URL
            VStack(alignment: .leading, spacing: 6) {
                Text("端点地址")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text(plugin.endpointURL)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(plugin.isRunning ? .primary : .secondary)
                        .textSelection(.enabled)

                    Spacer()

                    Button(action: copyEndpointURL) {
                        Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                            .foregroundColor(showCopiedToast ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("复制到剪贴板")
                }
            }

            // 端口配置
            VStack(alignment: .leading, spacing: 6) {
                Text("端口")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("19104", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onAppear {
                            portText = String(plugin.currentPort)
                        }

                    Button("应用") {
                        applyPort()
                    }
                    .disabled(portText == String(plugin.currentPort))

                    Spacer()
                }
            }

            // 自动启动
            Toggle(isOn: Binding(
                get: { plugin.autoStart },
                set: { plugin.updateAutoStart($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("随 ETerm 启动")
                        .font(.body)
                    Text("启动 ETerm 时自动运行 MCP Router")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Full 模式
            Toggle(isOn: Binding(
                get: { plugin.fullMode },
                set: { plugin.updateFullMode($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Full 模式")
                            .font(.body)
                        Text(plugin.fullMode ? "Full" : "Light")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(plugin.fullMode ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.2))
                            .foregroundColor(plugin.fullMode ? .orange : .secondary)
                            .cornerRadius(4)
                    }
                    Text(plugin.fullMode
                         ? "AI 可使用 add_server、remove_server、update_server 管理 MCP 服务器"
                         : "AI 只能使用基本工具：list、describe、call")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // 控制按钮
            HStack(spacing: 12) {
                if plugin.isRunning {
                    Button(action: { plugin.stop() }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("停止")
                        }
                    }
                    .foregroundColor(.red)

                    Button(action: { plugin.restart() }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("重启")
                        }
                    }
                } else {
                    Button(action: { plugin.start() }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("启动")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }

            Spacer()

            // 使用说明
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP Router")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("MCP Router 是一个多服务器 MCP 代理，可以将多个 MCP 服务聚合到一个端点。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("配置 Claude Desktop 使用上面的端点地址即可访问所有已配置的 MCP 服务。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func copyEndpointURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plugin.endpointURL, forType: .string)

        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedToast = false
        }
    }

    private func applyPort() {
        guard let port = UInt16(portText), port > 0 else {
            portText = String(plugin.currentPort)
            return
        }
        plugin.setPort(port)
    }
}

#Preview {
    MCPRouterSettingsView()
        .frame(width: 450, height: 400)
}
