//
//  WorkspaceConfigView.swift
//  ETerm
//
//  MCP Router Workspace 管理视图 - 基于 WorkspacePlugin 的项目列表
//

import SwiftUI

/// Workspace 管理主视图
struct MCPWorkspaceConfigView: View {
    @ObservedObject var workspaceManager = MCPWorkspaceManager.shared

    @State private var selectedWorkspace: MCPWorkspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("工作区")
                    .font(.headline)

                Spacer()

                Button(action: { workspaceManager.syncWithWorkspacePlugin() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("同步工作区列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if workspaceManager.workspaces.isEmpty {
                emptyStateView
            } else {
                workspaceListView
            }
        }
        .sheet(item: $selectedWorkspace) { workspace in
            MCPWorkspaceDetailView(workspace: workspace)
        }
    }

    // MARK: - Views

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))

            Text("暂无工作区")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("在「工作区」插件中添加项目文件夹")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var workspaceListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(workspaceManager.workspaces) { workspace in
                    WorkspaceRowView(
                        workspace: workspace,
                        isDefault: workspace.isDefault,
                        onTap: {
                            selectedWorkspace = workspace
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Workspace Row

private struct WorkspaceRowView: View {
    let workspace: MCPWorkspace
    let isDefault: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var showCopiedToast = false

    var body: some View {
        HStack(spacing: 10) {
            // 图标
            Image(systemName: isDefault ? "star.fill" : "folder.fill")
                .font(.system(size: 14))
                .foregroundColor(isDefault ? .yellow : .blue)
                .frame(width: 20)

            // 信息
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))

                if isDefault {
                    Text("默认配置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(workspace.projectPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Token
            HStack(spacing: 4) {
                Text(workspace.token)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.blue)

                Button(action: copyToken) {
                    Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(showCopiedToast ? .green : .secondary)
                }
                .buttonStyle(.borderless)
            }

            // 自定义标记
            if !workspace.serverOverrides.isEmpty || !workspace.flattenOverrides.isEmpty {
                Text("\(workspace.serverOverrides.count + workspace.flattenOverrides.count) 项自定义")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
            }

            // 箭头
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : (isDefault ? Color.yellow.opacity(0.05) : Color.clear))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(workspace.token, forType: .string)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedToast = false
        }
    }
}

// MARK: - Workspace Detail View

struct MCPWorkspaceDetailView: View {
    let workspace: MCPWorkspace

    @ObservedObject var workspaceManager = MCPWorkspaceManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var servers: [MCPServerConfig] = []

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text(workspace.name)
                    .font(.headline)

                Spacer()

                if !workspace.isDefault && (!workspace.serverOverrides.isEmpty || !workspace.flattenOverrides.isEmpty) {
                    Button("重置") {
                        workspaceManager.resetOverrides(for: workspace.token)
                    }
                    .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Token 信息
            tokenSection

            Divider()

            // Server 配置列表
            serverListSection
        }
        .frame(minWidth: 450, minHeight: 400)
        .onAppear {
            loadServers()
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text(workspace.token)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)

                Button(action: copyToken) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if !workspace.projectPath.isEmpty {
                HStack {
                    Text("项目路径")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(workspace.projectPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Text("此 Token 用于 .mcp.json 中的 X-Workspace-Token Header")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private var serverListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Server 配置")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if workspace.isDefault {
                    Text("默认配置将被其他工作区继承")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if servers.isEmpty {
                VStack {
                    Text("暂无服务器")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(servers) { server in
                            ServerToggleCardView(
                                server: server,
                                workspace: workspace,
                                defaultWorkspace: workspaceManager.defaultWorkspace,
                                onToggle: { enabled in
                                    workspaceManager.setServerEnabled(for: workspace.token, serverName: server.name, enabled: enabled)
                                },
                                onFlattenToggle: { flatten in
                                    workspaceManager.setFlattenMode(for: workspace.token, serverName: server.name, flatten: flatten)
                                }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func loadServers() {
        if let bridge = MCPRouterPlugin.shared?.routerBridge {
            do {
                servers = try bridge.listServers()
            } catch {
                logWarn("[MCPWorkspace] Failed to list servers: \(error)")
            }
        }
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(workspace.token, forType: .string)
    }
}

// MARK: - Server Toggle Card

private struct ServerToggleCardView: View {
    let server: MCPServerConfig
    let workspace: MCPWorkspace
    let defaultWorkspace: MCPWorkspace?
    let onToggle: (Bool) -> Void
    let onFlattenToggle: (Bool) -> Void

    private var isEnabled: Bool {
        workspace.isServerEnabled(server.name, serverConfig: server, defaultWorkspace: defaultWorkspace)
    }

    private var isCustomized: Bool {
        workspace.isServerCustomized(server.name)
    }

    private var isFlattenEnabled: Bool {
        workspace.isFlattenEnabled(server.name, serverConfig: server, defaultWorkspace: defaultWorkspace)
    }

    private var isFlattenCustomized: Bool {
        workspace.isFlattenCustomized(server.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                // 类型图标
                Image(systemName: server.serverType == .http ? "globe" : "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(isEnabled ? .blue : .secondary)

                Text(server.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEnabled ? .primary : .secondary)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // URL/Command
            if let url = server.url {
                Text(url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let command = server.command {
                Text(command)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // 平铺模式
            if isEnabled {
                HStack {
                    Label("平铺模式", systemImage: "square.grid.2x2")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { isFlattenEnabled },
                        set: { onFlattenToggle($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(isFlattenCustomized ? Color.orange.opacity(0.1) : Color.primary.opacity(0.03))
                .cornerRadius(4)
            }

            // 全局禁用提示
            if !server.enabled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Server Pool 中已禁用")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCustomized ? Color.blue : Color.clear, lineWidth: 1.5)
        )
        .opacity(isEnabled ? 1.0 : 0.6)
    }
}

// MARK: - Preview

#Preview {
    MCPWorkspaceConfigView()
        .frame(width: 400, height: 500)
}
