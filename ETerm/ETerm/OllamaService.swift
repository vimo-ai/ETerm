//
//  OllamaService.swift
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/15.
//

import Foundation

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
            onUpdate(fullResponse)
        }
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
