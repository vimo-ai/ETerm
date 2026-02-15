//
//  SettingsView.swift
//  ETerm
//
//  设置页面
//

import SwiftUI
import UniformTypeIdentifiers
import ETermKit

struct SettingsView: View {
    @StateObject private var configManager = AIConfigManager.shared
    @StateObject private var ollamaService = OllamaService.shared
    @StateObject private var hookInstaller = ClaudeHookInstaller.shared

    @State private var apiKey: String = ""
    @State private var baseURL: String = ""

    @State private var testStatus: TestStatus = .idle
    @State private var showTestResult = false
    @State private var testMessage = ""

    // Ollama 配置
    @State private var ollamaModel: String = ""
    @State private var ollamaBaseURL: String = ""
    @State private var ollamaTestStatus: TestStatus = .idle
    @State private var ollamaTestMessage: String = ""
    @State private var showOllamaTestResult: Bool = false
    @State private var availableModels: [String] = []

    // Claude Hooks 配置
    @State private var hookInstallError: String? = nil
    @State private var showHookForceAlert: Bool = false

    // 外观配置
    @ObservedObject private var backgroundConfig = BackgroundConfig.shared
    @State private var selectedBackgroundMode: BackgroundMode = BackgroundConfig.shared.mode

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

                    // 本地 AI (Ollama) 配置
                    SettingsSectionView(title: "本地 AI (Ollama)") {
                        VStack(alignment: .leading, spacing: 16) {
                            // 状态显示
                            HStack {
                                Circle()
                                    .fill(ollamaStatusColor)
                                    .frame(width: 8, height: 8)
                                Text(ollamaService.status.displayText)
                                    .font(.subheadline)
                                Spacer()
                                Button("刷新状态") {
                                    refreshOllamaStatus()
                                }
                                .buttonStyle(.borderless)
                                .disabled(ollamaTestStatus == .testing)
                            }

                            Divider()

                            // Base URL
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ollama 地址")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                TextField("http://localhost:11434", text: $ollamaBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: ollamaBaseURL) { _, _ in
                                        saveOllamaConfig()
                                    }
                            }

                            // 模型选择
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("模型")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if !availableModels.isEmpty {
                                        Text("\(availableModels.count) 个可用")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                HStack {
                                    if availableModels.isEmpty {
                                        TextField("qwen3:0.6b", text: $ollamaModel)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: ollamaModel) { _, _ in
                                                saveOllamaConfig()
                                            }
                                    } else {
                                        Picker("", selection: $ollamaModel) {
                                            ForEach(availableModels, id: \.self) { model in
                                                Text(model).tag(model)
                                            }
                                        }
                                        .labelsHidden()
                                        .onChange(of: ollamaModel) { _, _ in
                                            saveOllamaConfig()
                                        }
                                    }

                                    Button("刷新") {
                                        refreshModels()
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            Divider()

                            // 测试按钮
                            Button(action: testOllamaConnection) {
                                HStack {
                                    if ollamaTestStatus == .testing {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: ollamaTestStatus == .success ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                                    }
                                    Text(ollamaTestStatus == .testing ? "测试中..." : "测试连接")
                                }
                            }
                            .disabled(ollamaTestStatus == .testing)

                            // 测试结果
                            if showOllamaTestResult {
                                HStack {
                                    Image(systemName: ollamaTestStatus == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(ollamaTestStatus == .success ? .green : .red)
                                    Text(ollamaTestMessage)
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(ollamaTestStatus == .success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                                )
                            }

                            // 帮助信息
                            VStack(alignment: .leading, spacing: 4) {
                                Text("命令补全 AI 建议")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("启用后，在终端输入命令时会使用本地 AI 从历史记录中选择最合适的建议。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("需要安装 Ollama 并下载模型：ollama pull qwen3:0.6b")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }

                    // Claude Hooks 配置
                    SettingsSectionView(title: "Claude Hooks") {
                        VStack(alignment: .leading, spacing: 12) {
                            // 状态显示
                            HStack {
                                Circle()
                                    .fill(hookStatusColor)
                                    .frame(width: 8, height: 8)
                                Text(hookInstaller.status.displayText)
                                    .font(.subheadline)
                                Spacer()
                                Button("刷新") {
                                    hookInstaller.checkStatus()
                                }
                                .buttonStyle(.borderless)
                            }

                            // 已安装的 hooks 列表
                            if !hookInstaller.installedHooks.isEmpty {
                                Text("已注册: \(hookInstaller.installedHooks.map { $0.description }.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            // 安装/更新按钮
                            HStack {
                                Button(action: installHooks) {
                                    HStack {
                                        if hookInstaller.isInstalling {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .frame(width: 14, height: 14)
                                        } else {
                                            Image(systemName: hookButtonIcon)
                                        }
                                        Text(hookButtonText)
                                    }
                                }
                                .disabled(hookInstaller.isInstalling)

                                Spacer()

                                Button("打开脚本目录") {
                                    hookInstaller.openScriptsDirectory()
                                }
                                .buttonStyle(.borderless)

                                Button("打开配置文件") {
                                    hookInstaller.openSettingsFile()
                                }
                                .buttonStyle(.borderless)
                            }

                            // 错误提示
                            if let error = hookInstallError {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.red.opacity(0.1))
                                )
                            }

                            // 帮助信息
                            Text("Claude Hooks 用于建立终端与会话的映射，支持自动恢复会话。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .alert("覆盖确认", isPresented: $showHookForceAlert) {
                        Button("覆盖", role: .destructive) {
                            Task {
                                do {
                                    try await hookInstaller.install(force: true)
                                    hookInstallError = nil
                                } catch {
                                    hookInstallError = error.localizedDescription
                                }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("脚本已被修改，是否强制覆盖？")
                    }

                    // 外观配置
                    SettingsSectionView(title: "外观") {
                        VStack(alignment: .leading, spacing: 16) {
                            // 背景模式 — 用 @State 驱动，onChange 同步到 config
                            HStack {
                                Text("终端背景")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Picker("", selection: $selectedBackgroundMode) {
                                    Text("山水画").tag(BackgroundMode.mountain)
                                    Text("自定义图片").tag(BackgroundMode.custom)
                                    Text("无背景").tag(BackgroundMode.plain)
                                }
                                .labelsHidden()
                                .frame(width: 160)
                                .onChange(of: selectedBackgroundMode) { _, newValue in
                                    NSLog("[BG] Picker changed to: \(newValue.rawValue)")
                                    backgroundConfig.mode = newValue
                                }
                            }

                            // 自定义图片选择
                            if selectedBackgroundMode == .custom {
                                HStack {
                                    Button("选择图片...") {
                                        selectBackgroundImage()
                                    }

                                    if backgroundConfig.customImagePath != nil {
                                        Button("清除图片") {
                                            backgroundConfig.customImagePath = nil
                                        }
                                        .foregroundColor(.red)
                                        .buttonStyle(.bordered)
                                    }

                                    Spacer()
                                }

                                if let path = backgroundConfig.customImagePath {
                                    Text((path as NSString).lastPathComponent)
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if let image = backgroundConfig.customImage {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 80)
                                            .clipped()
                                            .contentShape(Rectangle())
                                            .cornerRadius(6)
                                    }
                                }
                            }

                            // 透明度
                            if selectedBackgroundMode != .plain {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("透明度")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(Int(backgroundConfig.opacity * 100))%")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .monospacedDigit()
                                    }
                                    Slider(value: $backgroundConfig.opacity, in: 0...1, step: 0.05)
                                }
                            }

                        }
                    }
                    .onAppear {
                        selectedBackgroundMode = backgroundConfig.mode
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
    .onAppear(perform: loadOllamaConfig)
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

    // MARK: - Claude Hooks

    private var hookStatusColor: Color {
        switch hookInstaller.status {
        case .installed:
            return .green
        case .notInstalled, .outdated, .partiallyInstalled:
            return .orange
        case .userModified:
            return .blue
        case .error:
            return .red
        }
    }

    private var hookButtonIcon: String {
        switch hookInstaller.status {
        case .installed:
            return "checkmark.circle"
        case .notInstalled:
            return "arrow.down.circle"
        case .outdated, .partiallyInstalled:
            return "arrow.triangle.2.circlepath"
        case .userModified:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.circle"
        }
    }

    private var hookButtonText: String {
        switch hookInstaller.status {
        case .installed:
            return "已是最新"
        case .notInstalled:
            return "安装 Hooks"
        case .outdated, .partiallyInstalled:
            return "更新 Hooks"
        case .userModified:
            return "强制更新"
        case .error:
            return "重试安装"
        }
    }

    private func installHooks() {
        // 如果用户修改过脚本，先弹窗确认
        if case .userModified = hookInstaller.status {
            showHookForceAlert = true
            return
        }

        Task {
            do {
                try await hookInstaller.install(force: false)
                hookInstallError = nil
            } catch {
                hookInstallError = error.localizedDescription
            }
        }
    }

    // MARK: - 外观

    private func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择终端背景图片"

        if panel.runModal() == .OK, let url = panel.url {
            // 拷贝到 app 数据目录，避免权限问题
            let destDir = ETermPaths.root + "/backgrounds"
            try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            let destPath = destDir + "/" + url.lastPathComponent

            try? FileManager.default.removeItem(atPath: destPath)
            try? FileManager.default.copyItem(atPath: url.path, toPath: destPath)

            backgroundConfig.customImagePath = destPath
        }
    }

    // MARK: - Ollama 配置

    private var ollamaStatusColor: Color {
        switch ollamaService.status {
        case .ready: return .green
        case .notInstalled, .notRunning, .modelNotFound: return .orange
        case .error: return .red
        case .unknown: return .gray
        }
    }

    private func loadOllamaConfig() {
        let settings = ollamaService.settings
        ollamaModel = settings.model
        ollamaBaseURL = settings.baseURL

        // 自动刷新状态和模型列表
        refreshOllamaStatus()
        refreshModels()
    }

    private func saveOllamaConfig() {
        var newSettings = ollamaService.settings
        newSettings.model = ollamaModel
        newSettings.baseURL = ollamaBaseURL
        ollamaService.updateSettings(newSettings)
    }

    private func refreshOllamaStatus() {
        Task {
            await ollamaService.checkHealth()
        }
    }

    private func refreshModels() {
        Task {
            let models = await ollamaService.listModels()
            await MainActor.run {
                availableModels = models
                // 如果当前选择的模型不在列表中，自动选择第一个可用模型
                if !models.isEmpty && !models.contains(ollamaModel) {
                    ollamaModel = models.first ?? "qwen3:0.6b"
                }
            }
        }
    }

    private func testOllamaConnection() {
        ollamaTestStatus = .testing
        showOllamaTestResult = false

        Task {
            let healthy = await ollamaService.checkHealth()

            await MainActor.run {
                if healthy {
                    ollamaTestStatus = .success
                    ollamaTestMessage = "连接成功！Ollama 可用"
                } else {
                    ollamaTestStatus = .failure
                    ollamaTestMessage = ollamaService.status.displayText
                }
                showOllamaTestResult = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    ollamaTestStatus = .idle
                    showOllamaTestResult = false
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
