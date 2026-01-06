//
//  VlaudeSettingsView.swift
//  VlaudeKit
//
//  远程控制设置视图
//

import SwiftUI

struct VlaudeSettingsView: View {
    @ObservedObject private var configManager = VlaudeConfigManager.shared

    @State private var serverURL: String = ""
    @State private var deviceName: String = ""
    @State private var isEnabled: Bool = false

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let msg): return msg
            case .failure(let msg): return msg
            }
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 标题
                HStack {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    Text("Remote Control")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                .padding(.bottom, 8)

                // 启用开关
                Toggle("Enable Remote Control", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        configManager.config.enabled = newValue
                    }

                // 连接状态
                if isEnabled {
                    HStack {
                        connectionStatusView
                        Spacer()
                        if configManager.connectionStatus == .disconnected {
                            Button("Reconnect") {
                                configManager.requestReconnect()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                // 服务器配置
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Configuration")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("http://your-server:3000", text: $serverURL)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    saveServerURL()
                                }

                            Button("Test") {
                                testConnection()
                            }
                            .disabled(serverURL.isEmpty || isTesting)
                        }

                        Text("Enter the URL of your vlaude-server instance")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Device Name")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("My Mac", text: $deviceName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                saveDeviceName()
                            }

                        Text("This name will be shown on mobile devices")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1.0 : 0.5)

                // 测试结果
                if let result = testResult {
                    HStack {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.isSuccess ? .green : .red)
                        Text(result.message)
                            .font(.subheadline)
                            .foregroundColor(result.isSuccess ? .green : .red)
                    }
                    .padding(8)
                    .background(result.isSuccess ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                if isTesting {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing connection...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // 说明
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Remote Control")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Remote Control allows you to view and interact with Claude sessions from your mobile device. You need a running vlaude-server instance to use this feature.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Features:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        FeatureRow(icon: "eye", text: "View Claude sessions on mobile")
                        FeatureRow(icon: "text.cursor", text: "Send messages remotely")
                        FeatureRow(icon: "plus.circle", text: "Create new sessions from mobile")
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadConfig()
        }
    }

    // MARK: - Connection Status View

    @ViewBuilder
    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            statusIndicator
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch configManager.connectionStatus {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private var statusText: String {
        switch configManager.connectionStatus {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .reconnecting:
            return "Reconnecting..."
        case .disconnected:
            return "Disconnected"
        }
    }

    // MARK: - Actions

    private func loadConfig() {
        let config = configManager.config
        serverURL = config.serverURL
        deviceName = config.deviceName
        isEnabled = config.enabled
    }

    private func saveServerURL() {
        configManager.config.serverURL = serverURL
    }

    private func saveDeviceName() {
        configManager.config.deviceName = deviceName
    }

    private func testConnection() {
        // 使用当前配置测试
        isTesting = true
        testResult = nil

        VlaudeClient.testConnection(config: configManager.config) { [self] result in
            DispatchQueue.main.async {
                isTesting = false

                switch result {
                case .success(let message):
                    testResult = .success(message)

                case .failure(let error):
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 16)

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    VlaudeSettingsView()
        .frame(width: 300, height: 500)
}
