//
//  WordEntry.swift
//  ETerm
//
//  SwiftData Model for vocabulary tracking
//

import SwiftData
import Foundation

@Model
final class WordEntry {
    // Basic information
    @Attribute(.unique) var word: String
    var phonetic: String?

    // Core data: Hit count and timestamps
    var hitCount: Int
    var queryTimestamps: [Date]  // Timestamp for each query

    // Context
    var lastSourceContext: String?  // Last source sentence when queried

    // Definition (simplified, only store the primary one)
    var primaryDefinition: String?      // Primary definition (English)
    var chineseTranslation: String?     // Chinese translation

    init(word: String, phonetic: String?, context: String?, definition: String?, translation: String? = nil) {
        self.word = word.lowercased()  // Store in lowercase for consistency
        self.phonetic = phonetic
        self.hitCount = 1
        self.queryTimestamps = [Date()]
        self.lastSourceContext = context
        self.primaryDefinition = definition
        self.chineseTranslation = translation
    }

    // Record a new query
    func recordQuery(context: String?, definition: String?, translation: String? = nil) {
        hitCount += 1
        queryTimestamps.append(Date())
        if let context {
            lastSourceContext = context
        }
        if let definition {
            primaryDefinition = definition
        }
        if let translation {
            chineseTranslation = translation
        }
    }

    // Convenience properties
    var lastQueryDate: Date? {
        queryTimestamps.last
    }

    var firstQueryDate: Date? {
        queryTimestamps.first
    }
}
