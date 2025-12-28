//
//  ClaudeTitleGenerator.swift
//  ClaudeKit
//
//  Claude Tab 智能标题生成器
//  使用 Ollama 本地模型根据用户 prompt 生成简短标题
//

import Foundation
import ETermKit

/// Ollama 配置（与主程序 OllamaSettings 保持一致）
private struct OllamaConfig: Codable {
    var baseURL: String = "http://localhost:11434"
    var model: String = "qwen3:0.6b"

    static let configPath = ETermPaths.config + "/ollama.json"

    static func load() -> OllamaConfig {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(OllamaConfig.self, from: data) else {
            return OllamaConfig()
        }
        return config
    }
}

/// Claude Tab 标题生成器
///
/// 使用 Ollama 本地模型根据用户问题生成简短标题。
/// 异步执行，不阻塞主流程。Ollama 不可用时返回 nil。
/// 配置从 ~/.eterm/config/ollama.json 读取，与主程序共享。
final class ClaudeTitleGenerator {
    static let shared = ClaudeTitleGenerator()

    /// Ollama 配置（懒加载，每次生成时重新读取以支持热更新）
    private var config: OllamaConfig {
        OllamaConfig.load()
    }

    private init() {}

    // MARK: - Public API

    /// 根据用户 prompt 生成标题
    ///
    /// - Parameter prompt: 用户提交的问题
    /// - Returns: 生成的标题，失败返回 nil
    func generateTitle(from prompt: String) async -> String? {
        // 1. 如果 prompt 太短，直接使用 prompt
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.count <= 15 {
            return sanitizeTitle(trimmedPrompt)
        }

        // 2. 构建生成请求
        let systemPrompt = buildPrompt(for: trimmedPrompt)

        do {
            let response = try await callOllama(prompt: systemPrompt)
            let title = sanitizeTitle(response)

            // 如果生成结果为空，返回 nil
            if title.isEmpty {
                return nil
            }

            return title

        } catch {
            print("[ClaudeTitleGenerator] Error: \(error)")
            return nil
        }
    }

    // MARK: - Private Methods

    /// 调用 Ollama API
    private func callOllama(prompt: String) async throws -> String {
        let cfg = config
        guard let url = URL(string: "\(cfg.baseURL)/api/generate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": cfg.model,
            "prompt": prompt,
            "stream": false,
            "raw": true,  // 禁用模板，避免触发 think 模式
            "options": [
                "num_predict": 20,
                "temperature": 0.3,
                "stop": ["\n", "。", ".", "\"", "'"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw URLError(.cannotDecodeContentData)
        }

        return responseText
    }

    /// 构建生成 prompt
    ///
    /// 根据用户输入语言自动选择提示语言
    private func buildPrompt(for userPrompt: String) -> String {
        let isChinese = containsChinese(userPrompt)

        if isChinese {
            return """
            用5-10个字总结以下问题的主题，只输出标题，不要解释：
            \(userPrompt.prefix(200))
            标题：
            """
        } else {
            return """
            Summarize the topic of this question in 3-5 words. Output only the title, no explanation:
            \(userPrompt.prefix(200))
            Title:
            """
        }
    }

    /// 检测文本是否包含中文
    private func containsChinese(_ text: String) -> Bool {
        for char in text {
            if let scalar = char.unicodeScalars.first {
                // CJK Unified Ideographs 范围
                if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                    return true
                }
            }
        }
        return false
    }

    /// 清理标题
    ///
    /// 移除多余的空白、引号、换行等
    private func sanitizeTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 移除开头的 "标题：" 或 "Title:" 等前缀
        let prefixes = ["标题：", "标题:", "Title:", "Title：", "主题：", "主题:", "Topic:", "Summary:"]
        for prefix in prefixes {
            if title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 移除引号（包括中英文引号）
        let quotesToRemove = ["\"", "'", "\u{201C}", "\u{201D}", "\u{300C}", "\u{300D}"]
        for quote in quotesToRemove {
            title = title.replacingOccurrences(of: quote, with: "")
        }

        // 移除末尾的句号
        while title.hasSuffix("。") || title.hasSuffix(".") {
            title = String(title.dropLast())
        }

        // 限制长度（最多 20 个字符）
        if title.count > 20 {
            title = String(title.prefix(17)) + "..."
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
