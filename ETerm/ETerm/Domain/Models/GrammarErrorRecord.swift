//
//  GrammarErrorRecord.swift
//  ETerm
//
//  SwiftData Model for grammar error tracking
//

import SwiftData
import Foundation

@Model
final class GrammarErrorRecord {
    var id: UUID
    var timestamp: Date

    // Error details
    var original: String
    var corrected: String
    var errorType: String
    var category: String  // AI-returned category (English identifier)

    // Context
    var inputContext: String

    init(original: String, corrected: String, errorType: String, category: String, context: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.original = original
        self.corrected = corrected
        self.errorType = errorType
        self.category = category
        self.inputContext = context
    }
}
