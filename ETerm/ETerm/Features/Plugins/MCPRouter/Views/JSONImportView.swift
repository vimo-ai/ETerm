//
//  JSONImportView.swift
//  ETerm
//
//  MCP Router JSON 导入界面
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据模型

/// 导入状态
enum MCPImportState {
    case editing          // 编辑 JSON
    case duplicateCheck   // 检测到重复，选择策略
    case importing        // 导入中
    case completed        // 完成，显示报告
}

/// 重复处理策略
enum MCPDuplicateStrategy: String, CaseIterable {
    case skip = "跳过重复项"
    case replace = "覆盖已存在的"
    case rename = "重命名导入"

    var description: String {
        switch self {
        case .skip:
            return "保留现有配置，不导入重复的服务器"
        case .replace:
            return "用新配置覆盖已存在的服务器"
        case .rename:
            return "自动重命名（如：context7 → context7-2）"
        }
    }

    var icon: String {
        switch self {
        case .skip: return "arrow.forward.circle"
        case .replace: return "arrow.triangle.2.circlepath"
        case .rename: return "doc.on.doc"
        }
    }
}

/// 导入结果统计
struct MCPImportResult {
    var added: [String] = []
    var skipped: [String] = []
    var replaced: [String] = []
    var failed: [(name: String, reason: String)] = []

    var totalProcessed: Int {
        added.count + skipped.count + replaced.count + failed.count
    }

    var successCount: Int {
        added.count + replaced.count
    }
}

// MARK: - JSONImportView

struct MCPJSONImportView: View {
    @Environment(\.dismiss) private var dismiss

    let bridge: MCPRouterBridge?
    let onImported: () -> Void

    @State private var jsonText = ""
    @State private var errorMessage: String?
    @State private var importState: MCPImportState = .editing
    @State private var duplicateNames: [String] = []
    @State private var selectedStrategy: MCPDuplicateStrategy = .skip
    @State private var importResult = MCPImportResult()
    @State private var existingServers: [MCPServerConfig] = []
    @State private var parsedConfigs: [String: [String: Any]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(navigationTitle)
                    .font(.headline)
                Spacer()
                Button(importState == .completed ? "关闭" : "取消") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            // 内容
            Group {
                switch importState {
                case .editing:
                    editingView
                case .duplicateCheck:
                    duplicateCheckView
                case .importing:
                    importingView
                case .completed:
                    completedView
                }
            }
        }
        .frame(width: 550, height: 500)
        .onAppear {
            loadExistingServers()
        }
    }

    private var navigationTitle: String {
        switch importState {
        case .editing: return "导入 JSON 配置"
        case .duplicateCheck: return "处理重复项"
        case .importing: return "导入中..."
        case .completed: return "导入完成"
        }
    }

    // MARK: - 编辑视图

    private var editingView: some View {
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
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }

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
                Button("选择文件...") {
                    selectFile()
                }

                Spacer()

                Button("导入") {
                    startImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(jsonText.isEmpty)
            }

            // 格式说明
            VStack(alignment: .leading, spacing: 6) {
                Text("支持的格式: Claude Code .mcp.json")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("""
                {
                  "mcpServers": {
                    "server-name": {
                      "type": "http",
                      "url": "http://localhost:8080"
                    }
                  }
                }
                """)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            }
        }
        .padding()
    }

    // MARK: - 重复检查视图

    private var duplicateCheckView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text("检测到重复的服务器")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(duplicateNames, id: \.self) { name in
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(.orange)
                            Text(name)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            .frame(maxHeight: 100)

            Divider()

            Text("如何处理这些重复项？")
                .font(.subheadline)

            VStack(spacing: 8) {
                ForEach(MCPDuplicateStrategy.allCases, id: \.self) { strategy in
                    Button {
                        selectedStrategy = strategy
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: strategy.icon)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(strategy.rawValue)
                                    .font(.subheadline)
                                Text(strategy.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if selectedStrategy == strategy {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(10)
                        .background(selectedStrategy == strategy ? Color.blue.opacity(0.1) : Color.clear)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedStrategy == strategy ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            HStack {
                Button("返回") {
                    importState = .editing
                }

                Spacer()

                Button("继续导入") {
                    performImport()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - 导入中视图

    private var importingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("正在导入...")
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 完成视图

    private var completedView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)

                Text("导入完成")
                    .font(.title2)
                    .fontWeight(.bold)

                // 统计
                HStack(spacing: 30) {
                    statView(value: importResult.totalProcessed, label: "总计", color: .primary)
                    statView(value: importResult.successCount, label: "成功", color: .green)
                    if !importResult.failed.isEmpty {
                        statView(value: importResult.failed.count, label: "失败", color: .red)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

                // 详情
                VStack(alignment: .leading, spacing: 12) {
                    if !importResult.added.isEmpty {
                        resultSection(title: "✅ 新增", items: importResult.added, color: .green)
                    }
                    if !importResult.replaced.isEmpty {
                        resultSection(title: "🔄 覆盖", items: importResult.replaced, color: .blue)
                    }
                    if !importResult.skipped.isEmpty {
                        resultSection(title: "⏭️ 跳过", items: importResult.skipped, color: .orange)
                    }
                    if !importResult.failed.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("❌ 失败")
                                .font(.subheadline)
                                .foregroundColor(.red)
                            ForEach(importResult.failed, id: \.name) { item in
                                VStack(alignment: .leading) {
                                    Text("• \(item.name)")
                                    Text(item.reason)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 12)
                                }
                            }
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                Button("完成") {
                    onImported()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func statView(value: Int, label: String, color: Color) -> some View {
        VStack {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func resultSection(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title): \(items.count) 个")
                .font(.subheadline)
                .foregroundColor(color)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Actions

    private func loadExistingServers() {
        do {
            existingServers = try bridge?.listServers() ?? []
        } catch {
            existingServers = []
        }
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

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            if let data = data as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                DispatchQueue.main.async {
                    jsonText = content
                }
            }
        }
    }

    private func startImport() {
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

            if mcpServers.isEmpty {
                errorMessage = "mcpServers 为空"
                return
            }

            parsedConfigs = mcpServers

            // 检测重复
            let existingNames = Set(existingServers.map { $0.name })
            let importingNames = Set(mcpServers.keys)
            duplicateNames = Array(importingNames.intersection(existingNames)).sorted()

            if !duplicateNames.isEmpty {
                importState = .duplicateCheck
            } else {
                performImport()
            }

        } catch {
            errorMessage = "JSON 解析失败: \(error.localizedDescription)"
        }
    }

    private func performImport() {
        importState = .importing
        importResult = MCPImportResult()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let existingNames = Set(existingServers.map { $0.name })

            for (name, config) in parsedConfigs {
                let isDuplicate = existingNames.contains(name)

                if isDuplicate {
                    switch selectedStrategy {
                    case .skip:
                        importResult.skipped.append(name)
                        continue

                    case .replace:
                        do {
                            try bridge?.removeServer(name: name)
                            if let serverConfig = parseServerConfig(name: name, config: config) {
                                try bridge?.addServer(serverConfig)
                                importResult.replaced.append(name)
                            } else {
                                importResult.failed.append((name, "配置解析失败"))
                            }
                        } catch {
                            importResult.failed.append((name, error.localizedDescription))
                        }

                    case .rename:
                        var newName = name
                        var suffix = 2
                        var allNames = existingNames
                        while allNames.contains(newName) {
                            newName = "\(name)-\(suffix)"
                            suffix += 1
                        }

                        if let serverConfig = parseServerConfig(name: newName, config: config) {
                            do {
                                try bridge?.addServer(serverConfig)
                                importResult.added.append(newName)
                            } catch {
                                importResult.failed.append((newName, error.localizedDescription))
                            }
                        } else {
                            importResult.failed.append((name, "配置解析失败"))
                        }
                    }
                } else {
                    if let serverConfig = parseServerConfig(name: name, config: config) {
                        do {
                            try bridge?.addServer(serverConfig)
                            importResult.added.append(name)
                        } catch {
                            importResult.failed.append((name, error.localizedDescription))
                        }
                    } else {
                        importResult.failed.append((name, "配置解析失败"))
                    }
                }
            }

            // 保存配置到文件
            MCPRouterPlugin.shared?.saveServerConfigs()

            importState = .completed
        }
    }

    private func parseServerConfig(name: String, config: [String: Any]) -> MCPServerConfig? {
        let type: MCPServerType
        if let typeString = config["type"] as? String {
            type = typeString == "http" ? .http : .stdio
        } else if config["command"] != nil {
            type = .stdio
        } else if config["url"] != nil {
            type = .http
        } else {
            return nil
        }

        if type == .http {
            guard let url = config["url"] as? String else { return nil }
            let headers = config["headers"] as? [String: String]
            return MCPServerConfig.http(name: name, url: url, headers: headers)
        } else {
            guard let command = config["command"] as? String else { return nil }
            let args = config["args"] as? [String] ?? []
            let env = config["env"] as? [String: String] ?? [:]
            return MCPServerConfig.stdio(name: name, command: command, args: args, env: env)
        }
    }
}

// MARK: - Preview

#Preview {
    MCPJSONImportView(bridge: nil, onImported: {})
}
