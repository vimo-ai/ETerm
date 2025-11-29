//
//  SentenceUnderstandingView.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/16.
//

import SwiftUI

struct SentenceUnderstandingView: View {
    @State private var inputText = ""
    @State private var translation = ""
    @State private var grammarAnalysis = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("📝 Sentence Understanding")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            // 输入区
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(
                        Group {
                            if inputText.isEmpty {
                                Text("输入英文句子或段落 (如: You should refactor this code...)")
                                    .foregroundColor(.secondary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                        }
                    )

                Button(action: analyze) {
                    Label("分析", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.isEmpty || isLoading)
            }
            .padding()

            Divider()

            // 内容区
            if isLoading {
                VStack {
                    ProgressView()
                    Text("分析中...")
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
            } else if !translation.isEmpty {
                // 左右分栏显示结果
                HStack(alignment: .top, spacing: 0) {
                    // 左栏: 翻译
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Translation")
                            .font(.headline)
                            .foregroundColor(.blue)

                        Text("翻译")
                            .font(.headline)
                            .foregroundColor(.green)

                        Divider()

                        ScrollView {
                            Text(translation)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()

                    Divider()

                    // 右栏: 语法分析
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Grammar Analysis")
                            .font(.headline)
                            .foregroundColor(.blue)

                        Text("语法分析")
                            .font(.headline)
                            .foregroundColor(.green)

                        Divider()

                        ScrollView {
                            Text(grammarAnalysis)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("输入句子开始分析")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func analyze() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isLoading = true
        error = nil
        translation = ""
        grammarAnalysis = ""

        Task {
            do {
                try await AIService.shared.analyzeSentence(text) { trans, grammar in
                    self.translation = trans
                    self.grammarAnalysis = grammar
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
    SentenceUnderstandingView()
        .frame(width: 900, height: 600)
}
