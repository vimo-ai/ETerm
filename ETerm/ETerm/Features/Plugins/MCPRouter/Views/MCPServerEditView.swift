//
//  MCPServerEditView.swift
//  ETerm
//
//  MCP Router 服务器编辑视图（添加/编辑）
//

import SwiftUI

/// 编辑模式
enum MCPServerEditMode {
    case add
    case edit(MCPServerConfigDTO)

    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}

/// 服务器编辑视图
struct MCPServerEditView: View {
    let mode: MCPServerEditMode
    let onSave: (MCPServerConfigDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    // 通用字段
    @State private var name = ""
    @State private var serverType: String = "http"
    @State private var serverDescription = ""

    // HTTP 字段
    @State private var url = ""
    @State private var headerPairs: [KeyValuePair] = []

    // Stdio 字段
    @State private var command = ""
    @State private var argsText = ""
    @State private var envPairs: [KeyValuePair] = []

    @State private var showingError = false
    @State private var errorMessage = ""

    init(mode: MCPServerEditMode, onSave: @escaping (MCPServerConfigDTO) -> Void) {
        self.mode = mode
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text(mode.isAdd ? "添加服务器" : "编辑服务器")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // 表单
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 基本信息
                    basicInfoSection

                    Divider()

                    // 类型特定配置
                    if serverType == "http" {
                        httpConfigSection
                    } else {
                        stdioConfigSection
                    }
                }
                .padding()
            }

            Divider()

            // 按钮
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(mode.isAdd ? "添加" : "保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .onAppear(perform: loadExistingData)
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基本信息")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // 名称
            LabeledContent("名称") {
                TextField("server-name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!mode.isAdd) // 编辑模式下不允许修改名称
            }

            // 类型
            LabeledContent("类型") {
                Picker("", selection: $serverType) {
                    Text("HTTP").tag("http")
                    Text("Stdio").tag("stdio")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(!mode.isAdd) // 编辑模式下不允许修改类型
            }

            // 描述
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

            Text("输入 MCP 服务器的 HTTP 端点地址")
                .font(.caption)
                .foregroundColor(.secondary)

            // HTTP Headers
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Headers")
                    Spacer()
                    Button(action: addHeaderPair) {
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
                            .foregroundColor(.secondary)

                        TextField("value", text: $pair.value)
                            .textFieldStyle(.roundedBorder)

                        Button(action: { removeHeaderPair(pair) }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if headerPairs.isEmpty {
                    Text("可添加 Authorization 等认证头")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var stdioConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stdio 配置")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // 命令
            LabeledContent("命令") {
                TextField("/usr/bin/node", text: $command)
                    .textFieldStyle(.roundedBorder)
            }

            // 参数
            LabeledContent("参数") {
                TextField("index.js --port 8080", text: $argsText)
                    .textFieldStyle(.roundedBorder)
            }

            Text("参数以空格分隔")
                .font(.caption)
                .foregroundColor(.secondary)

            // 环境变量
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("环境变量")
                    Spacer()
                    Button(action: addEnvPair) {
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
                            .foregroundColor(.secondary)

                        TextField("value", text: $pair.value)
                            .textFieldStyle(.roundedBorder)

                        Button(action: { removeEnvPair(pair) }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: - Actions

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

    private func addEnvPair() {
        envPairs.append(KeyValuePair(key: "", value: ""))
    }

    private func removeEnvPair(_ pair: KeyValuePair) {
        envPairs.removeAll { $0.id == pair.id }
    }

    private func addHeaderPair() {
        headerPairs.append(KeyValuePair(key: "", value: ""))
    }

    private func removeHeaderPair(_ pair: KeyValuePair) {
        headerPairs.removeAll { $0.id == pair.id }
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

// MARK: - Helper Types

private struct KeyValuePair: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}
