//
//  SDKPluginSidebarView.swift
//  ETerm
//
//  MCP Router 设置视图 - 通过 IPC 与 Extension Host 通信
//

import SwiftUI
import Combine
import AppKit

// MARK: - Main Settings View

/// MCP Router 设置主视图
struct SDKPluginSidebarView: View {
    let pluginId: String
    let tabId: String
    let title: String

    @StateObject private var viewModel = MCPRouterViewModel()
    @State private var selectedTab = 0

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
                    BasicSettingsView(viewModel: viewModel, pluginId: pluginId)
                case 1:
                    MCPServerListView()
                case 2:
                    MCPWorkspaceConfigView()
                case 3:
                    IntegrationView(viewModel: viewModel)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 400)
        .onAppear {
            viewModel.startListening(for: pluginId)
        }
        .onDisappear {
            viewModel.stopListening()
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

// MARK: - Basic Settings Tab

private struct BasicSettingsView: View {
    @ObservedObject var viewModel: MCPRouterViewModel
    let pluginId: String

    @State private var portText = ""
    @State private var showCopiedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 状态显示
                HStack {
                    Circle()
                        .fill(viewModel.isRunning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                    Spacer()
                    Text("v\(viewModel.version)")
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
                        Text(viewModel.endpointURL)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(viewModel.isRunning ? .primary : .secondary)
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
                                portText = String(viewModel.port)
                            }
                            .onChange(of: viewModel.port) { _, newValue in
                                portText = String(newValue)
                            }

                        Button("应用") {
                            applyPort()
                        }
                        .disabled(portText == String(viewModel.port))

                        Spacer()
                    }
                }

                // Full 模式
                Toggle(isOn: Binding(
                    get: { viewModel.fullMode },
                    set: { setFullMode($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Full 模式")
                                .font(.body)
                            Text(viewModel.fullMode ? "Full" : "Light")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(viewModel.fullMode ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.2))
                                .foregroundColor(viewModel.fullMode ? .orange : .secondary)
                                .cornerRadius(4)
                        }
                        Text(viewModel.fullMode
                             ? "AI 可使用管理工具管理 MCP 服务器"
                             : "AI 只能使用基本工具")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // 控制按钮
                HStack(spacing: 12) {
                    if viewModel.isRunning {
                        Button(action: { sendCommand("stop") }) {
                            HStack {
                                Image(systemName: "stop.fill")
                                Text("停止")
                            }
                        }
                        .foregroundColor(.red)

                        Button(action: { sendCommand("reload") }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("重启")
                            }
                        }
                    } else {
                        Button(action: { sendCommand("start") }) {
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
                }
            }
            .padding()
        }
    }

    private func copyEndpointURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.endpointURL, forType: .string)

        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedToast = false
        }
    }

    private func applyPort() {
        guard let port = Int(portText), port > 0, port < 65536 else {
            portText = String(viewModel.port)
            return
        }
        Task {
            try? await MCPRouterIPCClient.shared.setPort(port)
        }
    }

    private func setFullMode(_ fullMode: Bool) {
        Task {
            try? await MCPRouterIPCClient.shared.setFullMode(fullMode)
        }
    }

    private func sendCommand(_ command: String) {
        Task {
            switch command {
            case "start":
                try? await MCPRouterIPCClient.shared.start()
            case "stop":
                try? await MCPRouterIPCClient.shared.stop()
            case "reload":
                try? await MCPRouterIPCClient.shared.reload()
            default:
                break
            }
        }
    }
}

// MARK: - Integration Tab

private struct IntegrationView: View {
    @ObservedObject var viewModel: MCPRouterViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("全局配置集成")
                    .font(.headline)

                Text("将 MCP Router 安装到 Claude CLI 或 Codex 的全局配置中。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // Claude CLI
                IntegrationRowView(
                    name: "Claude CLI",
                    icon: "terminal",
                    configPath: "~/.claude.json",
                    description: "Claude Code CLI 全局配置",
                    port: viewModel.port
                )

                // Codex
                IntegrationRowView(
                    name: "Codex",
                    icon: "chevron.left.forwardslash.chevron.right",
                    configPath: "~/.codex/config.json",
                    description: "Codex CLI 全局配置",
                    port: viewModel.port
                )

                Spacer()
            }
            .padding()
        }
    }
}

private struct IntegrationRowView: View {
    let name: String
    let icon: String
    let configPath: String
    let description: String
    let port: Int

    @State private var isInstalled = false
    @State private var configExists = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)

                Text(name)
                    .font(.headline)

                if isInstalled {
                    Text("已安装")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .cornerRadius(4)
                }

                Spacer()

                if configExists {
                    if isInstalled {
                        Button("卸载") {
                            toggleInstall()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("安装") {
                            toggleInstall()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("配置文件不存在")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(configPath)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            checkStatus()
        }
    }

    private func checkStatus() {
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        configExists = FileManager.default.fileExists(atPath: expandedPath)

        if configExists {
            if let data = FileManager.default.contents(atPath: expandedPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mcpServers = json["mcpServers"] as? [String: Any] {
                isInstalled = mcpServers["mcp-router"] != nil
            }
        }
    }

    private func toggleInstall() {
        let expandedPath = NSString(string: configPath).expandingTildeInPath

        guard let data = FileManager.default.contents(atPath: expandedPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var mcpServers = json["mcpServers"] as? [String: Any] ?? [:]

        if isInstalled {
            mcpServers.removeValue(forKey: "mcp-router")
        } else {
            mcpServers["mcp-router"] = [
                "type": "http",
                "url": "http://127.0.0.1:\(port)"
            ]
        }

        json["mcpServers"] = mcpServers

        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: URL(fileURLWithPath: expandedPath))
            isInstalled.toggle()
        }
    }
}

// MARK: - ViewModel

/// MCP Router ViewModel
final class MCPRouterViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var port: Int = 19104
    @Published var statusMessage = "Not running"
    @Published var version = ""
    @Published var fullMode = false

    var endpointURL: String {
        "http://127.0.0.1:\(port)"
    }

    private var pluginId: String?
    private var cancellable: AnyCancellable?

    func startListening(for pluginId: String) {
        self.pluginId = pluginId

        // 先从缓存获取初始状态
        Task {
            if let cached = await ExtensionHostManager.shared.getCachedViewModel(for: pluginId) {
                await MainActor.run {
                    self.applyData(cached)
                }
            }
        }

        // 订阅后续更新
        cancellable = NotificationCenter.default.publisher(
            for: NSNotification.Name("ETerm.UpdateViewModel")
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleUpdate(notification)
        }
    }

    func stopListening() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func handleUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let notificationPluginId = userInfo["pluginId"] as? String,
              notificationPluginId == pluginId,
              let data = userInfo["data"] as? [String: Any] else {
            return
        }
        applyData(data)
    }

    private func applyData(_ data: [String: Any]) {
        if let isRunning = data["isRunning"] as? Bool {
            self.isRunning = isRunning
        }

        if let port = data["port"] as? Int {
            self.port = port
        }

        if let statusMessage = data["statusMessage"] as? String {
            self.statusMessage = statusMessage
        }

        if let version = data["version"] as? String {
            self.version = version
        }

        if let fullMode = data["exposeManagementTools"] as? Bool {
            self.fullMode = fullMode
        }
    }
}

// MARK: - Preview

#Preview {
    SDKPluginSidebarView(
        pluginId: "com.eterm.mcp-router",
        tabId: "mcp-router-settings",
        title: "MCP Router"
    )
}
