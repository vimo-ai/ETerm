//
//  AIService.swift
//  TranslationKit
//
//  AI 业务逻辑层 - 通过 HostBridge 调用主程序 AI 能力
//

import Foundation
import ETermKit

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

enum AIServiceError: LocalizedError {
    case missingClient
    case emptyResponse
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .missingClient:
            return "请先在设置中配置 API Key"
        case .emptyResponse:
            return "AI 返回了空响应，请稍后重试"
        case .invalidJSON:
            return "AI 响应格式异常，请稍后重试"
        }
    }
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

    private weak var host: HostBridge?

    private init() {}

    /// 设置 HostBridge（插件激活时调用）
    func configure(host: HostBridge) {
        self.host = host
    }

    // MARK: - Public APIs

    func translate(_ text: String, model: String) async throws -> String {
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
            model: model,
            system: "You are a concise translator. Only output translated text.",
            user: prompt,
            extraBody: ["translation_options": translationOptions]
        )
    }

    func translateDictionaryContent(definitions: [(definition: String, example: String?)], model: String) async throws -> [(translatedDefinition: String, translatedExample: String?)] {
        var results: [(String, String?)] = []

        for item in definitions {
            let def = try await translate(item.definition, model: model)
            var ex: String? = nil
            if let example = item.example {
                ex = try await translate(example, model: model)
            }
            results.append((def, ex))
        }

        return results
    }

    /// 句子分析（翻译 + 语法），流式更新
    func analyzeSentence(_ sentence: String, model: String, onUpdate: @escaping (String, String) -> Void) async throws {
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

        // 帧对齐批量更新，避免单字符更新导致的闪烁
        var lastSentTime: Date?
        let batchInterval: TimeInterval = 0.05  // 50ms 批量发送间隔

        try await streamText(
            model: model,
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

            // 批量更新策略：按时间间隔批量发送，避免逐字符闪烁
            let now = Date()
            let shouldSend: Bool
            if let last = lastSentTime {
                shouldSend = now.timeIntervalSince(last) >= batchInterval
            } else {
                shouldSend = true  // 首次立即发送
            }

            if shouldSend {
                onUpdate(cleanedTranslation, cleanedGrammar)
                lastSentTime = now
            }
        }

        // 流结束后，发送最终内容（确保最后一批数据不丢失）
        let finalTranslation = translationBuffer
            .replacingOccurrences(of: translationMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalGrammar = reachedGrammar ? grammarBuffer.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        onUpdate(finalTranslation, finalGrammar)
    }

    /// 写作检查，流式输出建议
    func checkWriting(_ text: String, model: String, onUpdate: @escaping (String) -> Void) async throws {
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
            model: model,
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
    func analyzeDispatcher(_ text: String, model: String, onReasoning: @escaping (String) -> Void) async throws -> AnalysisPlan {
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
            model: model,
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

    func performAnalysis(_ text: String, plan: AnalysisPlan, model: String) async throws -> AnalysisResult {
        var result = AnalysisResult()

        try await withThrowingTaskGroup(of: AnalysisTask?.self) { group in
            if plan.needFixes {
                group.addTask { try await .fixes(self.getFixes(text, model: model)) }
            }
            if plan.needIdiomatic {
                group.addTask { try await .idiomatic(self.getIdiomaticSuggestions(text, model: model)) }
            }
            if plan.needTranslation {
                group.addTask { try await self.translateChineseToEnglish(text, model: model) }
            }
            if plan.needExplanation {
                group.addTask { try await .explanation(self.getDetailedExplanation(text, model: model)) }
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

    func getDetailedExplanation(_ text: String, model: String) async throws -> [GrammarPoint] {
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
            model: model,
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

    private func getFixes(_ text: String, model: String) async throws -> [GrammarFix] {
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
            model: model,
            system: system,
            user: user
        )

        struct Wrapper: Decodable { let fixes: [GrammarFix] }

        guard let data = json.data(using: .utf8) else { throw AIServiceError.emptyResponse }
        return try JSONDecoder().decode(Wrapper.self, from: data).fixes
    }

    private func getIdiomaticSuggestions(_ text: String, model: String) async throws -> [IdiomaticSuggestion] {
        let system = "你是英语写作教练。提供更自然、地道的表达建议，中文解释原因。"
        let user = """
        文本：
        \(text)

        返回 JSON：
        { "suggestions": [ { "current": "...", "idiomatic": "...", "explanation": "..." } ] }
        """

        let json = try await chatText(
            model: model,
            system: system,
            user: user
        )

        struct Wrapper: Decodable { let suggestions: [IdiomaticSuggestion] }
        guard let data = json.data(using: .utf8) else { throw AIServiceError.emptyResponse }
        return try JSONDecoder().decode(Wrapper.self, from: data).suggestions
    }

    private func translateChineseToEnglish(_ text: String, model: String) async throws -> AnalysisTask {
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
            model: model,
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
        guard let host else { throw AIServiceError.missingClient }
        logDebug("[TranslationKit.AIService] chatText 调用, model=\(model)")

        // DashScope 的翻译模型（qwen-mt-flash）不接受 system 角色，只允许 user/assistant。
        // 检查模型名称包含 "mt" 来判断是否为翻译模型
        let finalSystem: String?
        let finalUser: String
        if model.contains("mt") {
            finalSystem = nil
            finalUser = [system, user].compactMap { $0 }.joined(separator: "\n\n")
        } else {
            finalSystem = system
            finalUser = user
        }

        let content = try await host.aiChat(
            model: model,
            system: finalSystem,
            user: finalUser,
            extraBody: extraBody
        )

        guard !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func streamText(model: String, system: String?, user: String, onChunk: @escaping (String) -> Void) async throws {
        guard let host else { throw AIServiceError.missingClient }

        try await host.aiStreamChat(
            model: model,
            system: system,
            user: user,
            onChunk: onChunk
        )
    }
}
