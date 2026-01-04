//
//  MCPRouterSettingsView.swift
//  MCPRouterKit
//
//  MCP Router 设置视图 - 4 个分栏（基本、服务器、工作区、集成）

import Foundation
import SwiftUI
import ETermKit
import UniformTypeIdentifiers
import AppKit

// MARK: - ViewModel

/// MCP Router View 状态 - 直接调用 Bridge
@MainActor
final class MCPRouterViewState: ObservableObject {
    @Published var isRunning = false
    @Published var port: Int = 19104
    @Published var statusMessage = "未运行"
    @Published var version = ""
    @Published var fullMode = false
    @Published var servers: [MCPServerConfigDTO] = []
    @Published var workspaces: [MCPWorkspaceDTO] = []

    private let bridge = MCPRouterBridge.shared
    private var workspaceObserver: NSObjectProtocol?

    var endpointURL: String {
        "http://127.0.0.1:\(port)"
    }

    var enabledCount: Int {
        servers.filter { $0.enabled }.count
    }

    var defaultWorkspace: MCPWorkspaceDTO? {
        workspaces.first { $0.isDefault }
    }

    init() {
        version = MCPRouterBridge.version
        setupWorkspaceObserver()
        // 从缓存加载已有的工作区数据
        loadCachedWorkspaces()
    }

    private func loadCachedWorkspaces() {
        let cached = WorkspaceCache.shared.workspaces
        if !cached.isEmpty {
            updateWorkspaces(from: cached)
        }
    }

    deinit {
        if let observer = workspaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: .mcpRouterWorkspacesUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let rawWorkspaces = notification.userInfo?["workspaces"] as? [[String: Any]] else {
                return
            }

            Task { @MainActor in
                self.updateWorkspaces(from: rawWorkspaces)
            }
        }
    }

    /// 从 WorkspaceKit 的路径列表更新工作区
    private func updateWorkspaces(from rawWorkspaces: [[String: Any]]) {
        // 将简单的路径列表转换为 MCPWorkspaceDTO
        // 保留现有的配置（serverOverrides 等）
        let newWorkspaces = rawWorkspaces.compactMap { raw -> MCPWorkspaceDTO? in
            guard let path = raw["path"] as? String else { return nil }
            let name = raw["name"] as? String ?? (path as NSString).lastPathComponent

            // 查找现有工作区的配置
            if let existing = workspaces.first(where: { $0.projectPath == path }) {
                return existing
            }

            // 创建新工作区（使用路径作为 token）
            return MCPWorkspaceDTO(
                token: path,
                name: name,
                projectPath: path
            )
        }

        workspaces = newWorkspaces

        // 同步到 Bridge
        do {
            try bridge.loadWorkspaces(workspaces)
        } catch {
            logError("[MCPRouter] loadWorkspaces error: \(error)")
        }
    }

    func refresh() {
        do {
            servers = try bridge.listServers()
            if let status = bridge.getStatus() {
                isRunning = status.isRunning
                statusMessage = isRunning ? "运行中 (端口 \(port))" : "未运行"
            }
            fullMode = bridge.getExposeManagementTools()
        } catch {
            logError("[MCPRouter] refresh error: \(error)")
        }
    }

    func start() {
        do {
            try bridge.startServer(port: UInt16(port))
            isRunning = true
            statusMessage = "运行中 (端口 \(port))"
        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
        }
    }

    func stop() {
        do {
            try bridge.stopServer()
            isRunning = false
            statusMessage = "未运行"
        } catch {
            statusMessage = "停止失败: \(error.localizedDescription)"
        }
    }

    func reload() {
        stop()
        start()
        refresh()
    }

    func setPort(_ newPort: Int) {
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }
        port = newPort
        if wasRunning {
            start()
        }
    }

    func addServer(_ config: MCPServerConfigDTO) {
        do {
            // 获取现有服务器列表，追加新服务器，然后批量加载
            var currentServers = try bridge.listServers()
            // 检查是否已存在同名服务器
            if !currentServers.contains(where: { $0.name == config.name }) {
                currentServers.append(config)
                try bridge.loadServers(currentServers)
            }
            refresh()
        } catch {
            logError("[MCPRouter] addServer error: \(error)")
        }
    }

    func removeServer(_ name: String) {
        do {
            try bridge.removeServer(name: name)
            refresh()
        } catch {
            logError("[MCPRouter] removeServer error: \(error)")
        }
    }

    func setServerEnabled(_ name: String, enabled: Bool) {
        do {
            try bridge.setServerEnabled(name: name, enabled: enabled)
            refresh()
        } catch {
            logError("[MCPRouter] setServerEnabled error: \(error)")
        }
    }

    func setServerFlattenMode(_ name: String, flatten: Bool) {
        do {
            try bridge.setServerFlattenMode(name: name, flatten: flatten)
            refresh()
        } catch {
            logError("[MCPRouter] setServerFlattenMode error: \(error)")
        }
    }

    func setExposeManagementTools(_ expose: Bool) {
        do {
            try bridge.setExposeManagementTools(expose)
            fullMode = expose
        } catch {
            logError("[MCPRouter] setExposeManagementTools error: \(error)")
        }
    }
}

// MARK: - Main Settings View

struct MCPRouterSettingsView: View {
    @StateObject private var viewModel = MCPRouterViewState()
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

            Group {
                switch selectedTab {
                case 0:
                    BasicSettingsTab(viewModel: viewModel)
                case 1:
                    MCPServerListView(viewModel: viewModel)
                case 2:
                    MCPWorkspaceConfigView(viewModel: viewModel)
                case 3:
                    IntegrationTab(viewModel: viewModel)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            viewModel.refresh()
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

private struct BasicSettingsTab: View {
    @ObservedObject var viewModel: MCPRouterViewState
    @State private var portText = ""

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

                // 控制按钮
                HStack(spacing: 12) {
                    if viewModel.isRunning {
                        Button(action: {
                            viewModel.stop()
                        }) {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button(action: {
                            viewModel.reload()
                        }) {
                            Label("重载", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            viewModel.start()
                        }) {
                            Label("启动", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
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
                            .textSelection(.enabled)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viewModel.endpointURL, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
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

                        Button("应用") {
                            if let port = Int(portText) {
                                viewModel.setPort(port)
                            }
                        }
                        .disabled(Int(portText) == viewModel.port)
                    }
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
}

// MARK: - Server List View

private struct MCPServerListView: View {
    @ObservedObject var viewModel: MCPRouterViewState

    @State private var selectedServer: MCPServerConfigDTO?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var showingImportSheet = false
    @State private var serverToDelete: MCPServerConfigDTO?

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

                Button(action: { showingImportSheet = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("导入配置")

                Button(action: { exportToJSON() }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("导出配置")
                .disabled(viewModel.servers.isEmpty)

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
            MCPJSONImportView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingEditSheet) {
            if let server = selectedServer {
                MCPServerEditView(mode: .edit(server)) { config in
                    viewModel.removeServer(server.name)
                    viewModel.addServer(config)
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

    private func exportToJSON() {
        var mcpServers: [String: [String: Any]] = [:]

        for server in viewModel.servers {
            var config: [String: Any] = ["type": server.serverType]

            if server.serverType == "http" {
                if let url = server.url { config["url"] = url }
                if let headers = server.headers, !headers.isEmpty { config["headers"] = headers }
            } else {
                if let command = server.command { config["command"] = command }
                if let args = server.args, !args.isEmpty { config["args"] = args }
                if let env = server.env, !env.isEmpty { config["env"] = env }
            }

            mcpServers[server.name] = config
        }

        let jsonObject = ["mcpServers": mcpServers]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

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

// MARK: - Server Row View

private struct ServerRowView: View {
    let server: MCPServerConfigDTO
    let onToggle: (Bool) -> Void
    let onFlattenToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)

                Image(systemName: server.serverType == "http" ? "globe" : "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(server.enabled ? .blue : .secondary)
                    .frame(width: 20)

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
                .help("启用后，该 Server 的工具将直接暴露给 AI")
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
        if server.serverType == "http" {
            return server.url ?? ""
        } else {
            return server.command ?? ""
        }
    }
}

// MARK: - Server Edit View

enum MCPServerEditMode {
    case add
    case edit(MCPServerConfigDTO)

    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}

private struct MCPServerEditView: View {
    let mode: MCPServerEditMode
    let onSave: (MCPServerConfigDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverType: String = "http"
    @State private var serverDescription = ""
    @State private var url = ""
    @State private var headerPairs: [KeyValuePair] = []
    @State private var command = ""
    @State private var argsText = ""
    @State private var envPairs: [KeyValuePair] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode.isAdd ? "添加服务器" : "编辑服务器")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicInfoSection
                    Divider()
                    if serverType == "http" {
                        httpConfigSection
                    } else {
                        stdioConfigSection
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode.isAdd ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .onAppear(perform: loadExistingData)
    }

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基本信息")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LabeledContent("名称") {
                TextField("server-name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!mode.isAdd)
            }

            LabeledContent("类型") {
                Picker("", selection: $serverType) {
                    Text("HTTP").tag("http")
                    Text("Stdio").tag("stdio")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(!mode.isAdd)
            }

            LabeledContent("描述") {
                TextField("可选描述", text: $serverDescription)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var httpConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HTTP 配置")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LabeledContent("URL") {
                TextField("http://localhost:8080", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Headers")
                    Spacer()
                    Button(action: { headerPairs.append(KeyValuePair(key: "", value: "")) }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach($headerPairs) { $pair in
                    HStack(spacing: 8) {
                        TextField("Header-Name", text: $pair.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text(":")
                        TextField("value", text: $pair.value)
                            .textFieldStyle(.roundedBorder)
                        Button(action: { headerPairs.removeAll { $0.id == pair.id } }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var stdioConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stdio 配置")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LabeledContent("命令") {
                TextField("/usr/bin/node", text: $command)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("参数") {
                TextField("index.js --port 8080", text: $argsText)
                    .textFieldStyle(.roundedBorder)
            }

            Text("参数以空格分隔")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("环境变量")
                    Spacer()
                    Button(action: { envPairs.append(KeyValuePair(key: "", value: "")) }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach($envPairs) { $pair in
                    HStack(spacing: 8) {
                        TextField("KEY", text: $pair.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text("=")
                        TextField("value", text: $pair.value)
                            .textFieldStyle(.roundedBorder)
                        Button(action: { envPairs.removeAll { $0.id == pair.id } }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func loadExistingData() {
        guard case .edit(let config) = mode else { return }

        name = config.name
        serverType = config.serverType
        serverDescription = config.description ?? ""

        if config.serverType == "http" {
            url = config.url ?? ""
            headerPairs = config.headers?.map { KeyValuePair(key: $0.key, value: $0.value) } ?? []
        } else {
            command = config.command ?? ""
            argsText = config.args?.joined(separator: " ") ?? ""
            envPairs = config.env?.map { KeyValuePair(key: $0.key, value: $0.value) } ?? []
        }
    }

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if serverType == "http" {
            return !url.isEmpty
        } else {
            return !command.isEmpty
        }
    }

    private func save() {
        let config: MCPServerConfigDTO

        if serverType == "http" {
            let headers = headerPairs.isEmpty ? nil : Dictionary(uniqueKeysWithValues: headerPairs.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
            config = MCPServerConfigDTO(
                name: name,
                serverType: "http",
                description: serverDescription.isEmpty ? nil : serverDescription,
                url: url,
                headers: headers
            )
        } else {
            let args = argsText.isEmpty ? nil : argsText.split(separator: " ").map(String.init)
            let env = envPairs.isEmpty ? nil : Dictionary(uniqueKeysWithValues: envPairs.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
            config = MCPServerConfigDTO(
                name: name,
                serverType: "stdio",
                description: serverDescription.isEmpty ? nil : serverDescription,
                command: command,
                args: args,
                env: env
            )
        }

        onSave(config)
        dismiss()
    }
}

private struct KeyValuePair: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

// MARK: - JSON Import View

private struct MCPJSONImportView: View {
    @ObservedObject var viewModel: MCPRouterViewState
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导入 JSON 配置")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding()

            Divider()

            VStack(spacing: 16) {
                Text("粘贴 JSON 配置或拖拽文件")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $jsonText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                if let errorMessage = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                HStack {
                    Button("选择文件...") { selectFile() }
                    Spacer()
                    Button("导入") { performImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(jsonText.isEmpty)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("支持的格式: Claude Code .mcp.json")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(width: 550, height: 450)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    jsonText = content
                }
            }
        }
    }

    private func performImport() {
        errorMessage = nil

        guard let data = jsonText.data(using: .utf8) else {
            errorMessage = "文本编码无效"
            return
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "JSON 格式无效"
                return
            }

            guard let mcpServers = json["mcpServers"] as? [String: [String: Any]] else {
                errorMessage = "不支持的格式，需要 mcpServers 字段"
                return
            }

            for (name, config) in mcpServers {
                let type = config["type"] as? String ?? (config["command"] != nil ? "stdio" : "http")

                if type == "http" {
                    guard let url = config["url"] as? String else { continue }
                    let headers = config["headers"] as? [String: String]
                    let serverConfig = MCPServerConfigDTO.http(name: name, url: url, headers: headers)
                    viewModel.addServer(serverConfig)
                } else {
                    guard let command = config["command"] as? String else { continue }
                    let args = config["args"] as? [String] ?? []
                    let env = config["env"] as? [String: String] ?? [:]
                    let serverConfig = MCPServerConfigDTO.stdio(name: name, command: command, args: args, env: env)
                    viewModel.addServer(serverConfig)
                }
            }

            dismiss()
        } catch {
            errorMessage = "JSON 解析失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - Workspace Config View

private struct MCPWorkspaceConfigView: View {
    @ObservedObject var viewModel: MCPRouterViewState
    @State private var selectedWorkspace: MCPWorkspaceDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("工作区")
                    .font(.headline)

                Spacer()

                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新工作区列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.workspaces.isEmpty {
                emptyStateView
            } else {
                workspaceListView
            }
        }
        .sheet(item: $selectedWorkspace) { workspace in
            MCPWorkspaceDetailView(
                workspace: workspace,
                servers: viewModel.servers,
                defaultWorkspace: viewModel.defaultWorkspace,
                viewModel: viewModel
            )
        }
    }

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
                ForEach(viewModel.workspaces) { workspace in
                    WorkspaceRowView(
                        workspace: workspace,
                        isDefault: workspace.isDefault,
                        onTap: { selectedWorkspace = workspace }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct WorkspaceRowView: View {
    let workspace: MCPWorkspaceDTO
    let isDefault: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var showCopiedToast = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDefault ? "star.fill" : "folder.fill")
                .font(.system(size: 14))
                .foregroundColor(isDefault ? .yellow : .blue)
                .frame(width: 20)

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

            if !workspace.serverOverrides.isEmpty || !workspace.flattenOverrides.isEmpty {
                Text("\(workspace.serverOverrides.count + workspace.flattenOverrides.count) 项自定义")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
            }

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

private struct MCPWorkspaceDetailView: View {
    let workspace: MCPWorkspaceDTO
    let servers: [MCPServerConfigDTO]
    let defaultWorkspace: MCPWorkspaceDTO?
    @ObservedObject var viewModel: MCPRouterViewState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text(workspace.name)
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            tokenSection
            Divider()
            serverListSection
        }
        .frame(minWidth: 450, minHeight: 400)
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

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.token, forType: .string)
                }) {
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
                        // 非默认工作区：显示只读提示
                        if !workspace.isDefault {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                Text("工作区级别配置暂不支持，请在「服务器」Tab 中修改全局配置")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }

                        ForEach(servers) { server in
                            ServerToggleCardView(
                                server: server,
                                workspace: workspace,
                                defaultWorkspace: defaultWorkspace,
                                isEditable: workspace.isDefault,
                                onToggle: { enabled in
                                    // 只有默认工作区才能编辑，使用全局配置
                                    viewModel.setServerEnabled(server.name, enabled: enabled)
                                },
                                onFlattenToggle: { flatten in
                                    viewModel.setServerFlattenMode(server.name, flatten: flatten)
                                }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct ServerToggleCardView: View {
    let server: MCPServerConfigDTO
    let workspace: MCPWorkspaceDTO
    let defaultWorkspace: MCPWorkspaceDTO?
    let isEditable: Bool
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
            HStack {
                Image(systemName: server.serverType == "http" ? "globe" : "terminal")
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
                .disabled(!isEditable)
            }

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
                    .disabled(!isEditable)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(isFlattenCustomized ? Color.orange.opacity(0.1) : Color.primary.opacity(0.03))
                .cornerRadius(4)
            }

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

// MARK: - Integration Tab

private struct IntegrationTab: View {
    @ObservedObject var viewModel: MCPRouterViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("全局配置集成")
                    .font(.headline)

                Text("将 MCP Router 安装到 Claude CLI 或 Codex 的全局配置中。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                ClaudeIntegrationRowView(port: viewModel.port)
                CodexIntegrationRowView(port: viewModel.port)

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Claude Integration (JSON)

private struct ClaudeIntegrationRowView: View {
    let port: Int
    private let configPath = "~/.claude.json"

    @State private var isInstalled = false
    @State private var configExists = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.blue)

                Text("Claude CLI")
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
                    Button(isInstalled ? "卸载" : "安装") {
                        toggleInstall()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isInstalled ? Color.secondary.opacity(0.2) : Color.accentColor)
                    .foregroundColor(isInstalled ? .primary : .white)
                    .cornerRadius(6)
                } else {
                    Button("创建配置") {
                        createConfig()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
            }

            Text(configPath)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
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

    private func createConfig() {
        let expandedPath = NSString(string: configPath).expandingTildeInPath

        let initialConfig: [String: Any] = [
            "mcpServers": [
                "mcp-router": [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)"
                ]
            ]
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: initialConfig, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: URL(fileURLWithPath: expandedPath))
            checkStatus()
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

// MARK: - Codex Integration (TOML)

private struct CodexIntegrationRowView: View {
    let port: Int
    private let configPath = "~/.codex/config.toml"

    @State private var isInstalled = false
    @State private var configExists = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .foregroundColor(.blue)

                Text("Codex")
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
                    Button(isInstalled ? "卸载" : "安装") {
                        toggleInstall()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isInstalled ? Color.secondary.opacity(0.2) : Color.accentColor)
                    .foregroundColor(isInstalled ? .primary : .white)
                    .cornerRadius(6)
                } else {
                    Text("配置文件不存在")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Text(configPath)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            checkStatus()
        }
    }

    private func checkStatus() {
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        configExists = FileManager.default.fileExists(atPath: expandedPath)

        if configExists {
            if let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
                isInstalled = content.contains("[mcp_servers.mcp-router]")
            }
        }
    }

    private func toggleInstall() {
        let expandedPath = NSString(string: configPath).expandingTildeInPath

        guard var content = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return
        }

        if isInstalled {
            let pattern = #"\[mcp_servers\.mcp-router\]\n(?:(?!\[)[^\n]*\n)*"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                content = regex.stringByReplacingMatches(
                    in: content,
                    options: [],
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: ""
                )
            }
        } else {
            let mcpConfig = """

            [mcp_servers.mcp-router]
            type = "http"
            url = "http://127.0.0.1:\(port)"
            """
            content += mcpConfig
        }

        try? content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
        isInstalled.toggle()
    }
}
