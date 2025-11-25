//
//  OllamaService.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import Foundation

// MARK: - 数据结构定义

/// Stage 1: AI Dispatcher 返回的分析计划
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

/// 语法修复项
struct GrammarFix: Codable {
    let original: String
    let corrected: String
    let errorType: String

    enum CodingKeys: String, CodingKey {
        case original
        case corrected
        case errorType = "error_type"
    }
}

/// 地道化建议项
struct IdiomaticSuggestion: Codable {
    let current: String
    let idiomatic: String
    let explanation: String
}

/// 中英转换对
struct Translation: Codable {
    let chinese: String
    let english: String
}

/// 语法点详解
struct GrammarPoint: Codable {
    let rule: String
    let explanation: String
    let examples: [String]
}

/// Stage 2: 各个具体分析结果
struct AnalysisResult: Codable {
    var fixes: [GrammarFix]?
    var idiomaticSuggestions: [IdiomaticSuggestion]?
    var pureEnglish: String?
    var translations: [Translation]?
    var grammarPoints: [GrammarPoint]?
}

class OllamaService {
    static let shared = OllamaService()

    private let baseURL = "http://127.0.0.1:11434"
    private let model = "qwen3:8b"

    private init() {}

    // 通用请求方法（非流式）
    private func request(prompt: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 流式请求方法
    private func streamRequest(prompt: String, onChunk: @escaping (String) -> Void) async throws {
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chunk = json["response"] as? String else {
                continue
            }

            await MainActor.run {
                onChunk(chunk)
            }
        }
    }

    // 翻译文本
    func translate(_ text: String) async throws -> String {
        let prompt = """
        Translate the following English text to Chinese. Only output the translation, no explanation:

        \(text)
        """
        return try await request(prompt: prompt)
    }

    // 翻译词典释义和例句
    func translateDictionaryContent(definitions: [(definition: String, example: String?)]) async throws -> [(translatedDefinition: String, translatedExample: String?)] {
        var results: [(String, String?)] = []

        for item in definitions {
            let defPrompt = """
            Translate the following English definition to Chinese. Only output the translation:

            \(item.definition)
            """
            let translatedDef = try await request(prompt: defPrompt)

            var translatedEx: String? = nil
            if let example = item.example {
                let exPrompt = """
                Translate the following English sentence to Chinese. Only output the translation:

                \(example)
                """
                translatedEx = try await request(prompt: exPrompt)
            }

            results.append((translatedDef, translatedEx))
        }

        return results
    }

    // 分析句子: 翻译 + 语法解释（流式）
    func analyzeSentence(_ sentence: String, onUpdate: @escaping (String, String) -> Void) async throws {
        let prompt = """
        请分析以下英文句子：

        \(sentence)

        请提供：
        1. 中文翻译
        2. 语法结构分析（标注主谓宾、从句、时态、重要语法点等）

        请按以下格式输出：
        【翻译】
        ...

        【语法分析】
        ...
        """

        var fullResponse = ""

        try await streamRequest(prompt: prompt) { chunk in
            fullResponse += chunk

            // 实时解析并更新
            let components = fullResponse.components(separatedBy: "【语法分析】")
            let translation = components[0].replacingOccurrences(of: "【翻译】", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let grammar = components.count > 1 ? components[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

            onUpdate(translation, grammar)
        }
    }

    // 写作检查: 语法错误 + 建议（流式）
    func checkWriting(_ text: String, onUpdate: @escaping (String) -> Void) async throws {
        let prompt = """
        请检查以下文本（可能包含中英文混合）：

        \(text)

        请提供：
        1. 语法错误（如果有）
        2. 用词建议（是否地道、是否有更好的表达）
        3. 如果有中文词汇，请提供对应的英文表达建议

        请用清晰的格式输出，帮助用户改进英文写作。
        """

        var fullResponse = ""

        try await streamRequest(prompt: prompt) { chunk in
            fullResponse += chunk
            // 只有当累积内容非空时才触发更新
            let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onUpdate(fullResponse)
            }
        }
    }

    // MARK: - Tools 支持方法

    /// Stage 1: AI Dispatcher - 分析文本并决定需要哪些检查
    func analyzeDispatcher(_ text: String, detailLevel: String = "standard", onReasoning: @escaping (String) -> Void) async throws -> AnalysisPlan {
        let url = URL(string: "\(baseURL)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You are a writing assistant dispatcher. Analyze the text and decide which checks are needed.
        User preference level: \(detailLevel) (concise/standard/detailed) - this is a hint, not a rule.

        Rules:
        - need_grammar_check: true if text has potential grammar issues
        - need_fixes: true if you found actual errors that need correction
        - need_idiomatic: true if text could be more natural/idiomatic
        - need_translation: true if text contains Chinese that needs English translation
        - need_explanation: true only if complex grammar needs deep explanation (respect user's detail level)
        """

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": "Text to analyze: \(text)"]
        ]

        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "analyze_dispatcher",
                    "description": "Return analysis plan for the text",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "need_grammar_check": ["type": "boolean", "description": "Whether grammar check is needed"],
                            "need_fixes": ["type": "boolean", "description": "Whether there are errors to fix"],
                            "need_idiomatic": ["type": "boolean", "description": "Whether idiomatic suggestions are needed"],
                            "need_translation": ["type": "boolean", "description": "Whether Chinese to English translation is needed"],
                            "need_explanation": ["type": "boolean", "description": "Whether detailed grammar explanation is needed"],
                            "reasoning": ["type": "string", "description": "Brief reasoning for the analysis plan"]
                        ],
                        "required": ["need_grammar_check", "need_fixes", "need_idiomatic", "need_translation", "need_explanation", "reasoning"]
                    ]
                ]
            ]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        var fullReasoning = ""
        var toolCallData: [String: Any]?
        var lineCount = 0

        print("🔷 [analyzeDispatcher] Starting to read stream...")

        for try await line in bytes.lines {
            lineCount += 1
            print("🔷 [analyzeDispatcher] Line \(lineCount): \(line.prefix(200))")

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("⚠️ [analyzeDispatcher] Failed to parse line as JSON")
                continue
            }

            print("🔷 [analyzeDispatcher] JSON keys: \(json.keys)")

            // 提取 reasoning（流式显示）
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                fullReasoning += content
                await MainActor.run {
                    onReasoning(fullReasoning)
                }
            }

            // 提取 tool_calls
            if let message = json["message"] as? [String: Any],
               let toolCalls = message["tool_calls"] as? [[String: Any]],
               let firstCall = toolCalls.first,
               let function = firstCall["function"] as? [String: Any] {
                print("🔷 [analyzeDispatcher] Found tool_calls! function: \(function)")
                toolCallData = function
            }

            // 检查是否完成
            if let done = json["done"] as? Bool, done {
                print("🔷 [analyzeDispatcher] Stream done")
                break
            }
        }

        print("🔷 [analyzeDispatcher] Total lines: \(lineCount)")
        print("🔷 [analyzeDispatcher] toolCallData: \(String(describing: toolCallData))")

        // 解析 tool call 参数
        guard let toolCall = toolCallData else {
            print("❌ [analyzeDispatcher] No toolCallData found")
            throw OllamaError.invalidResponse
        }

        // 尝试多种方式获取 arguments
        var argumentsData: Data?

        if let argsString = toolCall["arguments"] as? String {
            print("🔷 [analyzeDispatcher] arguments is string: \(argsString)")
            argumentsData = argsString.data(using: .utf8)
        } else if let argsDict = toolCall["arguments"] as? [String: Any] {
            print("🔷 [analyzeDispatcher] arguments is dict: \(argsDict)")
            argumentsData = try? JSONSerialization.data(withJSONObject: argsDict)
        } else {
            print("❌ [analyzeDispatcher] arguments not found or unknown type: \(type(of: toolCall["arguments"]))")
        }

        guard let data = argumentsData else {
            print("❌ [analyzeDispatcher] Failed to get argumentsData")
            throw OllamaError.invalidResponse
        }

        do {
            let plan = try JSONDecoder().decode(AnalysisPlan.self, from: data)
            print("✅ [analyzeDispatcher] Successfully decoded plan: \(plan)")
            return plan
        } catch {
            print("❌ [analyzeDispatcher] Failed to decode plan: \(error)")
            if let jsonString = String(data: data, encoding: .utf8) {
                print("❌ [analyzeDispatcher] Raw arguments: \(jsonString)")
            }
            throw OllamaError.invalidResponse
        }
    }

    /// Stage 2: 执行具体分析 - 并行调用多个 tools
    func performAnalysis(_ text: String, plan: AnalysisPlan) async throws -> AnalysisResult {
        // 定义任务类型
        enum AnalysisTask {
            case fixes([GrammarFix])
            case idiomatic([IdiomaticSuggestion])
            case translation(String, [Translation])
            case explanation([GrammarPoint])
        }

        // 并行执行需要的分析
        let tasks = try await withThrowingTaskGroup(of: AnalysisTask?.self) { group in
            if plan.needFixes {
                group.addTask {
                    let fixes = try await self.getFixes(text)
                    return .fixes(fixes)
                }
            }

            if plan.needIdiomatic {
                group.addTask {
                    let suggestions = try await self.getIdiomaticSuggestions(text)
                    return .idiomatic(suggestions)
                }
            }

            if plan.needTranslation {
                group.addTask {
                    let (pureEnglish, translations) = try await self.translateChineseToEnglish(text)
                    return .translation(pureEnglish, translations)
                }
            }

            if plan.needExplanation {
                group.addTask {
                    let points = try await self.getDetailedExplanation(text)
                    return .explanation(points)
                }
            }

            var results: [AnalysisTask] = []
            for try await task in group {
                if let task = task {
                    results.append(task)
                }
            }
            return results
        }

        // 组装结果
        var result = AnalysisResult()
        for task in tasks {
            switch task {
            case .fixes(let fixes):
                result.fixes = fixes
            case .idiomatic(let suggestions):
                result.idiomaticSuggestions = suggestions
            case .translation(let pureEnglish, let translations):
                result.pureEnglish = pureEnglish
                result.translations = translations
            case .explanation(let points):
                result.grammarPoints = points
            }
        }

        return result
    }

    /// Tool: 获取语法修复
    private func getFixes(_ text: String) async throws -> [GrammarFix] {
        let systemPrompt = "You are a grammar checker. Find and fix grammar errors in the text."
        let userPrompt = "Text: \(text)"

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "get_fixes",
                "description": "Return grammar fixes",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "fixes": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "original": ["type": "string"],
                                    "corrected": ["type": "string"],
                                    "error_type": ["type": "string"]
                                ],
                                "required": ["original", "corrected", "error_type"]
                            ]
                        ]
                    ],
                    "required": ["fixes"]
                ]
            ]
        ]

        let result = try await callTool(systemPrompt: systemPrompt, userPrompt: userPrompt, tool: tool)
        guard let fixesArray = result["fixes"] as? [[String: Any]] else {
            return []
        }

        return try fixesArray.map { dict in
            let jsonData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(GrammarFix.self, from: jsonData)
        }
    }

    /// Tool: 获取地道化建议
    private func getIdiomaticSuggestions(_ text: String) async throws -> [IdiomaticSuggestion] {
        let systemPrompt = "You are a native English writing coach. Suggest more natural and idiomatic expressions."
        let userPrompt = "Text: \(text)"

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "idiomatic_suggestions",
                "description": "Return idiomatic suggestions",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "suggestions": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "current": ["type": "string"],
                                    "idiomatic": ["type": "string"],
                                    "explanation": ["type": "string"]
                                ],
                                "required": ["current", "idiomatic", "explanation"]
                            ]
                        ]
                    ],
                    "required": ["suggestions"]
                ]
            ]
        ]

        let result = try await callTool(systemPrompt: systemPrompt, userPrompt: userPrompt, tool: tool)
        guard let suggestionsArray = result["suggestions"] as? [[String: Any]] else {
            return []
        }

        return try suggestionsArray.map { dict in
            let jsonData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(IdiomaticSuggestion.self, from: jsonData)
        }
    }

    /// Tool: 中英转换
    private func translateChineseToEnglish(_ text: String) async throws -> (pureEnglish: String, translations: [Translation]) {
        let systemPrompt = "You are a translator. Convert mixed Chinese-English text to pure English and provide translations."
        let userPrompt = "Text: \(text)"

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "chinese_to_english",
                "description": "Translate Chinese parts to English",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "pure_english": ["type": "string", "description": "Full text in English"],
                        "translations": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "chinese": ["type": "string"],
                                    "english": ["type": "string"]
                                ],
                                "required": ["chinese", "english"]
                            ]
                        ]
                    ],
                    "required": ["pure_english", "translations"]
                ]
            ]
        ]

        let result = try await callTool(systemPrompt: systemPrompt, userPrompt: userPrompt, tool: tool)
        let pureEnglish = result["pure_english"] as? String ?? ""
        let translationsArray = result["translations"] as? [[String: Any]] ?? []

        let translations = try translationsArray.map { dict in
            let jsonData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(Translation.self, from: jsonData)
        }

        return (pureEnglish, translations)
    }

    /// Tool: 详细语法解释
    private func getDetailedExplanation(_ text: String) async throws -> [GrammarPoint] {
        let systemPrompt = "You are a grammar teacher. Explain important grammar rules used in the text."
        let userPrompt = "Text: \(text)"

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "detailed_explanation",
                "description": "Provide detailed grammar explanation",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "grammar_points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "rule": ["type": "string"],
                                    "explanation": ["type": "string"],
                                    "examples": [
                                        "type": "array",
                                        "items": ["type": "string"]
                                    ]
                                ],
                                "required": ["rule", "explanation", "examples"]
                            ]
                        ]
                    ],
                    "required": ["grammar_points"]
                ]
            ]
        ]

        let result = try await callTool(systemPrompt: systemPrompt, userPrompt: userPrompt, tool: tool)
        guard let pointsArray = result["grammar_points"] as? [[String: Any]] else {
            return []
        }

        return try pointsArray.map { dict in
            let jsonData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(GrammarPoint.self, from: jsonData)
        }
    }

    /// 通用 Tool 调用方法（非流式）
    private func callTool(systemPrompt: String, userPrompt: String, tool: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/api/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": [tool],
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 调试日志：打印请求体
        if let requestJson = String(data: request.httpBody ?? Data(), encoding: .utf8) {
            print("🔷 [callTool] Request body:\n\(requestJson.prefix(500))...")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ [callTool] Response is not HTTPURLResponse")
            throw OllamaError.requestFailed
        }

        print("🔷 [callTool] HTTP Status: \(httpResponse.statusCode)")

        // 打印原始响应
        if let responseString = String(data: data, encoding: .utf8) {
            print("🔷 [callTool] Raw response:\n\(responseString)")
        }

        guard httpResponse.statusCode == 200 else {
            print("❌ [callTool] HTTP error: \(httpResponse.statusCode)")
            throw OllamaError.requestFailed
        }

        // 逐步解析并打印调试信息
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ [callTool] Failed to parse JSON")
            throw OllamaError.invalidResponse
        }
        print("🔷 [callTool] JSON keys: \(json.keys)")

        guard let message = json["message"] as? [String: Any] else {
            print("❌ [callTool] No 'message' in response. Full JSON: \(json)")
            throw OllamaError.invalidResponse
        }
        print("🔷 [callTool] Message keys: \(message.keys)")

        guard let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            print("❌ [callTool] No 'tool_calls' in message. Message content: \(message)")
            // 如果没有 tool_calls 但有 content，可能是模型直接回复了
            if let content = message["content"] as? String {
                print("🔷 [callTool] Model returned content instead of tool_call: \(content)")
            }
            throw OllamaError.invalidResponse
        }
        print("🔷 [callTool] Tool calls count: \(toolCalls.count)")

        guard let firstCall = toolCalls.first else {
            print("❌ [callTool] tool_calls array is empty")
            throw OllamaError.invalidResponse
        }
        print("🔷 [callTool] First call keys: \(firstCall.keys)")

        guard let function = firstCall["function"] as? [String: Any] else {
            print("❌ [callTool] No 'function' in tool call. firstCall: \(firstCall)")
            throw OllamaError.invalidResponse
        }
        print("🔷 [callTool] Function keys: \(function.keys)")

        guard let argumentsString = function["arguments"] as? String else {
            print("❌ [callTool] No 'arguments' string in function. function: \(function)")
            // 尝试直接作为字典获取
            if let argumentsDict = function["arguments"] as? [String: Any] {
                print("🔷 [callTool] Arguments is already a dict: \(argumentsDict)")
                return argumentsDict
            }
            throw OllamaError.invalidResponse
        }
        print("🔷 [callTool] Arguments string: \(argumentsString)")

        guard let argumentsData = argumentsString.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            print("❌ [callTool] Failed to parse arguments string as JSON")
            throw OllamaError.invalidResponse
        }

        print("✅ [callTool] Successfully parsed arguments: \(arguments.keys)")
        return arguments
    }
}

enum OllamaError: Error {
    case requestFailed
    case invalidResponse

    var localizedDescription: String {
        switch self {
        case .requestFailed:
            return "请求失败，请确保 Ollama 正在运行"
        case .invalidResponse:
            return "响应格式错误"
        }
    }
}
