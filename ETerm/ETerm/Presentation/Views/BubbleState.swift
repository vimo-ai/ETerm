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
        case dictionary(DictionaryWord, translations: [(String, String?)])  // 单词：词典数据 + 中文翻译
        case translation(String)                                            // 短语/句子：翻译结果
        case analysis(translation: String, grammar: String)                 // 句子分析（翻译 + 语法）
        case error(String)
    }

    // MARK: - Published Properties

    @Published var mode: Mode = .hidden
    @Published var originalText: String = ""
    @Published var position: CGPoint = .zero
    @Published var content: Content = .idle

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
        guard case .dictionary(let word, _) = content else { return nil }
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

        let text = originalText

        do {
            if isSingleWord {
                // 单词 → 优先词典，失败降级翻译
                do {
                    let word = try await DictionaryService.shared.lookup(text)
                    // 先显示英文词典内容
                    content = .dictionary(word, translations: [])

                    // 异步加载中文翻译
                    Task {
                        await loadTranslations(for: word)
                    }
                } catch DictionaryError.wordNotFound {
                    // 词典查不到（专有名词等），降级翻译
                    let result = try await OllamaService.shared.translate(text)
                    content = .translation(result)
                }
            } else {
                // 句子/短语 → 句子分析（翻译 + 语法）
                var translation = ""
                var grammar = ""

                try await OllamaService.shared.analyzeSentence(text) { trans, gram in
                    translation = trans
                    grammar = gram
                    // 流式更新 UI
                    self.content = .analysis(translation: translation, grammar: grammar)
                }

                // 最终结果
                if !translation.isEmpty {
                    content = .analysis(translation: translation, grammar: grammar)
                } else {
                    // 降级到普通翻译
                    let result = try await OllamaService.shared.translate(text)
                    content = .translation(result)
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

    /// 加载词典翻译（私有方法）
    private func loadTranslations(for word: DictionaryWord) async {
        // 收集所有需要翻译的释义和例句
        var definitionsToTranslate: [(String, String?)] = []
        for meaning in word.meanings {
            for definition in meaning.definitions.prefix(3) {
                definitionsToTranslate.append((definition.definition, definition.example))
            }
        }

        do {
            let translations = try await OllamaService.shared.translateDictionaryContent(definitions: definitionsToTranslate)

            // 更新内容（保持当前 word，添加翻译）
            content = .dictionary(word, translations: translations)
        } catch {
            // 翻译失败时，保持英文内容不变
            print("翻译失败: \(error.localizedDescription)")
        }
    }

    /// 复制内容到剪贴板
    func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch content {
        case .dictionary(let word, let translations):
            // 格式化词典内容（包含中文翻译）
            var text = "\(word.word)\n"
            if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                text += "\(phonetic)\n"
            }
            text += "\n"

            var flatIndex = 0
            for meaning in word.meanings {
                text += "\(meaning.partOfSpeech):\n"
                for (index, def) in meaning.definitions.prefix(3).enumerated() {
                    text += "\(index + 1). \(def.definition)\n"
                    // 添加中文翻译
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

        case .analysis(let translation, let grammar):
            let text = "翻译：\(translation)\n\n语法分析：\(grammar)"
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
}
