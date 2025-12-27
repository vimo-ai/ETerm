//
//  CommandInputView.swift
//  ETerm
//
//  命令输入视图（SwiftUI）

import SwiftUI

/// 命令输入视图
struct CommandInputView: View {
    // MARK: - 状态

    @State private var command: String = ""
    @State private var resultMessage: String = ""
    @State private var isError: Bool = false
    @State private var showResult: Bool = false

    let cwd: String
    let onExecute: (String) -> Void
    let onCancel: () -> Void

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            // 输入框区域
            HStack(spacing: 12) {
                // 提示符
                Text(">")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                // 输入框（使用自定义的可聚焦 TextField）
                FocusableTextField(
                    text: $command,
                    placeholder: "输入命令...",
                    onSubmit: {
                        executeCommand()
                    },
                    onEscape: {
                        onCancel()
                    }
                )

                // 工作目录提示
                Text(shortenPath(cwd))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // 结果显示区域
            if showResult {
                HStack {
                    Text(resultMessage)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(isError ? .red : .green)
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    Spacer()
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        )
        .padding(4)
        .onReceive(NotificationCenter.default.publisher(for: .commandExecutionResult)) { notification in
            handleExecutionResult(notification)
        }
    }

    // MARK: - 私有方法

    /// 执行命令
    private func executeCommand() {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        let commandToExecute = command
        command = ""  // 清空输入框
        showResult = false

        onExecute(commandToExecute)
    }

    /// 处理执行结果
    private func handleExecutionResult(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String,
              let error = userInfo["isError"] as? Bool else {
            return
        }

        withAnimation {
            resultMessage = message
            isError = error
            showResult = true
        }

        // 3 秒后自动隐藏结果
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showResult = false
            }
        }
    }

    /// 缩短路径显示
    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - 预览

#Preview {
    CommandInputView(
        cwd: "/Users/username/Documents/project",
        onExecute: { command in
        },
        onCancel: {
        }
    )
    .frame(width: 500, height: 80)
}
