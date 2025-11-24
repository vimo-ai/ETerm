//
//  TranslationBubbleView.swift
//  ETerm
//
//  选词翻译气泡视图（纯展示组件）
//

import SwiftUI

struct TranslationBubbleView: View {
    @ObservedObject var state: BubbleState
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        if state.mode != .hidden {
            ZStack {
                switch state.mode {
                case .hidden:
                    EmptyView()

                case .hint:
                    hintButton

                case .expanded:
                    expandedBubble
                }
            }
            .offset(dragOffset)
            .position(state.position)
            .zIndex(100)
        }
    }

    // MARK: - Hint Button

    private var hintButton: some View {
        Button(action: { state.expand() }) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .padding(10)
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                )
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Expanded Bubble

    private var expandedBubble: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部：原文 + 关闭按钮
            headerView

            Divider()
                .background(Color.white.opacity(0.2))

            // 内容区
            contentView

            // 底部功能栏
            footerView
        }
        .padding(16)
        .frame(width: bubbleWidth)
        .background(bubbleBackground)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .contentShape(Rectangle())
        .onTapGesture { /* 拦截点击，防止穿透 */ }
        .gesture(dragGesture)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top) {
            Text(state.originalText)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundColor(.white)
                .lineLimit(2)

            Spacer()

            // 来源标识
            sourceTag

            Button(action: { state.hide() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    private var sourceTag: some View {
        Group {
            switch state.content {
            case .dictionary:
                Text("Dictionary")
                    .tagStyle(color: .green)
            case .translation, .analysis:
                Text("AI")
                    .tagStyle(color: .blue)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch state.content {
        case .idle:
            EmptyView()

        case .loading:
            loadingView

        case .dictionary(let word):
            DictionaryBubbleContent(word: word)

        case .translation(let text):
            TranslationBubbleContent(text: text)

        case .analysis(let translation, let grammar):
            AnalysisBubbleContent(translation: translation, grammar: grammar)

        case .error(let message):
            errorView(message: message)
        }
    }

    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("AI 思考中...")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // 发音按钮（仅词典模式且有音频时显示）
            if state.audioURL != nil {
                Button(action: { state.playPronunciation() }) {
                    Label("发音", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                }
            }

            Spacer()

            // 复制按钮
            if case .loading = state.content {
                // 加载中不显示
            } else if case .idle = state.content {
                // 空闲不显示
            } else if case .error = state.content {
                // 错误不显示
            } else {
                Button(action: { state.copyContent() }) {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }
        }
        .foregroundColor(.white.opacity(0.6))
        .padding(.top, 4)
    }

    // MARK: - Styling

    private var bubbleWidth: CGFloat {
        switch state.content {
        case .dictionary:
            return 380
        case .analysis:
            return 420
        default:
            return 340
        }
    }

    private var bubbleBackground: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    }

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .named("BubbleContainer"))
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                state.updatePosition(by: value.translation)
            }
    }
}

// MARK: - Content Components

/// 词典内容展示
struct DictionaryBubbleContent: View {
    let word: DictionaryWord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 音标
                if let phonetic = word.phonetic ?? word.phonetics?.first?.text {
                    Text(phonetic)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }

                // 各词性释义
                ForEach(Array(word.meanings.enumerated()), id: \.offset) { index, meaning in
                    VStack(alignment: .leading, spacing: 6) {
                        // 词性
                        Text(meaning.partOfSpeech)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue.opacity(0.8))

                        // 释义（最多显示3个）
                        ForEach(Array(meaning.definitions.prefix(3).enumerated()), id: \.offset) { defIndex, definition in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(defIndex + 1).")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.5))
                                    Text(definition.definition)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.9))
                                }

                                // 例句
                                if let example = definition.example {
                                    Text("→ \(example)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.6))
                                        .italic()
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }

                    if index < word.meanings.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }
}

/// 翻译内容展示
struct TranslationBubbleContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 句子分析内容展示
struct AnalysisBubbleContent: View {
    let translation: String
    let grammar: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 翻译
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundColor(.green.opacity(0.8))
                        .fontWeight(.semibold)

                    Text(translation)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                }

                // 语法分析
                if !grammar.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("语法分析")
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.8))
                            .fontWeight(.semibold)

                        Text(grammar)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }
}

// MARK: - Helper Extensions

extension Text {
    func tagStyle(color: Color) -> some View {
        self
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
            .padding(.trailing, 8)
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
