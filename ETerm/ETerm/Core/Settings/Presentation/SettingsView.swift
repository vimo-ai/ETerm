//
//  SettingsView.swift
//  ETerm
//
//  设置页面
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @StateObject private var configManager = AIConfigManager.shared

    @State private var apiKey: String = ""
    @State private var baseURL: String = ""

    @State private var testStatus: TestStatus = .idle
    @State private var showTestResult = false
    @State private var testMessage = ""

    // 开发者选项
    @State private var debugLogEnabled: Bool = LogManager.shared.debugEnabled

    enum TestStatus {
        case idle
        case testing
        case success
        case failure
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("设置")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding()

            Divider()

            // 设置内容区域
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // AI 服务配置
                    SettingsSectionView(title: "AI 服务配置") {
                        VStack(alignment: .leading, spacing: 16) {
                            // API Key
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                SecureField("请输入 DashScope API Key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .focusable(true)
                                    .onPasteCommand(of: [.plainText]) { providers in
                                        providers.first?.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { (data, error) in
                                            if let data = data as? Data,
                                               let string = String(data: data, encoding: .utf8) {
                                                DispatchQueue.main.async {
                                                    apiKey = string
                                                }
                                            }
                                        }
                                    }
                            }

                            // Base URL
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Base URL")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                TextField("https://dashscope.aliyuncs.com/compatible-mode/v1", text: $baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .focusable(true)
                            }

                            Divider()

                            // 操作按钮
                            HStack(spacing: 12) {
                                Button(action: testConnection) {
                                    HStack {
                                        if testStatus == .testing {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .frame(width: 14, height: 14)
                                        } else {
                                            Image(systemName: testStatusIcon)
                                        }
                                        Text(testStatusText)
                                    }
                                }
                                .disabled(testStatus == .testing || !isFormValid)

                                Spacer()

                                Button("重置为默认", action: resetToDefault)
                                    .foregroundColor(.orange)

                                Button("保存", action: saveConfig)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!isFormValid)
                            }

                            // 测试结果提示
                            if showTestResult {
                                HStack {
                                    Image(systemName: testStatus == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(testStatus == .success ? .green : .red)
                                    Text(testMessage)
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(testStatus == .success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                                )
                            }
                        }
                    }

                    // 开发者选项
                    SettingsSectionView(title: "开发者选项") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $debugLogEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("调试日志")
                                        .font(.body)
                                    Text("启用后日志输出到 stderr，可在终端查看")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: debugLogEnabled) { _, newValue in
                                LogManager.shared.debugEnabled = newValue
                            }

                            // 日志文件位置
                            HStack {
                                Text("日志目录")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(ETermPaths.logs)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                Button(action: {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ETermPaths.logs)
                                }) {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("在 Finder 中打开")
                            }

                            // 数据目录
                            HStack {
                                Text("数据目录")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(ETermPaths.root)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                Button(action: {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ETermPaths.root)
                                }) {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("在 Finder 中打开")
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear(perform: loadConfig)
    }

    // MARK: - 辅助视图

    private var isFormValid: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && URL(string: baseURL) != nil
    }

    private var testStatusIcon: String {
        switch testStatus {
        case .idle: return "antenna.radiowaves.left.and.right"
        case .testing: return "antenna.radiowaves.left.and.right"
        case .success: return "checkmark.circle"
        case .failure: return "xmark.circle"
        }
    }

    private var testStatusText: String {
        switch testStatus {
        case .idle: return "测试连接"
        case .testing: return "测试中..."
        case .success: return "连接成功"
        case .failure: return "连接失败"
        }
    }

    // MARK: - 操作方法

    private func loadConfig() {
        let config = configManager.config
        apiKey = config.apiKey
        baseURL = config.baseURL
    }

    private func saveConfig() {
        configManager.config = AIConfig(
            apiKey: apiKey,
            baseURL: baseURL
        )

        // 重新初始化 AI 服务
        AIService.shared.reinitializeClient()

        // 显示保存成功提示
        testStatus = .success
        testMessage = "配置已保存"
        showTestResult = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showTestResult = false
            testStatus = .idle
        }
    }

    private func resetToDefault() {
        let defaultConfig = AIConfig.default
        apiKey = defaultConfig.apiKey
        baseURL = defaultConfig.baseURL
    }

    private func testConnection() {
        testStatus = .testing
        showTestResult = false

        Task {
            do {
                // 创建临时配置进行测试
                let tempConfig = AIConfig(
                    apiKey: apiKey,
                    baseURL: baseURL
                )

                // 临时保存配置
                let originalConfig = configManager.config
                configManager.config = tempConfig

                // 测试连接
                _ = try await configManager.testConnection()

                await MainActor.run {
                    testStatus = .success
                    testMessage = "连接成功！API 可用"
                    showTestResult = true

                    // 2秒后重置状态
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        testStatus = .idle
                        showTestResult = false
                    }
                }

                // 恢复原配置
                configManager.config = originalConfig

            } catch {
                await MainActor.run {
                    testStatus = .failure
                    testMessage = "连接失败：\(error.localizedDescription)"
                    showTestResult = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        testStatus = .idle
                        showTestResult = false
                    }
                }
            }
        }
    }
}

// MARK: - 设置分组视图

struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
