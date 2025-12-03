//
//  BubbleState.swift
//  ETerm
//
//  选词气泡状态管理
//  设计原则：状态即数据，业务逻辑内聚
//

import SwiftUI
import Combine
import AppKit
import SwiftData

@MainActor
class BubbleState: ObservableObject {

    // MARK: - 显示模式

    enum Mode {
        case hidden     // 隐藏
        case hint       // 悬浮提示图标
        case expanded   // 展开内容
    }

    // MARK: - 内容状态（状态即数据）

    enum Content {
        case idle
        case loading
        case dictionary(DictionaryWord, wordTranslation: String?, translations: [(String, String?)])  // 单词：词典数据 + 单词翻译 + 释义翻译
        case translation(String)                                            // 短语/句子：翻译结果
        case analysis                                                       // 句子分析（翻译 + 语法），具体内容单独存储以便流式更新
        case error(String)
    }

    // MARK: - Published Properties

    @Published var mode: Mode = .hidden
    @Published var originalText: String = ""
    @Published var position: CGPoint = .zero
    @Published var content: Content = .idle
    /// 当前使用的模型名，用于 UI 标签
    @Published var currentModelTag: String = ""
    /// 流式句子分析 - 翻译
    @Published var analysisTranslation: String = ""
    /// 流式句子分析 - 语法
    @Published var analysisGrammar: String = ""

    // MARK: - Computed Properties

    /// 判断是否为单词（纯字母无空格）
    var isSingleWord: Bool {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
               !trimmed.contains(" ") &&
               trimmed.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil
    }

    /// 获取发音 URL（仅词典模式）
    var audioURL: String? {
        guard case .dictionary(let word, _, _) = content else { return nil }
        return word.phonetics?.first(where: { $0.audio != nil && !$0.audio!.isEmpty })?.audio
    }

    // MARK: - Actions

    /// 显示气泡（hint 模式）
    func show(text: String, at position: CGPoint) {
        self.originalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.position = position
        self.content = .idle
        self.mode = .hint
    }

    /// 更新文本并重新加载（用于已展开状态下的新选词）
    func updateText(_ text: String) {
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 当翻译窗口已展开时，忽略单字符点击，避免误触触发新的翻译请求
        if mode == .expanded && newText.count == 1 {
            return
        }

        // 如果文本相同，不重复加载
        guard newText != originalText else { return }

        self.originalText = newText

        // 如果已展开，直接重新加载内容
        if mode == .expanded {
            Task {
                await loadContent()
            }
        } else {
            // 否则切换到 hint 模式
            self.content = .idle
            self.mode = .hint
        }
    }

    /// 隐藏气泡
    func hide() {
        withAnimation {
            mode = .hidden
        }
    }

    /// 展开并加载内容
    func expand() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            mode = .expanded
        }

        Task {
            await loadContent()
        }
    }

    /// 加载内容（核心业务逻辑）
    func loadContent() async {
        content = .loading
        currentModelTag = ""
        analysisTranslation = ""
        analysisGrammar = ""

        let text = originalText

        // 从插件配置读取模型
        let pluginConfig = TranslationPluginConfigManager.shared.config

        do {
            if isSingleWord {
                // 单词 → 优先词典，失败降级翻译
                do {
                    let word = try await DictionaryService.shared.lookup(text)
                    // 先显示英文词典内容（不带翻译）
                    content = .dictionary(word, wordTranslation: nil, translations: [])
                    currentModelTag = "词典"

                    // Save word to database
                    let phonetic = word.phonetic ?? word.phonetics?.first?.text
                    let definition = word.meanings.first?.definitions.first?.definition
                    saveToVocabulary(
                        word: text,
                        phonetic: phonetic,
                        definition: definition,
                        sourceContext: nil  // No context for dictionary lookup
                    )

                    // 异步加载单词翻译和释义翻译
                    Task {
                        await loadWordAndDefinitionTranslations(for: word)
                    }
                } catch DictionaryError.wordNotFound {
                    // 词典查不到（专有名词等），降级翻译
                    let result = try await AIService.shared.translate(text, model: pluginConfig.translationModel)
                    content = .translation(result)
                    currentModelTag = pluginConfig.translationModel
                }
            } else {
                // 句子/短语 → 句子分析（翻译 + 语法）
                var receivedStreaming = false
                var didShowAnalysis = false
                var finalTranslation = ""
                var finalGrammar = ""

                try await AIService.shared.analyzeSentence(text, model: pluginConfig.analysisModel) { trans, gram in
                    receivedStreaming = true
                    finalTranslation = trans
                    finalGrammar = gram

                    // 批量更新已在 AIService 层处理，此处直接更新 UI
                    withTransaction(Transaction(animation: nil)) {
                        self.analysisTranslation = trans
                        self.analysisGrammar = gram
                    }

                    // 首次收到内容时切换到分析模式，后续仅更新字符串，避免视图重建闪烁
                    if !didShowAnalysis {
                        self.content = .analysis
                        self.currentModelTag = pluginConfig.analysisModel
                        didShowAnalysis = true
                    }
                }

                // 最终结果
                if receivedStreaming, !analysisTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    withTransaction(Transaction(animation: nil)) {
                        self.analysisTranslation = finalTranslation
                        self.analysisGrammar = finalGrammar
                        content = .analysis
                    }
                    currentModelTag = pluginConfig.analysisModel

                    // 保存短语/句子到数据库（用于复合名词等）
                    saveToVocabulary(
                        word: text,
                        phonetic: nil,
                        definition: finalGrammar.isEmpty ? nil : finalGrammar,
                        translation: finalTranslation,
                        sourceContext: nil
                    )
                } else {
                    // 降级到普通翻译
                    let result = try await AIService.shared.translate(text, model: pluginConfig.translationModel)
                    content = .translation(result)
                    currentModelTag = pluginConfig.translationModel

                    // 保存翻译结果到数据库
                    saveToVocabulary(
                        word: text,
                        phonetic: nil,
                        definition: nil,
                        translation: result,
                        sourceContext: nil
                    )
                }
            }
        } catch {
            content = .error(error.localizedDescription)
        }
    }

    /// 播放发音
    func playPronunciation() {
        guard let url = audioURL else { return }
        DictionaryService.shared.playPronunciation(audioURL: url)
    }

    /// 加载单词翻译和释义翻译（私有方法）
    private func loadWordAndDefinitionTranslations(for word: DictionaryWord) async {
        // 从插件配置读取翻译模型
        let pluginConfig = TranslationPluginConfigManager.shared.config

        // 1. 先翻译单词本身
        let wordTranslation = try? await AIService.shared.translate(word.word, model: pluginConfig.translationModel)

        // 2. 收集所有需要翻译的释义和例句
        var definitionsToTranslate: [(String, String?)] = []
        for meaning in word.meanings {
            for definition in meaning.definitions.prefix(3) {
                definitionsToTranslate.append((definition.definition, definition.example))
            }
        }

        // 3. 并行翻译所有释义和例句
        var translations: [(String, String?)] = Array(repeating: ("", nil), count: definitionsToTranslate.count)

        await withTaskGroup(of: (Int, String, String?).self) { group in
            for (index, item) in definitionsToTranslate.enumerated() {
                group.addTask {
                    let def = try? await AIService.shared.translate(item.0, model: pluginConfig.translationModel)
                    let ex = item.1 != nil ? (try? await AIService.shared.translate(item.1!, model: pluginConfig.translationModel)) : nil
                    return (index, def ?? "", ex)
                }
            }

            for await (index, def, ex) in group {
                translations[index] = (def, ex)
                // 实时更新 UI（包含单词翻译）
                content = .dictionary(word, wordTranslation: wordTranslation, translations: translations)
                currentModelTag = pluginConfig.translationModel
            }
        }

        // Save Chinese translation after loading
        if let wordTranslation = wordTranslation, !wordTranslation.isEmpty {
            saveToVocabulary(
                word: word.word,
                phonetic: word.phonetic ?? word.phonetics?.first?.text,
                definition: word.meanings.first?.definitions.first?.definition,
                translation: wordTranslation,  // 保存单词的整体翻译
                sourceContext: nil
            )
        }
    }

    /// 复制内容到剪贴板
    func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch content {
        case .dictionary(let word, let wordTranslation, let translations):
            // 格式化词典内容（包含单词翻译和释义翻译）
            var text = "\(word.word)"
            if let wordTrans = wordTranslation {
                text += " - \(wordTrans)"
            }
            text += "\n"
            if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                text += "\(phonetic)\n"
            }
            text += "\n"

            var flatIndex = 0
            for meaning in word.meanings {
                text += "\(meaning.partOfSpeech):\n"
                for (index, def) in meaning.definitions.prefix(3).enumerated() {
                    text += "\(index + 1). \(def.definition)\n"
                    // 添加释义翻译
                    if flatIndex < translations.count {
                        text += "   译: \(translations[flatIndex].0)\n"
                    }
                    if let example = def.example {
                        text += "   例: \(example)\n"
                        // 添加例句翻译
                        if flatIndex < translations.count, let translatedExample = translations[flatIndex].1 {
                            text += "   译: \(translatedExample)\n"
                        }
                    }
                    flatIndex += 1
                }
                text += "\n"
            }
            pasteboard.setString(text, forType: .string)

        case .translation(let text):
            pasteboard.setString(text, forType: .string)

        case .analysis:
            let text = "翻译：\(analysisTranslation)\n\n语法分析：\(analysisGrammar)"
            pasteboard.setString(text, forType: .string)

        default:
            break
        }
    }

    /// 更新位置（拖拽后）
    func updatePosition(by offset: CGSize) {
        position = CGPoint(
            x: position.x + offset.width,
            y: position.y + offset.height
        )
    }

    // MARK: - Model tag for UI

    var modelTag: String {
        switch content {
        case .dictionary:
            return "词典"
        default:
            return currentModelTag
        }
    }

    // MARK: - Vocabulary Saving

    /// Save word to vocabulary database
    func saveToVocabulary(
        word: String,
        phonetic: String?,
        definition: String?,
        translation: String? = nil,
        sourceContext: String?
    ) {
        Task { @MainActor in
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
                  let modelContainer = appDelegate.modelContainer else {
                print("❌ ModelContainer not available")
                return
            }

            let modelContext = ModelContext(modelContainer)

            do {
                // Normalize word (lowercase)
                let normalizedWord = word.lowercased().trimmingCharacters(in: .whitespaces)

                // Check if word already exists
                let descriptor = FetchDescriptor<WordEntry>(
                    predicate: #Predicate { $0.word == normalizedWord }
                )

                if let existing = try modelContext.fetch(descriptor).first {
                    // Already exists, increment hit count
                    existing.recordQuery(context: sourceContext, definition: definition, translation: translation)
                    print("📚 Word already exists, Hit +1: \(word) (total: \(existing.hitCount) times)")
                } else {
                    // New word
                    let entry = WordEntry(
                        word: normalizedWord,
                        phonetic: phonetic,
                        context: sourceContext,
                        definition: definition,
                        translation: translation
                    )
                    modelContext.insert(entry)
                    print("📚 New word recorded: \(word)")
                }

                try modelContext.save()
            } catch {
                print("❌ Failed to save word: \(error)")
            }
        }
    }
}
