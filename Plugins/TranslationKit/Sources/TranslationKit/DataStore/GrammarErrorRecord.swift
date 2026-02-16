//
//  GrammarErrorRecord.swift
//  TranslationKit
//
//  语法错误记录模型 - SwiftData
//

import SwiftData
import Foundation

@Model
public final class GrammarErrorRecord {
    public var id: UUID
    public var timestamp: Date

    // 错误详情
    public var original: String
    public var corrected: String
    public var errorType: String
    public var category: String  // tense, article, preposition 等

    // 上下文
    public var inputContext: String

    public init(original: String, corrected: String, errorType: String, category: String, context: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.original = original
        self.corrected = corrected
        self.errorType = errorType
        self.category = category
        self.inputContext = context
    }
}
