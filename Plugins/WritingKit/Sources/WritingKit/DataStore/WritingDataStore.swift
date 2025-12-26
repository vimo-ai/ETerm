//
//  WritingDataStore.swift
//  WritingKit
//
//  写作助手数据存储 - 管理语法错误档案
//

import SwiftData
import Foundation

/// WritingKit 专用的 ModelContainer
public enum WritingDataStore {
    /// 数据库路径
    private static let databasePath: String = {
        let dataDir = NSHomeDirectory() + "/.eterm/data"
        // 确保目录存在
        try? FileManager.default.createDirectory(
            atPath: dataDir,
            withIntermediateDirectories: true
        )
        return dataDir + "/writing.db"
    }()

    /// 共享的 ModelContainer
    public static let shared: ModelContainer = {
        let schema = Schema([GrammarErrorRecord.self])

        do {
            let dbURL = URL(fileURLWithPath: databasePath)
            let config = ModelConfiguration(url: dbURL)

            let container = try ModelContainer(for: schema, configurations: [config])
            print("[WritingKit] DataStore initialized at: \(databasePath)")
            return container
        } catch {
            print("[WritingKit] 使用自定义路径初始化数据库失败，回退到默认路径: \(error)")

            do {
                let config = ModelConfiguration("WritingKit", schema: schema)
                let container = try ModelContainer(for: schema, configurations: [config])
                return container
            } catch {
                fatalError("[WritingKit] 无法创建 ModelContainer: \(error)")
            }
        }
    }()

    /// 获取 ModelContext（主线程）
    @MainActor
    public static var mainContext: ModelContext {
        shared.mainContext
    }

    /// 保存语法错误
    @MainActor
    public static func saveGrammarError(
        original: String,
        corrected: String,
        errorType: String,
        category: String,
        context: String
    ) {
        let record = GrammarErrorRecord(
            original: original,
            corrected: corrected,
            errorType: errorType,
            category: category,
            context: context
        )
        mainContext.insert(record)

        do {
            try mainContext.save()
            print("[WritingKit] Saved grammar error: \(original) -> \(corrected)")
        } catch {
            print("[WritingKit] Failed to save grammar error: \(error)")
        }
    }
}
