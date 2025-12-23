//
//  ServerListView.swift
//  ETerm
//
//  MCP Router 服务器列表视图
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

/// 服务器列表视图
struct MCPServerListView: View {
    @ObservedObject var viewModel: MCPServerListViewModel

    @State private var selectedServer: MCPServerConfig?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var showingImportSheet = false
    @State private var serverToDelete: MCPServerConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("MCP 服务器")
                    .font(.headline)

                Spacer()

                Text("\(viewModel.enabledCount)/\(viewModel.servers.count) 已启用")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // 导入按钮
                Button(action: { showingImportSheet = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("导入配置")

                // 导出按钮
                Button(action: exportToJSON) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("导出配置")
                .disabled(viewModel.servers.isEmpty)

                // 添加按钮
                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加服务器")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.servers.isEmpty {
                emptyStateView
            } else {
                serverListView
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MCPServerEditView(mode: .add) { config in
                viewModel.addServer(config)
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            MCPJSONImportView(bridge: viewModel.bridge) {
                viewModel.refresh()
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            if let server = selectedServer {
                MCPServerEditView(mode: .edit(server)) { config in
                    viewModel.updateServer(config)
                }
            }
        }
        .alert("删除服务器", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let server = serverToDelete {
                    viewModel.removeServer(server.name)
                }
            }
        } message: {
            if let server = serverToDelete {
                Text("确定要删除服务器「\(server.name)」吗？此操作不可撤销。")
            }
        }
    }

    // MARK: - Views

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))

            Text("暂无服务器")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("添加服务器") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var serverListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.servers) { server in
                    ServerRowView(
                        server: server,
                        onToggle: { enabled in
                            viewModel.setServerEnabled(server.name, enabled: enabled)
                        },
                        onFlattenToggle: { flatten in
                            viewModel.setServerFlattenMode(server.name, flatten: flatten)
                        },
                        onEdit: {
                            selectedServer = server
                            showingEditSheet = true
                        },
                        onDelete: {
                            serverToDelete = server
                            showingDeleteAlert = true
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func exportToJSON() {
        // 转换为 Claude Code .mcp.json 格式
        var mcpServers: [String: [String: Any]] = [:]

        for server in viewModel.servers {
            var config: [String: Any] = [
                "type": server.serverType.rawValue
            ]

            if server.serverType == .http {
                if let url = server.url {
                    config["url"] = url
                }
                if let headers = server.headers, !headers.isEmpty {
                    config["headers"] = headers
                }
            } else if server.serverType == .stdio {
                if let command = server.command {
                    config["command"] = command
                }
                if let args = server.args, !args.isEmpty {
                    config["args"] = args
                }
                if let env = server.env, !env.isEmpty {
                    config["env"] = env
                }
            }

            mcpServers[server.name] = config
        }

        let jsonObject = ["mcpServers": mcpServers]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        // 保存到文件
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ".mcp.json"
        panel.allowedContentTypes = [.json]

        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? jsonString.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Server Row

private struct ServerRowView: View {
    let server: MCPServerConfig
    let onToggle: (Bool) -> Void
    let onFlattenToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // 启用开关
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)

                // 类型图标
                Image(systemName: server.serverType == .http ? "globe" : "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(server.enabled ? .blue : .secondary)
                    .frame(width: 20)

                // 服务器信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(server.enabled ? .primary : .secondary)

                    Text(serverSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // 操作按钮
                if isHovered {
                    HStack(spacing: 8) {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("编辑")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("删除")
                    }
                }
            }

            // 平铺模式控制 - 仅当服务器启用时显示
            if server.enabled {
                HStack {
                    Label("平铺模式", systemImage: "square.grid.2x2")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { server.flattenMode },
                        set: { onFlattenToggle($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(4)
                .help("启用后，该 Server 的工具将直接暴露给 AI，减少调用步骤")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("编辑", action: onEdit)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private var serverSubtitle: String {
        switch server.serverType {
        case .http:
            return server.url ?? ""
        case .stdio:
            return server.command ?? ""
        }
    }
}

// MARK: - ViewModel

final class MCPServerListViewModel: ObservableObject {
    @Published private(set) var servers: [MCPServerConfig] = []

    private(set) weak var bridge: MCPRouterBridge?

    var enabledCount: Int {
        servers.filter { $0.enabled }.count
    }

    init(bridge: MCPRouterBridge?) {
        self.bridge = bridge
        refresh()
    }

    func refresh() {
        do {
            servers = try bridge?.listServers() ?? []
        } catch {
            logWarn("[MCPRouter] Failed to list servers: \(error)")
        }
    }

    func addServer(_ config: MCPServerConfig) {
        do {
            try bridge?.addServer(config)
            refresh()
            MCPRouterPlugin.shared?.saveServerConfigs()
        } catch {
            logWarn("[MCPRouter] Failed to add server: \(error)")
        }
    }

    func updateServer(_ config: MCPServerConfig) {
        do {
            try bridge?.removeServer(name: config.name)
            try bridge?.addServer(config)
            refresh()
            MCPRouterPlugin.shared?.saveServerConfigs()
        } catch {
            logWarn("[MCPRouter] Failed to update server: \(error)")
        }
    }

    func removeServer(_ name: String) {
        do {
            try bridge?.removeServer(name: name)
            refresh()
            MCPRouterPlugin.shared?.saveServerConfigs()
        } catch {
            logWarn("[MCPRouter] Failed to remove server: \(error)")
        }
    }

    func setServerEnabled(_ name: String, enabled: Bool) {
        do {
            try bridge?.setServerEnabled(name: name, enabled: enabled)
            refresh()
            MCPRouterPlugin.shared?.saveServerConfigs()
        } catch {
            logWarn("[MCPRouter] Failed to set server enabled: \(error)")
        }
    }

    func setServerFlattenMode(_ name: String, flatten: Bool) {
        do {
            try bridge?.setServerFlattenMode(name: name, flatten: flatten)
            refresh()
            MCPRouterPlugin.shared?.saveServerConfigs()
        } catch {
            logWarn("[MCPRouter] Failed to set server flatten mode: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    MCPServerListView(viewModel: MCPServerListViewModel(bridge: nil))
        .frame(width: 350, height: 400)
}
