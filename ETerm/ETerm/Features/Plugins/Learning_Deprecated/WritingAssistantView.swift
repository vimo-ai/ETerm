//
//  WritingAssistantView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/16.
//

import SwiftUI

struct WritingAssistantView: View {
    @State private var inputText = ""
    @State private var suggestions = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("✍️ Writing Assistant")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            // 输入区
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        Group {
                            if inputText.isEmpty {
                                Text("输入你要发送给 Claude 的内容 (可以中英混合)\n如: I want implement a 新功能")
                                    .foregroundColor(.secondary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                        }
                    )

                Button(action: check) {
                    Label("检查", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.isEmpty || isLoading)
            }
            .padding()

            Divider()

            // 建议显示区
            if isLoading {
                VStack {
                    ProgressView()
                    Text("检查中...")
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("💡 建议与改进")
                            .font(.headline)
                            .foregroundColor(.blue)

                        Spacer()

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(suggestions, forType: .string)
                        }) {
                            Label("复制建议", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    Divider()

                    ScrollView {
                        Text(suggestions)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("输入文本开始检查")
                        .foregroundColor(.secondary)
                    Text("可以帮你检查语法、用词、并将中文转为英文建议")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func check() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isLoading = true
        error = nil
        suggestions = ""

        Task {
            do {
                // 从插件配置读取模型
                let pluginConfig = TranslationPluginConfigManager.shared.config

                try await AIService.shared.checkWriting(text, model: pluginConfig.analysisModel) { result in
                    self.suggestions = result
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    WritingAssistantView()
        .frame(width: 900, height: 600)
}
