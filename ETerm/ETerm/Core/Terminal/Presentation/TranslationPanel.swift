//
//  TranslationPanel.swift
//  ETerm
//
//  选词翻译功能
//  - Hint: 使用 NSPopover 显示 ✨ 按钮
//  - 翻译窗口: 使用独立 NSPanel，可拖拽，手动关闭
//

import SwiftUI
import AppKit
import Combine

// MARK: - Translation Mode Notifications

extension NSNotification.Name {
    /// 翻译模式状态已改变（由主程序发送，value: Bool）
    static let translationModeDidChange = NSNotification.Name("ETerm.TranslationModeDidChange")
    /// 请求切换翻译模式（由插件发送）
    static let translationModeToggleRequest = NSNotification.Name("ETerm.TranslationModeToggleRequest")
}

// MARK: - Translation Mode

@MainActor
final class TranslationModeStore: ObservableObject {
    static let shared = TranslationModeStore()

    @Published var isEnabled: Bool = false {
        didSet {
            // 状态改变时发送通知，让插件同步
            NotificationCenter.default.post(
                name: .translationModeDidChange,
                object: nil,
                userInfo: ["isEnabled": isEnabled]
            )
        }
    }

    var statusText: String {
        isEnabled ? "翻译模式：开" : "翻译模式：关"
    }

    private init() {
        // 监听来自插件的 toggle 请求
        NotificationCenter.default.addObserver(
            forName: .translationModeToggleRequest,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggle()
            }
        }
    }

    func toggle() {
        isEnabled.toggle()
    }
}

// MARK: - Translation Controller

/// 翻译功能控制器（单例）
/// 协调 hint popover 和翻译窗口
final class TranslationController: NSObject {

    // MARK: - Singleton

    static let shared = TranslationController()

    // MARK: - Properties

    /// 气泡状态
    let state = BubbleState()

    /// Hint Popover（显示 ✨）
    private lazy var hintPopover: NSPopover = {
        let p = NSPopover()
        p.behavior = .semitransient
        p.animates = true
        p.contentSize = NSSize(width: 50, height: 50)
        return p
    }()

    /// 来源视图
    private weak var sourceView: NSView?
    private var sourceRect: NSRect = .zero

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private override init() {
        super.init()
        setupHintContent()
        setupObservers()
    }

    private func setupHintContent() {
        let hintView = HintButtonView { [weak self] in
            self?.onHintClicked()
        }
        hintPopover.contentViewController = NSHostingController(rootView: hintView)
    }

    private func setupObservers() {
        state.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.handleModeChange(mode)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// 显示 hint
    func show(text: String, at rect: NSRect, in view: NSView) {
        sourceView = view
        sourceRect = rect

        if state.mode == .hidden {
            state.show(text: text, at: .zero)
        } else if state.mode == .hint {
            // 已经显示 hint，更新文本
            state.updateText(text)
        } else {
            // expanded 模式，更新内容
            state.updateText(text)
        }
    }

    /// 直接展开并翻译（用于翻译模式自动触发）
    func translateImmediately(text: String, at rect: NSRect, in view: NSView) {
        show(text: text, at: rect, in: view)
        state.expand()
    }

    /// 隐藏所有
    func hide() {
        state.hide()
    }

    // MARK: - Mode Handling

    private func handleModeChange(_ mode: BubbleState.Mode) {
        switch mode {
        case .hidden:
            hintPopover.performClose(nil)
            InfoWindowRegistry.shared.hideContent(id: "translation")

        case .hint:
            // 显示 hint popover
            InfoWindowRegistry.shared.hideContent(id: "translation")
            showHintPopover()

        case .expanded:
            // 关闭 hint，显示翻译窗口
            hintPopover.performClose(nil)
            showTranslationWindow()
        }
    }

    private func showHintPopover() {
        guard let view = sourceView else { return }
        if !hintPopover.isShown {
            hintPopover.show(relativeTo: sourceRect, of: view, preferredEdge: .maxY)
        }
    }

    private func showTranslationWindow() {
        InfoWindowRegistry.shared.showContent(id: "translation")
    }

    // MARK: - Actions

    private func onHintClicked() {
        state.expand()
    }
}

// MARK: - Hint Button View

struct HintButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Translation Content View

struct TranslationContentView: View {
    @ObservedObject var state: BubbleState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            Divider()
            contentView
            Spacer(minLength: 0)
            footerView
        }
        .padding(16)
        .frame(minWidth: 280, minHeight: 180)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top) {
            Text(state.originalText)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)

            Spacer()

            sourceTag
        }
    }

    @ViewBuilder
    private var sourceTag: some View {
        switch state.content {
        case .dictionary:
            TagView(text: "词典", color: .green)
        case .translation, .analysis:
            TagView(text: state.modelTag, color: .blue)
        default:
            EmptyView()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch state.content {
        case .idle:
            EmptyView()

        case .loading:
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("AI 思考中...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 30)

        case .dictionary(let word, let wordTranslation, let translations):
            DictionaryView(word: word, wordTranslation: wordTranslation, translations: translations)

        case .translation(let text):
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .analysis:
            AnalysisView(
                translation: state.analysisTranslation,
                grammar: state.analysisGrammar
            )

        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if state.audioURL != nil {
                Button(action: { state.playPronunciation() }) {
                    Label("发音", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if canCopy {
                Button(action: { state.copyContent() }) {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var canCopy: Bool {
        switch state.content {
        case .loading, .idle, .error:
            return false
        default:
            return true
        }
    }
}

// MARK: - Tag View

struct TagView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// MARK: - Dictionary View（左右分栏）

struct DictionaryView: View {
    let word: DictionaryWord
    let wordTranslation: String?
    let translations: [(String, String?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 单词中文翻译
            if let wordTrans = wordTranslation {
                HStack(spacing: 6) {
                    Text(word.word)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("→")
                        .foregroundColor(.secondary)
                    Text(wordTrans)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                .padding(.bottom, 4)
            }

            // 音标
            if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                Text(phonetic)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            // 左右分栏内容
            HStack(alignment: .top, spacing: 0) {
                // 左栏: 英文
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("English")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)

                        ForEach(Array(word.meanings.enumerated()), id: \.offset) { meaningIndex, meaning in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(meaning.partOfSpeech)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)

                                ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, definition in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .top, spacing: 4) {
                                            Text("\(defIndex + 1).")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(definition.definition)
                                                .font(.callout)
                                                .textSelection(.enabled)
                                        }

                                        if let example = definition.example {
                                            Text("e.g. \(example)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .italic()
                                                .padding(.leading, 14)
                                                .textSelection(.enabled)
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
                    .padding(.trailing, 8)
                }

                Divider()

                // 右栏: 中文
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("中文")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)

                        if translations.isEmpty {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("翻译中...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ForEach(Array(word.meanings.enumerated()), id: \.offset) { meaningIndex, meaning in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(translatePartOfSpeech(meaning.partOfSpeech))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)

                                    ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, _ in
                                        let flatIndex = getFlatIndex(meaningIndex: meaningIndex, defIndex: defIndex)
                                        if flatIndex < translations.count {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(alignment: .top, spacing: 4) {
                                                    Text("\(defIndex + 1).")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text(translations[flatIndex].0)
                                                        .font(.callout)
                                                        .foregroundColor(.green)
                                                        .textSelection(.enabled)
                                                }

                                                if let translatedExample = translations[flatIndex].1 {
                                                    Text("例: \(translatedExample)")
                                                        .font(.caption)
                                                        .foregroundColor(.green.opacity(0.8))
                                                        .italic()
                                                        .padding(.leading, 14)
                                                        .textSelection(.enabled)
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
                    .padding(.leading, 8)
                }
            }
        }
    }

    // 计算扁平化索引
    private func getFlatIndex(meaningIndex: Int, defIndex: Int) -> Int {
        var index = 0
        for i in 0..<meaningIndex {
            index += min(word.meanings[i].definitions.count, 3)
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

// MARK: - Analysis View

struct AnalysisView: View {
    let translation: String
    let grammar: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fontWeight(.semibold)

                    Text(translation)
                        .font(.body)
                        .textSelection(.enabled)
                }

                if !grammar.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("语法分析")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)

                        Text(grammar)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Type Aliases

typealias TranslationPopover = TranslationController

enum TranslationPanel {
    static var shared: TranslationController { TranslationController.shared }
}
