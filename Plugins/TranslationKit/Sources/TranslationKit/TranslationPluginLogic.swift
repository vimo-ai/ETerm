//
//  TranslationPluginLogic.swift
//  TranslationKit
//
//  翻译插件逻辑层 - Extension Host 进程入口
//
//  职责：
//  - 处理选词事件，执行翻译业务流程
//  - 调用宿主核心服务（AI/词典）
//  - 向 ViewModel 推送状态更新

import Foundation
import ETermKit

/// 翻译插件逻辑层
@objc public final class TranslationPluginLogic: NSObject, PluginLogic, @unchecked Sendable {

    // MARK: - PluginLogic

    public static let id = "com.eterm.translation"

    private var host: HostBridge?
    private var configManager: TranslationConfigManager?

    /// 当前翻译任务（用于取消旧任务）
    private var currentTask: Task<Void, Never>?

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host
        self.configManager = TranslationConfigManager()

        // 发送初始状态
        sendInitialState()

        // 注册服务
        registerServices()

        print("[TranslationPluginLogic] Activated")
    }

    public func deactivate() {
        currentTask?.cancel()
        currentTask = nil
        host = nil
        configManager = nil
        print("[TranslationPluginLogic] Deactivated")
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "terminal.didEndSelection":
            handleSelection(payload: payload)

        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "translation.show":
            host?.showInfoPanel("translation")

        case "translation.hide":
            host?.hideInfoPanel("translation")
            host?.hideBubble()

        case "translation.toggle":
            // 切换翻译模式（由宿主处理 UI 状态）
            host?.emit(eventName: "plugin.translation.toggle", payload: [:])

        default:
            break
        }
    }

    // MARK: - Selection Handling

    private func handleSelection(payload: [String: Any]) {
        guard let text = payload["text"] as? String else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // 取消之前的任务
        currentTask?.cancel()

        // 显示加载状态
        updateViewState(
            originalText: trimmedText,
            contentType: "loading",
            content: [:]
        )

        // 启动新的翻译任务
        currentTask = Task { [weak self] in
            await self?.performTranslation(text: trimmedText)
        }
    }

    // MARK: - Translation Logic

    private func performTranslation(text: String) async {
        guard let host = host, let config = configManager?.config else { return }

        let isSingleWord = checkIsSingleWord(text)

        if isSingleWord {
            await translateWord(text: text, config: config, host: host)
        } else {
            await translateSentence(text: text, config: config, host: host)
        }
    }

    /// 单词翻译：词典查询 → 降级 AI 翻译
    private func translateWord(text: String, config: TranslationConfig, host: HostBridge) async {
        // 先尝试词典查询
        let dictionaryResult = host.callService(
            pluginId: "eterm",
            name: "dictionary.lookup",
            params: ["word": text]
        )

        if let result = dictionaryResult,
           let success = result["success"] as? Bool, success {
            // 词典查询成功
            updateViewState(
                originalText: text,
                contentType: "dictionary",
                content: result,
                modelTag: "词典"
            )

            // 异步加载释义翻译
            await loadDefinitionTranslations(
                dictionaryResult: result,
                originalText: text,
                config: config,
                host: host
            )
        } else {
            // 词典查询失败，降级到 AI 翻译
            await fallbackToAITranslation(text: text, config: config, host: host)
        }
    }

    /// 句子翻译：AI 句子分析
    private func translateSentence(text: String, config: TranslationConfig, host: HostBridge) async {
        let result = host.callService(
            pluginId: "eterm",
            name: "ai.analyzeSentence",
            params: [
                "text": text,
                "model": config.analysisModel
            ]
        )

        if let result = result,
           let success = result["success"] as? Bool, success {
            let translation = result["translation"] as? String ?? ""
            let grammar = result["grammar"] as? String ?? ""

            updateViewState(
                originalText: text,
                contentType: "analysis",
                content: [
                    "translation": translation,
                    "grammar": grammar
                ],
                modelTag: config.analysisModel
            )
        } else {
            // 句子分析失败，降级到普通翻译
            await fallbackToAITranslation(text: text, config: config, host: host)
        }
    }

    /// 降级到 AI 翻译
    private func fallbackToAITranslation(text: String, config: TranslationConfig, host: HostBridge) async {
        let result = host.callService(
            pluginId: "eterm",
            name: "ai.translate",
            params: [
                "text": text,
                "model": config.translationModel
            ]
        )

        if let result = result,
           let success = result["success"] as? Bool, success,
           let translated = result["result"] as? String {
            updateViewState(
                originalText: text,
                contentType: "translation",
                content: ["text": translated],
                modelTag: config.translationModel
            )
        } else {
            let error = result?["error"] as? String ?? "翻译失败"
            updateViewState(
                originalText: text,
                contentType: "error",
                content: ["message": error]
            )
        }
    }

    /// 加载词典释义的翻译
    private func loadDefinitionTranslations(
        dictionaryResult: [String: Any],
        originalText: String,
        config: TranslationConfig,
        host: HostBridge
    ) async {
        // 先翻译单词本身
        let wordTransResult = host.callService(
            pluginId: "eterm",
            name: "ai.translate",
            params: ["text": originalText, "model": config.translationModel]
        )
        let wordTranslation = (wordTransResult?["result"] as? String) ?? ""

        // 收集需要翻译的释义
        guard let meanings = dictionaryResult["meanings"] as? [[String: Any]] else { return }

        var definitionsToTranslate: [(definition: String, example: String?)] = []
        for meaning in meanings {
            guard let definitions = meaning["definitions"] as? [[String: Any]] else { continue }
            for def in definitions.prefix(3) {
                let definition = def["definition"] as? String ?? ""
                let example = def["example"] as? String
                definitionsToTranslate.append((definition, example))
            }
        }

        // 翻译每个释义
        var translations: [[String: Any]] = []
        for item in definitionsToTranslate {
            let defResult = host.callService(
                pluginId: "eterm",
                name: "ai.translate",
                params: ["text": item.definition, "model": config.translationModel]
            )
            let translatedDef = (defResult?["result"] as? String) ?? ""

            var translatedExample: String? = nil
            if let example = item.example {
                let exResult = host.callService(
                    pluginId: "eterm",
                    name: "ai.translate",
                    params: ["text": example, "model": config.translationModel]
                )
                translatedExample = exResult?["result"] as? String
            }

            var trans: [String: Any] = ["definition": translatedDef]
            if let ex = translatedExample {
                trans["example"] = ex
            }
            translations.append(trans)

            // 每翻译一个就更新一次 UI
            var updatedContent = dictionaryResult
            updatedContent["wordTranslation"] = wordTranslation
            updatedContent["translations"] = translations
            updateViewState(
                originalText: originalText,
                contentType: "dictionary",
                content: updatedContent,
                modelTag: config.translationModel
            )
        }
    }

    // MARK: - State Updates

    private func sendInitialState() {
        guard let config = configManager?.config else { return }

        host?.updateViewModel(Self.id, data: [
            "contentType": "idle",
            "config": [
                "dispatcherModel": config.dispatcherModel,
                "analysisModel": config.analysisModel,
                "translationModel": config.translationModel
            ]
        ])
    }

    private func updateViewState(
        originalText: String,
        contentType: String,
        content: [String: Any],
        modelTag: String? = nil
    ) {
        var data: [String: Any] = [
            "originalText": originalText,
            "contentType": contentType,
            "content": content
        ]
        if let tag = modelTag {
            data["modelTag"] = tag
        }

        host?.updateViewModel(Self.id, data: data)
    }

    // MARK: - Helpers

    private func checkIsSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 不含空格且全是字母
        return !trimmed.contains(" ") &&
               trimmed.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil
    }

    // MARK: - Services

    private func registerServices() {
        // 获取配置服务
        host?.registerService(name: "getConfig") { [weak self] _ in
            guard let config = self?.configManager?.config else { return nil }
            return [
                "dispatcherModel": config.dispatcherModel,
                "analysisModel": config.analysisModel,
                "translationModel": config.translationModel
            ]
        }

        // 更新配置服务
        host?.registerService(name: "updateConfig") { [weak self] params in
            guard let dispatcherModel = params["dispatcherModel"] as? String,
                  let analysisModel = params["analysisModel"] as? String,
                  let translationModel = params["translationModel"] as? String else {
                return ["success": false, "error": "Invalid parameters"]
            }

            self?.configManager?.updateConfig(
                dispatcherModel: dispatcherModel,
                analysisModel: analysisModel,
                translationModel: translationModel
            )
            self?.sendInitialState()

            return ["success": true]
        }

        // 翻译服务（供其他插件调用）
        host?.registerService(name: "translate") { [weak self] params in
            guard let text = params["text"] as? String,
                  let host = self?.host,
                  let config = self?.configManager?.config else {
                return ["success": false, "error": "Invalid parameters"]
            }

            return host.callService(
                pluginId: "eterm",
                name: "ai.translate",
                params: ["text": text, "model": config.translationModel]
            )
        }
    }
}
