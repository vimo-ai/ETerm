//
//  EnglishLearningDataStore.swift
//  TranslationKit
//
//  SwiftData 容器 - 管理单词本

import SwiftData
import Foundation
import ETermKit

/// TranslationKit 专用的 ModelContainer
public enum EnglishLearningDataStore {
    /// 数据库路径
    private static let databasePath: String = {
        try? ETermPaths.ensureDirectory(ETermPaths.data)
        return ETermPaths.data + "/translation.db"
    }()

    public static let shared: ModelContainer = {
        let schema = Schema([WordEntry.self])

        do {
            // 使用自定义路径
            let dbURL = URL(fileURLWithPath: databasePath)
            let config = ModelConfiguration(url: dbURL)

            let container = try ModelContainer(for: schema, configurations: [config])
            return container
        } catch {
            // 如果自定义路径失败，回退到默认路径

            do {
                let config = ModelConfiguration("EnglishLearning", schema: schema)
                let container = try ModelContainer(for: schema, configurations: [config])
                return container
            } catch {
                fatalError("[TranslationKit] 无法创建 ModelContainer: \(error)")
            }
        }
    }()
}
