//
//  AIService.swift
//  ETerm
//
//  Centralized AI caller for DashScope (OpenAI-compatible) with per-use-case models.
//

import Foundation

// MARK: - Shared data models

struct AnalysisPlan: Codable {
    let needGrammarCheck: Bool
    let needFixes: Bool
    let needIdiomatic: Bool
    let needTranslation: Bool
    let needExplanation: Bool
    let reasoning: String

    enum CodingKeys: String, CodingKey {
        case needGrammarCheck = "need_grammar_check"
        case needFixes = "need_fixes"
        case needIdiomatic = "need_idiomatic"
        case needTranslation = "need_translation"
        case needExplanation = "need_explanation"
        case reasoning
    }
}

struct GrammarFix: Codable {
    let original: String
    let corrected: String
    let errorType: String
    let category: String  // Grammar error category (English identifier)

    enum CodingKeys: String, CodingKey {
        case original
        case corrected
        case errorType = "error_type"
        case category
    }
}

struct IdiomaticSuggestion: Codable {
    let current: String
    let idiomatic: String
    let explanation: String
}

struct Translation: Codable {
    let chinese: String
    let english: String
}

struct GrammarPoint: Codable {
    let rule: String
    let explanation: String
    let examples: [String]
}

struct AnalysisResult: Codable {
    var fixes: [GrammarFix]?
    var idiomaticSuggestions: [IdiomaticSuggestion]?
    var pureEnglish: String?
    var translations: [Translation]?
    var grammarPoints: [GrammarPoint]?
}

enum AIServiceError: Error {
    case missingClient
    case emptyResponse
    case invalidJSON
}

private enum AnalysisTask {
    case fixes([GrammarFix])
    case idiomatic([IdiomaticSuggestion])
    case translation(String, [Translation])
    case explanation([GrammarPoint])
}

// MARK: - Service

final class AIService {
    static let shared = AIService()

    private var client: DashScopeClient?

    // Model routing - 从配置管理器读取
    private var dispatcherModel: String {
        AIConfigManager.shared.config.dispatcherModel
    }

    private var analysisModel: String {
        AIConfigManager.shared.config.analysisModel
    }

    private var translationModel: String {
        AIConfigManager.shared.config.translationModel
    }

    private init() {
        client = try? DashScopeClient(defaultModel: AIConfigManager.shared.config.analysisModel)
    }

    /// 重新初始化客户端（配置变更后调用）
    func reinitializeClient() {
        client = try? DashScopeClient(defaultModel: AIConfigManager.shared.config.analysisModel)
    }

    // MARK: - Public APIs

    func translate(_ text: String) async throws -> String {
        let prompt = """
        你是专业中英文互译助手。请只输出翻译结果，不要附加解释或格式。

        待翻译内容：
        \(text)
        """

        let translationOptions: [String: Any] = [
            "source_lang": "auto",
            // 气泡翻译场景固定目标：中文
            "target_lang": "Chinese"
        ]

        return try await chatText(
            model: translationModel,
            system: "You are a concise translator. Only output translated text.",
            user: prompt,
            extraBody: ["translation_options": translationOptions]
        )
    }

    func translateDictionaryContent(definitions: [(definition: String, example: String?)]) async throws -> [(translatedDefinition: String, translatedExample: String?)] {
        var results: [(String, String?)] = []

        for item in definitions {
            let def = try await translate(item.definition)
            var ex: String? = nil
            if let example = item.example {
                ex = try await translate(example)
            }
            results.append((def, ex))
        }

        return results
    }

    /// 句子分析（翻译 + 语法），流式更新
    func analyzeSentence(_ sentence: String, onUpdate: @escaping (String, String) -> Void) async throws {
        let system = "你是英语老师，请提供翻译和语法分析。输出格式使用【翻译】和【语法分析】分段。"
        let user = """
        请分析以下英文句子：

        \(sentence)

        输出格式：
        【翻译】
        ...

        【语法分析】
        ...
        """

        // 增量解析，避免「【语法分析】」标记未完全到达时污染翻译文本导致闪烁
        let grammarMarker = "【语法分析】"
        let translationMarker = "【翻译】"
        var translationBuffer = ""
        var grammarBuffer = ""
        var reachedGrammar = false

        try await streamText(
            model: analysisModel,
            system: system,
            user: user
        ) { chunk in
            if reachedGrammar {
                grammarBuffer += chunk
            } else {
                translationBuffer += chunk
                if let range = translationBuffer.range(of: grammarMarker) {
                    // 标记前归翻译，标记后归语法，避免来回闪烁
                    let before = translationBuffer[..<range.lowerBound]
                    let after = translationBuffer[range.upperBound...]
                    translationBuffer = String(before)
                    grammarBuffer += after
                    reachedGrammar = true
                }
            }

            let cleanedTranslation = translationBuffer
                .replacingOccurrences(of: translationMarker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedGrammar = reachedGrammar ? grammarBuffer.trimmingCharacters(in: .whitespacesAndNewlines) : ""

            onUpdate(cleanedTranslation, cleanedGrammar)
        }
    }

    /// 写作检查，流式输出建议
    func checkWriting(_ text: String, onUpdate: @escaping (String) -> Void) async throws {
        let system = "你是一位英语写作教练，请逐步输出改进建议和修改示例，使用中文解释。"
        let user = """
        请检查以下文本（可能包含中英文混合），给出：
        1. 语法错误与修改
        2. 用词/表达建议（更地道）
        3. 如果有中文，请提供英文表达建议

        文本：
        \(text)
        """

        var full = ""
        try await streamText(
            model: analysisModel,
            system: system,
            user: user
        ) { chunk in
            full += chunk
            let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onUpdate(full)
            }
        }
    }

    /// Dispatcher：返回分析计划（不流式，直接解析 JSON）
    func analyzeDispatcher(_ text: String, onReasoning: @escaping (String) -> Void) async throws -> AnalysisPlan {
        let system = "You are a dispatcher. Analyze the text and output pure JSON with required booleans and reasoning."
        let user = """
        Analyze this text and decide which checks are needed. Return JSON object with keys:
        - need_grammar_check (boolean)
        - need_fixes (boolean)
        - need_idiomatic (boolean)
        - need_translation (boolean)
        - need_explanation (boolean, default false if unsure)
        - reasoning (string, concise)

        Text:
        \(text)
        """

        let response = try await chatText(
            model: dispatcherModel,
            system: system,
            user: user
        )

        guard let data = response.data(using: .utf8) else {
            throw AIServiceError.emptyResponse
        }
        let plan = try JSONDecoder().decode(AnalysisPlan.self, from: data)
        onReasoning(plan.reasoning)
        return plan
    }

    func performAnalysis(_ text: String, plan: AnalysisPlan) async throws -> AnalysisResult {
        var result = AnalysisResult()

        try await withThrowingTaskGroup(of: AnalysisTask?.self) { group in
            if plan.needFixes {
                group.addTask { try await .fixes(self.getFixes(text)) }
            }
            if plan.needIdiomatic {
                group.addTask { try await .idiomatic(self.getIdiomaticSuggestions(text)) }
            }
            if plan.needTranslation {
                group.addTask { try await self.translateChineseToEnglish(text) }
            }
            if plan.needExplanation {
                group.addTask { try await .explanation(self.getDetailedExplanation(text)) }
            }

            for try await task in group {
                guard let task else { continue }
                switch task {
                case .fixes(let fixes):
                    result.fixes = fixes
                case .idiomatic(let sug):
                    result.idiomaticSuggestions = sug
                case .translation(let pure, let trs):
                    result.pureEnglish = pure
                    result.translations = trs
                case .explanation(let points):
                    result.grammarPoints = points
                }
            }
        }

        return result
    }

    func getDetailedExplanation(_ text: String) async throws -> [GrammarPoint] {
        let system = "你是一位英语语法老师，请用中文给出重要语法点的条目化解释，严格 JSON。"
        let user = """
        文本：
        \(text)

        请返回 JSON:
        {
          "grammar_points": [
            { "rule": "...", "explanation": "...", "examples": ["...", "..."] }
          ]
        }
        """

        let json = try await chatText(
            model: analysisModel,
            system: system,
            user: user
        )

        guard let data = json.data(using: .utf8) else {
            throw AIServiceError.emptyResponse
        }

        struct Wrapper: Decodable { let grammar_points: [GrammarPoint] }
        return try JSONDecoder().decode(Wrapper.self, from: data).grammar_points
    }

    // MARK: - Private helpers

    private func getFixes(_ text: String) async throws -> [GrammarFix] {
        let system = """
        你是语法检查专家。请返回 JSON 格式的语法错误修正。

        分类规则（category 必须从以下选择一个）：
        - tense (时态)
        - article (冠词)
        - preposition (介词)
        - subject_verb_agreement (主谓一致)
        - word_order (词序)
        - singular_plural (单复数)
        - punctuation (标点)
        - spelling (拼写)
        - word_choice (用词)
        - sentence_structure (句子结构)
        - other (其他)
        """

        let user = """
        文本：
        \(text)

        返回 JSON：
        {
          "fixes": [
            {
              "original": "错误的文本片段",
              "corrected": "修正后的文本",
              "error_type": "错误类型的中文描述",
              "category": "分类标识（从上面列表选择，必须是英文）"
            }
          ]
        }

        如果没有语法错误，返回空数组：{"fixes": []}
        """

        let json = try await chatText(
            model: analysisModel,
            system: system,
            user: user
        )

        struct Wrapper: Decodable { let fixes: [GrammarFix] }

        guard let data = json.data(using: .utf8) else { throw AIServiceError.emptyResponse }
        return try JSONDecoder().decode(Wrapper.self, from: data).fixes
    }

    private func getIdiomaticSuggestions(_ text: String) async throws -> [IdiomaticSuggestion] {
        let system = "你是英语写作教练。提供更自然、地道的表达建议，中文解释原因。"
        let user = """
        文本：
        \(text)

        返回 JSON：
        { "suggestions": [ { "current": "...", "idiomatic": "...", "explanation": "..." } ] }
        """

        let json = try await chatText(
            model: analysisModel,
            system: system,
            user: user
        )

        struct Wrapper: Decodable { let suggestions: [IdiomaticSuggestion] }
        guard let data = json.data(using: .utf8) else { throw AIServiceError.emptyResponse }
        return try JSONDecoder().decode(Wrapper.self, from: data).suggestions
    }

    private func translateChineseToEnglish(_ text: String) async throws -> AnalysisTask {
        let system = "You are a translator. Convert Chinese parts to English and also give a mapping list. Only output JSON."
        let user = """
        Text:
        \(text)

        Return JSON:
        {
          "pure_english": "<full English text>",
          "translations": [ { "chinese": "...", "english": "..." } ]
        }
        """

        let json = try await chatText(
            model: analysisModel,
            system: system,
            user: user
        )

        struct Wrapper: Decodable {
            let pure_english: String
            let translations: [Translation]
        }

        guard let data = json.data(using: .utf8) else { throw AIServiceError.emptyResponse }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return .translation(wrapper.pure_english, wrapper.translations)
    }

    private func chatText(model: String, system: String?, user: String, temperature: Double? = nil, extraBody: [String: Any]? = nil) async throws -> String {
        guard let client else { throw AIServiceError.missingClient }

        var messages: [DashScopeMessage] = []

        // DashScope 的翻译模型（qwen-mt-flash）不接受 system 角色，只允许 user/assistant。
        if model == translationModel {
            let combined = [system, user].compactMap { $0 }.joined(separator: "\n\n")
            messages.append(DashScopeMessage(role: "user", content: combined))
        } else {
            if let system {
                messages.append(DashScopeMessage(role: "system", content: system))
            }
            messages.append(DashScopeMessage(role: "user", content: user))
        }

        let resp = try await client.chat(messages: messages, model: model, temperature: temperature, extraBody: extraBody)
        guard let content = resp.choices.first?.message.content, !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func streamText(model: String, system: String?, user: String, onChunk: @escaping (String) -> Void) async throws {
        guard let client else { throw AIServiceError.missingClient }

        var messages: [DashScopeMessage] = []
        if let system {
            messages.append(DashScopeMessage(role: "system", content: system))
        }
        messages.append(DashScopeMessage(role: "user", content: user))

        let handle = try client.streamChat(messages: messages, model: model)

        for try await chunk in handle.stream {
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                await MainActor.run {
                    onChunk(delta)
                }
            }
        }
    }
}
