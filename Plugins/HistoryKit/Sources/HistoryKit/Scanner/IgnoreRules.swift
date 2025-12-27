//
//  IgnoreRules.swift
//  HistoryKit
//
//  忽略规则

import Foundation

// MARK: - IgnoreRules

/// 忽略规则管理
public struct IgnoreRules: Sendable {

    /// 默认忽略的目录
    public static let defaultIgnoreDirs: Set<String> = [
        ".git",
        "node_modules",
        ".eterm-history",
        "__pycache__",
        "target",
        "build",
        "dist",
        ".cache",
        ".idea",
        ".vscode",
        "DerivedData",
        ".build",
        "Pods",
        "vendor",
        ".next",
        ".nuxt",
        "out",
        ".output",
        "coverage"
    ]

    /// 默认忽略的文件模式
    public static let defaultIgnorePatterns: [String] = [
        "*.log",
        ".DS_Store",
        "*.swp",
        "*.swo",
        "*~",
        "Thumbs.db",
        "*.pyc",
        "*.pyo",
        "*.class",
        "*.o",
        "*.a",
        "*.so",
        "*.dylib"
    ]

    /// 最大文件大小（10MB）
    public static let maxFileSize: Int64 = 10 * 1024 * 1024

    /// 忽略的目录
    private let ignoreDirs: Set<String>

    /// 忽略的文件模式
    private let ignorePatterns: [String]

    public init(
        ignoreDirs: Set<String>? = nil,
        ignorePatterns: [String]? = nil
    ) {
        self.ignoreDirs = ignoreDirs ?? Self.defaultIgnoreDirs
        self.ignorePatterns = ignorePatterns ?? Self.defaultIgnorePatterns
    }

    /// 检查目录是否应该被忽略
    public func shouldIgnoreDirectory(_ name: String) -> Bool {
        ignoreDirs.contains(name)
    }

    /// 检查文件是否应该被忽略
    public func shouldIgnoreFile(_ name: String) -> Bool {
        for pattern in ignorePatterns {
            if matchPattern(pattern, against: name) {
                return true
            }
        }
        return false
    }

    /// 检查路径是否应该被忽略
    public func shouldIgnore(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")

        // 检查路径中的每个目录
        for component in components.dropLast() {
            if shouldIgnoreDirectory(String(component)) {
                return true
            }
        }

        // 检查文件名
        if let fileName = components.last {
            return shouldIgnoreFile(String(fileName))
        }

        return false
    }

    /// 简单的通配符匹配（支持 * 和 ?）
    private func matchPattern(_ pattern: String, against string: String) -> Bool {
        // 简单实现：只支持 * 开头的模式
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return string.hasSuffix(suffix)
        }

        // 精确匹配
        return pattern == string
    }
}
