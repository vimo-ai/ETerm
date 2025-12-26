//
//  TranslationViewProvider.swift
//  TranslationKit
//
//  ViewProvider - 提供 SwiftUI View 给主进程

import Foundation
import SwiftUI
import ETermKit

// MARK: - ViewProvider

/// Translation ViewProvider
@objc(TranslationViewProvider)
public final class TranslationViewProvider: NSObject, PluginViewProvider {

    public required override init() {
        super.init()
    }

    @MainActor
    public func view(for tabId: String) -> AnyView {
        switch tabId {
        case "translation-settings":
            return AnyView(TranslationSettingsView())
        default:
            return AnyView(
                Text("Unknown tab: \(tabId)")
                    .foregroundColor(.secondary)
            )
        }
    }

    @MainActor
    public func createInfoPanelView(id: String) -> AnyView? {
        guard id == "translation" else { return nil }
        return AnyView(TranslationContentView())
    }

    @MainActor
    public func createBubbleContentView(id: String) -> AnyView? {
        guard id == "translation-bubble" else { return nil }
        return AnyView(TranslationContentView())
    }
}

// MARK: - Translation Content View

/// 翻译内容视图（InfoPanel 和 Bubble 共用）
struct TranslationContentView: View {
    @StateObject private var viewModel = TranslationViewState()

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
        .onAppear {
            viewModel.startListening()
        }
        .onDisappear {
            viewModel.stopListening()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack(alignment: .top) {
            Text(viewModel.originalText)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)

            Spacer()

            if let tag = viewModel.modelTag {
                TagView(text: tag, color: tag == "词典" ? .green : .blue)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.contentType {
        case "idle":
            EmptyView()

        case "loading":
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("AI 思考中...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 30)

        case "dictionary":
            DictionaryContentView(content: viewModel.content)

        case "translation":
            if let text = viewModel.content["text"] as? String {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case "analysis":
            AnalysisContentView(content: viewModel.content)

        case "error":
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(viewModel.content["message"] as? String ?? "发生错误")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)

        default:
            EmptyView()
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerView: some View {
        HStack {
            if let audioURL = viewModel.audioURL {
                Button(action: { playAudio(url: audioURL) }) {
                    Label("发音", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if viewModel.canCopy {
                Button(action: { copyContent() }) {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func playAudio(url: String) {
        // TODO: 通过宿主服务播放音频
    }

    private func copyContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch viewModel.contentType {
        case "translation":
            if let text = viewModel.content["text"] as? String {
                pasteboard.setString(text, forType: .string)
            }
        case "analysis":
            let translation = viewModel.content["translation"] as? String ?? ""
            let grammar = viewModel.content["grammar"] as? String ?? ""
            pasteboard.setString("翻译：\(translation)\n\n语法分析：\(grammar)", forType: .string)
        case "dictionary":
            // 简化复制词典内容
            pasteboard.setString(viewModel.originalText, forType: .string)
        default:
            break
        }
    }
}

// MARK: - Translation View State

/// 翻译视图状态（监听 ViewModel 更新）
@MainActor
final class TranslationViewState: ObservableObject {
    @Published var originalText: String = ""
    @Published var contentType: String = "idle"
    @Published var content: [String: Any] = [:]
    @Published var modelTag: String?

    private var observer: Any?

    var audioURL: String? {
        guard contentType == "dictionary",
              let phonetics = content["phonetics"] as? [[String: Any]] else {
            return nil
        }
        return phonetics.first(where: { ($0["audio"] as? String)?.isEmpty == false })?["audio"] as? String
    }

    var canCopy: Bool {
        contentType != "idle" && contentType != "loading" && contentType != "error"
    }

    nonisolated func startListening() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.UpdateViewModel"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // 在闭包内提取数据
            guard let userInfo = notification.userInfo,
                  let pluginId = userInfo["pluginId"] as? String,
                  pluginId == "com.eterm.translation",
                  let data = userInfo["data"] as? [String: Any] else {
                return
            }

            // 提取原始值
            let originalText = data["originalText"] as? String
            let contentType = data["contentType"] as? String
            let modelTag = data["modelTag"] as? String

            // 将 content 字典序列化为 JSON Data（Sendable）
            var contentData: Data?
            if let content = data["content"] as? [String: Any] {
                contentData = try? JSONSerialization.data(withJSONObject: content)
            }

            // 在 MainActor 上更新状态
            Task { @MainActor [weak self] in
                self?.applyUpdate(
                    originalText: originalText,
                    contentType: contentType,
                    contentData: contentData,
                    modelTag: modelTag
                )
            }
        }
        Task { @MainActor [weak self] in
            self?.observer = observer
        }
    }

    func stopListening() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func applyUpdate(
        originalText: String?,
        contentType: String?,
        contentData: Data?,
        modelTag: String?
    ) {
        if let text = originalText {
            self.originalText = text
        }
        if let type = contentType {
            self.contentType = type
        }
        if let data = contentData,
           let content = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.content = content
        }
        self.modelTag = modelTag
    }
}

// MARK: - Dictionary Content View

private struct DictionaryContentView: View {
    let content: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 单词翻译
            if let wordTranslation = content["wordTranslation"] as? String, !wordTranslation.isEmpty {
                HStack(spacing: 6) {
                    if let word = content["word"] as? String {
                        Text(word)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    Text("→")
                        .foregroundColor(.secondary)
                    Text(wordTranslation)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                .padding(.bottom, 4)
            }

            // 音标
            if let phonetic = content["phonetic"] as? String {
                Text(phonetic)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            // 释义
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let meanings = content["meanings"] as? [[String: Any]] {
                        let translations = content["translations"] as? [[String: Any]] ?? []
                        var flatIndex = 0

                        ForEach(Array(meanings.enumerated()), id: \.offset) { meaningIndex, meaning in
                            VStack(alignment: .leading, spacing: 8) {
                                if let pos = meaning["partOfSpeech"] as? String {
                                    Text(translatePartOfSpeech(pos))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                }

                                if let definitions = meaning["definitions"] as? [[String: Any]] {
                                    ForEach(Array(definitions.prefix(3).enumerated()), id: \.offset) { defIndex, def in
                                        let currentIndex = getFlatIndex(meanings: meanings, meaningIndex: meaningIndex, defIndex: defIndex)
                                        DefinitionRow(
                                            index: defIndex + 1,
                                            definition: def,
                                            translation: currentIndex < translations.count ? translations[currentIndex] : nil
                                        )
                                    }
                                }
                            }

                            if meaningIndex < meanings.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

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

    private func getFlatIndex(meanings: [[String: Any]], meaningIndex: Int, defIndex: Int) -> Int {
        var index = 0
        for i in 0..<meaningIndex {
            if let defs = meanings[i]["definitions"] as? [[String: Any]] {
                index += min(defs.count, 3)
            }
        }
        return index + defIndex
    }
}

// MARK: - Definition Row

private struct DefinitionRow: View {
    let index: Int
    let definition: [String: Any]
    let translation: [String: Any]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 英文释义
            HStack(alignment: .top, spacing: 4) {
                Text("\(index).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(definition["definition"] as? String ?? "")
                    .font(.callout)
                    .textSelection(.enabled)
            }

            // 中文释义翻译
            if let translatedDef = translation?["definition"] as? String, !translatedDef.isEmpty {
                Text(translatedDef)
                    .font(.callout)
                    .foregroundColor(.green)
                    .padding(.leading, 14)
            }

            // 英文例句
            if let example = definition["example"] as? String {
                Text("e.g. \(example)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 14)
                    .textSelection(.enabled)

                // 中文例句翻译
                if let translatedEx = translation?["example"] as? String, !translatedEx.isEmpty {
                    Text("例: \(translatedEx)")
                        .font(.caption)
                        .foregroundColor(.green.opacity(0.8))
                        .italic()
                        .padding(.leading, 14)
                }
            }
        }
    }
}

// MARK: - Analysis Content View

private struct AnalysisContentView: View {
    let content: [String: Any]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fontWeight(.semibold)

                    Text(content["translation"] as? String ?? "")
                        .font(.body)
                        .textSelection(.enabled)
                }

                if let grammar = content["grammar"] as? String, !grammar.isEmpty {
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

// MARK: - Tag View

private struct TagView: View {
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

// MARK: - Translation Settings View

struct TranslationSettingsView: View {
    @StateObject private var viewModel = TranslationSettingsState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("翻译插件配置")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSectionView(title: "模型配置") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("配置翻译插件使用的 AI 模型")
                                .font(.callout)
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 12) {
                                ModelConfigField(
                                    label: "调度模型",
                                    model: $viewModel.dispatcherModel,
                                    placeholder: "qwen-flash",
                                    description: "用于判断文本需要的分析类型"
                                )

                                ModelConfigField(
                                    label: "分析模型",
                                    model: $viewModel.analysisModel,
                                    placeholder: "qwen3-max",
                                    description: "用于深度语法和语义分析"
                                )

                                ModelConfigField(
                                    label: "翻译模型",
                                    model: $viewModel.translationModel,
                                    placeholder: "qwen-mt-flash",
                                    description: "用于文本翻译"
                                )
                            }

                            Divider()

                            HStack(spacing: 12) {
                                Button("重置为默认") {
                                    viewModel.resetToDefault()
                                }
                                .foregroundColor(.orange)

                                Spacer()

                                Button("保存") {
                                    viewModel.saveConfig()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!viewModel.isFormValid)
                            }

                            if viewModel.showSaveResult {
                                HStack {
                                    Image(systemName: viewModel.saveSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(viewModel.saveSuccess ? .green : .red)
                                    Text(viewModel.saveMessage)
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(viewModel.saveSuccess ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                                )
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            viewModel.loadConfig()
        }
    }
}

// MARK: - Settings State

@MainActor
final class TranslationSettingsState: ObservableObject {
    @Published var dispatcherModel: String = ""
    @Published var analysisModel: String = ""
    @Published var translationModel: String = ""
    @Published var showSaveResult = false
    @Published var saveSuccess = false
    @Published var saveMessage = ""

    private let configFilePath: String

    var isFormValid: Bool {
        !dispatcherModel.isEmpty && !analysisModel.isEmpty && !translationModel.isEmpty
    }

    init() {
        let home = NSHomeDirectory()
        configFilePath = "\(home)/.eterm/plugins/Translation/config.json"
    }

    func loadConfig() {
        guard FileManager.default.fileExists(atPath: configFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configFilePath)),
              let config = try? JSONDecoder().decode(TranslationConfig.self, from: data) else {
            let defaultConfig = TranslationConfig.default
            dispatcherModel = defaultConfig.dispatcherModel
            analysisModel = defaultConfig.analysisModel
            translationModel = defaultConfig.translationModel
            return
        }

        dispatcherModel = config.dispatcherModel
        analysisModel = config.analysisModel
        translationModel = config.translationModel
    }

    func saveConfig() {
        do {
            let parentDir = (configFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            let config = TranslationConfig(
                dispatcherModel: dispatcherModel,
                analysisModel: analysisModel,
                translationModel: translationModel
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath))

            saveSuccess = true
            saveMessage = "配置已保存"
        } catch {
            saveSuccess = false
            saveMessage = "保存失败: \(error.localizedDescription)"
        }

        showSaveResult = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showSaveResult = false
        }
    }

    func resetToDefault() {
        let defaultConfig = TranslationConfig.default
        dispatcherModel = defaultConfig.dispatcherModel
        analysisModel = defaultConfig.analysisModel
        translationModel = defaultConfig.translationModel
    }
}

// MARK: - Subviews

private struct SettingsSectionView<Content: View>: View {
    let title: String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content()
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
        }
    }
}

private struct ModelConfigField: View {
    let label: String
    @Binding var model: String
    let placeholder: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(width: 80, alignment: .leading)

                TextField(placeholder, text: $model)
                    .textFieldStyle(.roundedBorder)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 80)
        }
    }
}
