//
//  DirectoryScanner.swift
//  HistoryKit
//
//  目录扫描器

import Foundation

// MARK: - DirectoryScanner

/// 目录扫描器
public final class DirectoryScanner: Sendable {

    /// 忽略规则
    private let ignoreRules: IgnoreRules

    public init(ignoreRules: IgnoreRules = IgnoreRules()) {
        self.ignoreRules = ignoreRules
    }

    /// 扫描目录，返回所有文件
    /// - Parameter projectPath: 项目路径
    /// - Returns: 扫描到的文件列表
    public func scan(projectPath: String) throws -> [ScannedFile] {
        let baseURL = URL(fileURLWithPath: projectPath)
        let fm = FileManager.default

        var results: [ScannedFile] = []

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey
        ]

        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []  // 不跳过隐藏文件，由忽略规则处理
        ) else {
            return []
        }

        while let url = enumerator.nextObject() as? URL {
            let relativePath = url.path.replacingOccurrences(
                of: baseURL.path + "/",
                with: ""
            )

            // 获取资源值
            guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys) else {
                continue
            }

            // 检查是否为目录
            if resourceValues.isDirectory == true {
                // 检查目录是否应该被忽略
                let dirName = url.lastPathComponent
                if ignoreRules.shouldIgnoreDirectory(dirName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // 只处理普通文件
            guard resourceValues.isRegularFile == true else {
                continue
            }

            // 检查忽略规则
            if ignoreRules.shouldIgnore(relativePath) {
                continue
            }

            // 获取文件大小
            let size = Int64(resourceValues.fileSize ?? 0)

            // 跳过大文件
            if size > IgnoreRules.maxFileSize {
                continue
            }

            // 获取修改时间
            let mtime = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0

            // 获取权限（通过 FileManager）
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let mode = UInt16((attributes?[.posixPermissions] as? Int) ?? 0o644)

            results.append(ScannedFile(
                path: relativePath,
                absolutePath: url,
                size: size,
                mtime: mtime,
                mode: mode
            ))
        }

        return results
    }
}
