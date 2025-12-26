//
//  EnglishLearningDataStore.swift
//  TranslationKit
//
//  SwiftData 容器 - 管理单词本和语法错误记录

import SwiftData
import Foundation

/// EnglishLearning 专用的 ModelContainer
public enum EnglishLearningDataStore {
    /// 数据库路径
    private static let databasePath: String = {
        let dataDir = NSHomeDirectory() + "/.eterm/data"
        // 确保目录存在
        try? FileManager.default.createDirectory(
            atPath: dataDir,
            withIntermediateDirectories: true
        )
        return dataDir + "/english-learning.db"
    }()

    public static let shared: ModelContainer = {
        let schema = Schema([WordEntry.self, GrammarErrorRecord.self])

        do {
            // 使用自定义路径
            let dbURL = URL(fileURLWithPath: databasePath)
            let config = ModelConfiguration(url: dbURL)

            let container = try ModelContainer(for: schema, configurations: [config])
            print("[TranslationKit] DataStore initialized at: \(databasePath)")
            return container
        } catch {
            // 如果自定义路径失败，回退到默认路径
            print("[TranslationKit] 使用自定义路径初始化数据库失败，回退到默认路径: \(error)")

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
