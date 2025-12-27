//
//  ClaudeTitleGenerator.swift
//  ETerm
//
//  Claude Tab 智能标题生成器
//  使用 Ollama 本地模型根据用户 prompt 生成简短标题
//

import Foundation

/// Claude Tab 标题生成器
///
/// 使用 Ollama 本地模型（qwen3:0.6b）根据用户问题生成简短标题。
/// 异步执行，不阻塞主流程。Ollama 不可用时返回 "Claude"。
final class ClaudeTitleGenerator {
    static let shared = ClaudeTitleGenerator()

    private let ollamaService = OllamaService.shared

    private init() {}

    // MARK: - Public API

    /// 根据用户 prompt 生成标题
    ///
    /// - Parameters:
    ///   - prompt: 用户提交的问题
    ///   - completion: 完成回调，返回生成的标题
    func generateTitle(from prompt: String, completion: @escaping (String) -> Void) {
        // 异步执行，不阻塞
        Task {
            let title = await generateTitleAsync(from: prompt)
            await MainActor.run {
                completion(title)
            }
        }
    }

    /// 异步生成标题
    ///
    /// - Parameter prompt: 用户提交的问题
    /// - Returns: 生成的标题
    func generateTitleAsync(from prompt: String) async -> String {
        // 1. 检查 Ollama 是否就绪
        guard ollamaService.status.isReady else {
            return "Claude"
        }

        // 2. 如果 prompt 太短，直接使用 prompt
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.count <= 15 {
            return sanitizeTitle(trimmedPrompt)
        }

        // 3. 构建生成请求
        let systemPrompt = buildPrompt(for: trimmedPrompt)

        do {
            let options = GenerateOptions(
                numPredict: 20,      // 最多生成 20 个 token
                temperature: 0.3,    // 较低温度，更稳定
                stop: ["\n", "。", ".", "\"", "'"],  // 遇到这些字符停止
                raw: true
            )

            let response = try await ollamaService.generate(prompt: systemPrompt, options: options)
            let title = sanitizeTitle(response)

            // 如果生成结果为空，fallback
            if title.isEmpty {
                return "Claude"
            }

            return title

        } catch {
            // Ollama 调用失败，fallback
            return "Claude"
        }
    }

    // MARK: - Private Methods

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
