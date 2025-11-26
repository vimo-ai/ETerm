//
//  WordBoundaryDetector.swift
//  ETerm
//
//  领域层 - 词边界检测器
//
//  职责：
//  - 识别文本中词的边界（支持中日韩 + 英文）
//  - 用于双击选中和分词删除功能
//
//  实现策略：
//  1. 优先使用 NaturalLanguage Framework（准确的语义分词）
//  2. 降级到简单规则（按空格和标点分割）
//

import Foundation
import NaturalLanguage

/// 词边界检测结果
struct WordBoundary {
    /// 词的起始索引（字符偏移）
    let startIndex: Int

    /// 词的结束索引（字符偏移，不包含）
    let endIndex: Int

    /// 选中的文本
    let text: String

    /// 是否由 NaturalLanguage 识别（用于调试）
    let isNLResult: Bool
}

/// 词边界检测器 - MVP 极简版本
final class WordBoundaryDetector {

    // MARK: - Properties

    /// NaturalLanguage 分词器（可复用，提升性能）
    private let tokenizer = NLTokenizer(unit: .word)

    // MARK: - Public API

    /// 查找指定位置的词边界
    ///
    /// - Parameters:
    ///   - text: 要分析的文本（通常是终端的一行）
    ///   - position: 光标/鼠标点击的字符位置（0-based）
    /// - Returns: 词边界信息，如果位置无效则返回 nil
    func findBoundary(in text: String, at position: Int) -> WordBoundary? {
        guard position >= 0 && position < text.count else {
            return nil
        }

        // 1. 优先使用 NaturalLanguage（支持中日韩多语言）
        if let nlResult = findBoundaryWithNL(in: text, at: position) {
            return nlResult
        }

        // 2. 降级：简单规则（按分隔符分割）
        return findBoundaryWithSimpleRules(in: text, at: position)
    }

    // MARK: - NaturalLanguage 分词

    /// 使用 NaturalLanguage Framework 查找词边界
    private func findBoundaryWithNL(in text: String, at position: Int) -> WordBoundary? {
        tokenizer.string = text
        let targetIndex = text.index(text.startIndex, offsetBy: position)

        var result: WordBoundary?

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            // 检查当前 token 是否包含目标位置
            if tokenRange.contains(targetIndex) {
                let start = text.distance(from: text.startIndex, to: tokenRange.lowerBound)
                let end = text.distance(from: text.startIndex, to: tokenRange.upperBound)
                let word = String(text[tokenRange])

                result = WordBoundary(
                    startIndex: start,
                    endIndex: end,
                    text: word,
                    isNLResult: true
                )
                return false  // 找到了，停止遍历
            }
            return true  // 继续遍历
        }

        return result
    }

    // MARK: - 简单规则降级

    /// 简单规则：按空格和标点符号分割
    ///
    /// 适用于 NaturalLanguage 失败的情况（如纯符号、特殊字符等）
    private func findBoundaryWithSimpleRules(in text: String, at position: Int) -> WordBoundary {
        let delimiters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)

        var start = position
        var end = position + 1

        // 向左扩展到分隔符或字符串开头
        while start > 0 {
            let index = text.index(text.startIndex, offsetBy: start - 1)
            let char = text[index]

            // 如果遇到分隔符，停止
            if char.unicodeScalars.contains(where: { delimiters.contains($0) }) {
                break
            }
            start -= 1
        }

        // 向右扩展到分隔符或字符串结尾
        while end < text.count {
            let index = text.index(text.startIndex, offsetBy: end)
            let char = text[index]

            // 如果遇到分隔符，停止
            if char.unicodeScalars.contains(where: { delimiters.contains($0) }) {
                break
            }
            end += 1
        }

        // 提取文本
        let startIdx = text.index(text.startIndex, offsetBy: start)
        let endIdx = text.index(text.startIndex, offsetBy: end)
        let word = String(text[startIdx..<endIdx])

        return WordBoundary(
            startIndex: start,
            endIndex: end,
            text: word,
            isNLResult: false
        )
    }
}
