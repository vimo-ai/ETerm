//
//  GlobalConfigView.swift
//  ETerm
//
//  全局配置集成视图 - Claude CLI / Codex 配置同步
//

import SwiftUI

/// 全局配置集成视图
struct GlobalConfigView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Text("全局配置集成")
                    .font(.headline)
                Spacer()
            }

            Text("将 MCP Router 安装到 Claude CLI 或 Codex 的全局配置中，所有 workspace 均可直接访问。")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // Provider 列表
            ForEach(GlobalConfigProviders.all, id: \.id) { provider in
                ConfigProviderRowView(provider: provider)
            }

            Spacer()
        }
    }
}

// MARK: - Provider Row

private struct ConfigProviderRowView: View {
    let provider: any GlobalConfigProvider

    @State private var isInstalled = false
    @State private var configExists = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 图标和名称
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: provider.id == "claude" ? "terminal" : "chevron.left.forwardslash.chevron.right")
                            .foregroundColor(.blue)

                        Text(provider.displayName)
                            .font(.headline)

                        // 状态标签
                        if isInstalled {
                            Text("已安装")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(4)
                        }
                    }

                    Text(provider.descriptionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 操作按钮
                if configExists {
                    if isInstalled {
                        Button(action: uninstall) {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("卸载")
                            }
                        }
                        .disabled(isProcessing)
                    } else {
                        Button(action: install) {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("安装")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isProcessing)
                    }
                } else {
                    Text("配置文件不存在")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // 配置文件路径
            HStack {
                Text(provider.configPath.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: openConfigDirectory) {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("打开配置目录")
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear(perform: checkStatus)
        .alert("错误", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    // MARK: - Actions

    private func checkStatus() {
        configExists = FileManager.default.fileExists(atPath: provider.configPath.path)

        if configExists {
            do {
                isInstalled = try provider.isInstalled()
            } catch {
                isInstalled = false
            }
        }
    }

    private func install() {
        guard let plugin = MCPRouterPlugin.shared else { return }

        isProcessing = true

        DispatchQueue.global().async {
            do {
                try provider.install(port: Int(plugin.currentPort))
                DispatchQueue.main.async {
                    isInstalled = true
                    isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isProcessing = false
                }
            }
        }
    }

    private func uninstall() {
        isProcessing = true

        DispatchQueue.global().async {
            do {
                try provider.uninstall()
                DispatchQueue.main.async {
                    isInstalled = false
                    isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isProcessing = false
                }
            }
        }
    }

    private func openConfigDirectory() {
        let dirPath = provider.configPath.deletingLastPathComponent().path
        NSWorkspace.shared.selectFile(provider.configPath.path, inFileViewerRootedAtPath: dirPath)
    }
}

// MARK: - Preview

#Preview {
    GlobalConfigView()
        .padding()
        .frame(width: 450, height: 350)
}
