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

    /// 翻译内容窗口
    private lazy var translationWindow: TranslationWindow = {
        TranslationWindow(state: state)
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

    /// 隐藏所有
    func hide() {
        state.hide()
    }

    // MARK: - Mode Handling

    private func handleModeChange(_ mode: BubbleState.Mode) {
        switch mode {
        case .hidden:
            hintPopover.performClose(nil)
            translationWindow.orderOut(nil)

        case .hint:
            // 显示 hint popover
            translationWindow.orderOut(nil)
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
        // 计算窗口位置（基于来源视图）
        if let view = sourceView, let window = view.window {
            let viewPoint = NSPoint(
                x: sourceRect.midX,
                y: sourceRect.maxY + 10
            )
            let windowPoint = view.convert(viewPoint, to: nil)
            let screenPoint = window.convertPoint(toScreen: windowPoint)

            translationWindow.positionNear(screenPoint: screenPoint)
        }

        translationWindow.orderFront(nil)
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

// MARK: - Translation Window

/// 独立翻译窗口
final class TranslationWindow: NSPanel {

    private let bubbleState: BubbleState
    private var hostingView: NSHostingView<TranslationContentView>?

    init(state: BubbleState) {
        self.bubbleState = state

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 350),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        setupWindow()
        setupContent()
    }

    private func setupWindow() {
        title = "翻译"
        level = .floating
        isOpaque = false
        backgroundColor = NSColor.windowBackgroundColor

        // 允许在所有 Space 显示
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 点击时不抢焦点
        becomesKeyOnlyIfNeeded = true

        // 关闭时隐藏而不是释放
        isReleasedWhenClosed = false

        // 最小尺寸
        minSize = NSSize(width: 300, height: 200)
    }

    private func setupContent() {
        let content = TranslationContentView(state: bubbleState)
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
        self.hostingView = hosting
    }

    /// 定位到屏幕坐标附近
    func positionNear(screenPoint: NSPoint) {
        let size = frame.size
        var origin = NSPoint(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y
        )

        // 边界检查
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame

            if origin.x + size.width > screenFrame.maxX {
                origin.x = screenFrame.maxX - size.width - 10
            }
            if origin.x < screenFrame.minX {
                origin.x = screenFrame.minX + 10
            }
            if origin.y + size.height > screenFrame.maxY {
                origin.y = screenPoint.y - size.height - 30
            }
            if origin.y < screenFrame.minY {
                origin.y = screenFrame.minY + 10
            }
        }

        setFrameOrigin(origin)
    }

    // 关闭时同步状态
    override func close() {
        bubbleState.hide()
        super.close()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
            TagView(text: "AI", color: .blue)
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

        case .dictionary(let word):
            DictionaryView(word: word)

        case .translation(let text):
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .analysis(let translation, let grammar):
            AnalysisView(translation: translation, grammar: grammar)

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

// MARK: - Dictionary View

struct DictionaryView: View {
    let word: DictionaryWord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 音标
                if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                    Text(phonetic)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // 词义
                ForEach(Array(word.meanings.enumerated()), id: \.offset) { index, meaning in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meaning.partOfSpeech)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)

                        ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, definition in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(defIndex + 1).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(definition.definition)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }

                                if let example = definition.example {
                                    Text("→ \(example)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding(.leading, 16)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if index < word.meanings.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Legacy Aliases

/// 兼容旧 API
typealias TranslationPopover = TranslationController

enum TranslationPanel {
    static var shared: TranslationController { TranslationController.shared }
}
