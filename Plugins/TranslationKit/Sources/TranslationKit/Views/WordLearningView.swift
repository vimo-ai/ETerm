//
//  WordLearningView.swift
//  TranslationKit
//
//  Created by 💻higuaifan on 2025/11/16.
//
//  [UNUSED] 从 ETerm/Features/Plugins/Learning 迁移而来，暂时无用
//

import SwiftUI

struct WordLearningView: View {
    @State private var inputText = ""
    @State private var wordData: DictionaryWord?
    @State private var translations: [(String, String?)] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("📖 Word Learning")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            // 输入区
            HStack {
                TextField("输入单词 (如: refactor)", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        lookup()
                    }

                Button(action: lookup) {
                    Label("查询", systemImage: "magnifyingglass")
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
                    Text("查询中...")
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
            } else if let word = wordData {
                ScrollView {
                    VStack(spacing: 16) {
                        // 单词 + 音标 + 发音
                        HStack {
                            Text(word.word)
                                .font(.system(size: 32, weight: .bold))

                            if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                                Text(phonetic)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if let audioURL = word.phonetics?.first(where: { $0.audio != nil && !$0.audio!.isEmpty })?.audio {
                                Button(action: {
                                    DictionaryService.shared.playPronunciation(audioURL: audioURL)
                                }) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.title2)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal)

                        Divider()

                        // 左右分栏内容
                        HStack(alignment: .top, spacing: 0) {
                            // 左栏: 英文
                            VStack(alignment: .leading, spacing: 12) {
                                Text("English")
                                    .font(.headline)
                                    .foregroundColor(.blue)

                                ForEach(Array(word.meanings.enumerated()), id: \.offset) { meaningIndex, meaning in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(meaning.partOfSpeech)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)

                                        ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, definition in
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(alignment: .top, spacing: 4) {
                                                    Text("\(defIndex + 1).")
                                                        .foregroundColor(.secondary)
                                                    Text(definition.definition)
                                                }
                                                .font(.body)

                                                if let example = definition.example {
                                                    Text("Example: \(example)")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .italic()
                                                        .padding(.leading, 16)
                                                }
                                            }
                                        }
                                    }

                                    if meaningIndex < word.meanings.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()

                            Divider()

                            // 右栏: 中文
                            VStack(alignment: .leading, spacing: 12) {
                                Text("中文")
                                    .font(.headline)
                                    .foregroundColor(.green)

                                if translations.isEmpty {
                                    Text("正在翻译...")
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(Array(word.meanings.enumerated()), id: \.offset) { meaningIndex, meaning in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(translatePartOfSpeech(meaning.partOfSpeech))
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.secondary)

                                            ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, _ in
                                                let flatIndex = getFlatIndex(meaningIndex: meaningIndex, defIndex: defIndex, meanings: word.meanings)
                                                if flatIndex < translations.count {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        HStack(alignment: .top, spacing: 4) {
                                                            Text("\(defIndex + 1).")
                                                                .foregroundColor(.secondary)
                                                            Text(translations[flatIndex].0)
                                                        }
                                                        .font(.body)

                                                        if let translatedExample = translations[flatIndex].1 {
                                                            Text("例句: \(translatedExample)")
                                                                .font(.caption)
                                                                .foregroundColor(.secondary)
                                                                .italic()
                                                                .padding(.leading, 16)
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        if meaningIndex < word.meanings.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("输入一个单词开始学习")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func lookup() {
        let word = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }

        isLoading = true
        error = nil
        wordData = nil
        translations = []

        Task {
            do {
                // 1. 查询字典
                let result = try await DictionaryService.shared.lookup(word)

                await MainActor.run {
                    wordData = result
                    isLoading = false
                }

                // 2. 翻译释义和例句
                var definitionsToTranslate: [(String, String?)] = []
                for meaning in result.meanings {
                    for definition in meaning.definitions.prefix(3) {
                        definitionsToTranslate.append((definition.definition, definition.example))
                    }
                }

                // 从插件配置读取翻译模型
                let pluginConfig = TranslationPluginConfigManager.shared.config
                let translated = try await AIService.shared.translateDictionaryContent(definitions: definitionsToTranslate, model: pluginConfig.translationModel)

                await MainActor.run {
                    translations = translated
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    // 计算扁平化索引
    private func getFlatIndex(meaningIndex: Int, defIndex: Int, meanings: [DictionaryWord.Meaning]) -> Int {
        var index = 0
        for i in 0..<meaningIndex {
            index += min(meanings[i].definitions.count, 3)
        }
        index += defIndex
        return index
    }

    // 翻译词性
    private func translatePartOfSpeech(_ pos: String) -> String {
        switch pos.lowercased() {
        case "noun": return "名词"
        case "verb": return "动词"
        case "adjective": return "形容词"
        case "adverb": return "副词"
        case "pronoun": return "代词"
        case "preposition": return "介词"
        case "conjunction": return "连词"
        case "interjection": return "感叹词"
        default: return pos
        }
    }
}

#Preview {
    WordLearningView()
        .frame(width: 900, height: 600)
}
