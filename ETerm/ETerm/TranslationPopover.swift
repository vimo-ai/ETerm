//
//  TranslationPopover.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import SwiftUI

// 内容类型枚举
enum ContentType {
    case dictionary(DictionaryWord)
    case translation(String)
}

struct TranslationPopoverView: View {
    let originalText: String
    @State private var content: ContentType?
    @State private var isLoading: Bool = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：原文区 + 关闭按钮
            HStack {
                Text(originalText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Spacer()

                // 来源标识
                if let content = content {
                    switch content {
                    case .dictionary:
                        Text("Dictionary")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    case .translation:
                        Text("qwen2.5:0.5b")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                // 关闭按钮
                Button(action: {
                    TranslationManager.shared.dismissPopover()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // 中间：内容区
            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("查询中...")
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 60)
                } else if let error = error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(height: 60)
                } else if let content = content {
                    switch content {
                    case .dictionary(let word):
                        DictionaryContentView(word: word)
                    case .translation(let text):
                        Text(text)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()

            // 底部：操作区
            HStack {
                if !isLoading && error == nil {
                    // 发音按钮(仅词典模式)
                    if case .dictionary(let word) = content,
                       let audioURL = word.phonetics?.first(where: { $0.audio != nil && !$0.audio!.isEmpty })?.audio {
                        Button(action: {
                            DictionaryService.shared.playPronunciation(audioURL: audioURL)
                        }) {
                            Label("发音", systemImage: "speaker.wave.2")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button(action: copyContent) {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        .onAppear {
            performLookup()
        }
    }

    // 判断是单词还是短语,并执行相应查询
    private func performLookup() {
        isLoading = true
        error = nil

        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSingleWord = !trimmed.contains(" ") && trimmed.rangeOfCharacter(from: .letters.inverted) == nil

        print("🔍 查询文本: '\(trimmed)'")
        print("📝 是否单词: \(isSingleWord)")

        Task {
            do {
                if isSingleWord {
                    // 单词 -> 优先使用词典
                    do {
                        let result = try await DictionaryService.shared.lookup(trimmed)
                        await MainActor.run {
                            content = .dictionary(result)
                            isLoading = false
                        }
                    } catch DictionaryError.wordNotFound {
                        // 词典查不到（如专有名词），降级使用翻译
                        print("⚠️ 词典未找到，使用翻译")
                        let result = try await OllamaService.shared.translate(trimmed)
                        await MainActor.run {
                            content = .translation(result)
                            isLoading = false
                        }
                    }
                } else {
                    // 短语/句子 -> 使用翻译
                    let result = try await OllamaService.shared.translate(trimmed)
                    await MainActor.run {
                        content = .translation(result)
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let content = content {
            switch content {
            case .dictionary(let word):
                // 复制词典内容(格式化)
                var text = "\(word.word)\n"
                if let phonetic = word.phonetic {
                    text += "\(phonetic)\n"
                }
                text += "\n"
                for meaning in word.meanings {
                    text += "\(meaning.partOfSpeech):\n"
                    for (index, def) in meaning.definitions.enumerated() {
                        text += "\(index + 1). \(def.definition)\n"
                        if let example = def.example {
                            text += "   例: \(example)\n"
                        }
                    }
                    text += "\n"
                }
                pasteboard.setString(text, forType: .string)
            case .translation(let text):
                pasteboard.setString(text, forType: .string)
            }
        }
    }
}

// 词典内容展示视图
struct DictionaryContentView: View {
    let word: DictionaryWord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 单词 + 音标
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.word)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                        Text(phonetic)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // 各个词性的释义
                ForEach(Array(word.meanings.enumerated()), id: \.offset) { index, meaning in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(meaning.partOfSpeech)
                            .font(.headline)
                            .foregroundColor(.blue)

                        ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, definition in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(defIndex + 1).")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                    Text(definition.definition)
                                        .font(.body)
                                }

                                if let example = definition.example {
                                    Text("例: \(example)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding(.leading, 20)
                                }
                            }
                        }
                    }

                    if index < word.meanings.count - 1 {
                        Divider()
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
    }
}

#Preview {
    TranslationPopoverView(originalText: "You should refactor this code using the factory pattern to improve testability.")
}
