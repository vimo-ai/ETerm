// TerminalPanelView.swift
// DevHelperKit
//
// 终端面板视图

import SwiftUI

/// 终端面板视图
struct TerminalPanelView: View {
    @ObservedObject var viewModel: DevHelperViewModel
    @Binding var selectedScript: SelectedScript?

    @State private var currentTerminalId: Int = -1

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                if let selected = selectedScript {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.secondary)
                    Text("\(selected.projectName) - \(selected.scriptName)")
                        .font(.headline)

                    if viewModel.isRunning(projectPath: selected.projectPath, scriptName: selected.scriptName) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                    }
                } else {
                    Image(systemName: "terminal")
                        .foregroundColor(.secondary)
                    Text("选择一个脚本")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()

                if currentTerminalId >= 0 {
                    Text("Terminal #\(currentTerminalId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // 终端区域
            if let selected = selectedScript {
                TerminalInstanceView(
                    selectedScript: selected,
                    viewModel: viewModel,
                    currentTerminalId: $currentTerminalId
                )
            } else {
                // 空状态
                VStack {
                    Spacer()
                    Image(systemName: "arrow.left")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("从左侧选择一个脚本运行")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }
}

/// 终端实例视图
struct TerminalInstanceView: View {
    let selectedScript: SelectedScript
    @ObservedObject var viewModel: DevHelperViewModel
    @Binding var currentTerminalId: Int

    @State private var terminalKey = UUID()
    @State private var isStarting = false

    private var isRunning: Bool {
        viewModel.isRunning(projectPath: selectedScript.projectPath, scriptName: selectedScript.scriptName)
    }

    private var shouldShowTerminal: Bool {
        isRunning || isStarting
    }

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowTerminal {
                // 终端占位符 - 实际终端由主应用提供
                TerminalPlaceholderView(
                    projectPath: selectedScript.projectPath,
                    terminalKey: terminalKey,
                    onTerminalCreated: { id in
                        currentTerminalId = id
                        if isStarting {
                            executeStartCommand(terminalId: id)
                        }
                    }
                )
                .id(terminalKey)
            } else {
                // 未运行：显示启动按钮
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green.opacity(0.8))

                    Text("点击启动")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Text(selectedScript.scriptCommand)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)

                    Button("启动") {
                        startScript()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Spacer()
                }
            }
        }
        .onChange(of: selectedScript) { _, newValue in
            // 切换脚本时重置状态
            isStarting = false
            if let existingId = viewModel.getTerminalId(projectPath: newValue.projectPath, scriptName: newValue.scriptName) {
                currentTerminalId = existingId
            }
            terminalKey = UUID()
        }
    }

    private func startScript() {
        isStarting = true
        terminalKey = UUID()
    }

    private func executeStartCommand(terminalId: Int) {
        // 发送启动任务请求
        NotificationCenter.default.post(
            name: NSNotification.Name("DevHelperStartTask"),
            object: nil,
            userInfo: [
                "projectPath": selectedScript.projectPath,
                "scriptName": selectedScript.scriptName,
                "terminalId": terminalId
            ]
        )

        isStarting = false

        // 执行命令
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let command = "cd '\(selectedScript.projectPath)' && \(selectedScript.scriptCommand)"
            NotificationCenter.default.post(
                name: NSNotification.Name("EmbeddedTerminalWriteInput"),
                object: nil,
                userInfo: [
                    "terminalId": terminalId,
                    "data": command + "\n"
                ]
            )
        }
    }
}

/// 终端占位符视图 - 实际终端由主应用注入
struct TerminalPlaceholderView: View {
    let projectPath: String
    let terminalKey: UUID
    let onTerminalCreated: (Int) -> Void

    var body: some View {
        // 这个视图会被主应用替换为实际的 EmbeddedTerminalView
        Color(nsColor: .textBackgroundColor)
            .overlay(
                VStack {
                    ProgressView()
                    Text("加载终端...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
            .onAppear {
                // 请求主应用创建终端
                NotificationCenter.default.post(
                    name: NSNotification.Name("DevHelperCreateTerminal"),
                    object: nil,
                    userInfo: [
                        "workingDirectory": projectPath,
                        "terminalKey": terminalKey.uuidString
                    ]
                )
            }
    }
}
