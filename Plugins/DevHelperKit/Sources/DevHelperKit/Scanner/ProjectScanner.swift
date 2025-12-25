// ProjectScanner.swift
// DevHelperKit
//
// 项目扫描器 - 遍历目录树，发现项目

import Foundation

/// 项目扫描器
public final class ProjectScanner: @unchecked Sendable {
    /// 单例
    public static let shared = ProjectScanner()

    /// 已注册的检测器
    private var detectors: [ProjectDetector] = []

    /// 公共忽略目录
    private let commonSkipDirectories: Set<String> = [".git", ".svn", ".hg"]

    private init() {
        // 注册内置检测器
        register(NodeProjectDetector())
        // 后续添加：
        // register(CargoProjectDetector())
        // register(GoProjectDetector())
    }

    // MARK: - 注册

    /// 注册项目检测器
    public func register(_ detector: ProjectDetector) {
        detectors.append(detector)
    }

    // MARK: - 扫描

    /// 扫描单个文件夹
    /// - Parameters:
    ///   - folder: 要扫描的文件夹
    ///   - maxDepth: 最大递归深度，默认 3
    /// - Returns: 检测到的项目列表
    public func scan(folder: URL, maxDepth: Int = 3) -> [DetectedProject] {
        // 合并所有跳过目录
        var allSkipDirs = commonSkipDirectories
        for detector in detectors {
            allSkipDirs.formUnion(detector.skipDirectories)
        }

        // 构建 configFileName -> Detector 映射，加速查找
        var detectorMap: [String: ProjectDetector] = [:]
        for detector in detectors {
            detectorMap[detector.configFileName] = detector
        }

        var results: [DetectedProject] = []
        scanDirectory(folder, depth: 0, maxDepth: maxDepth, skipDirs: allSkipDirs, detectorMap: detectorMap, results: &results)
        return results
    }

    /// 扫描多个文件夹
    /// - Parameters:
    ///   - folders: 要扫描的文件夹列表
    ///   - maxDepth: 最大递归深度
    /// - Returns: 检测到的项目列表
    public func scan(folders: [URL], maxDepth: Int = 3) -> [DetectedProject] {
        var allResults: [DetectedProject] = []
        for folder in folders {
            let results = scan(folder: folder, maxDepth: maxDepth)
            allResults.append(contentsOf: results)
        }
        return allResults
    }

    // MARK: - 内部实现

    private func scanDirectory(
        _ dir: URL,
        depth: Int,
        maxDepth: Int,
        skipDirs: Set<String>,
        detectorMap: [String: ProjectDetector],
        results: inout [DetectedProject]
    ) {
        guard depth <= maxDepth else { return }

        // 一次 readdir
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        // 分离文件和目录
        var fileNames: Set<String> = []
        var subdirs: [URL] = []

        for item in contents {
            let name = item.lastPathComponent

            if isDirectory(item) {
                if !skipDirs.contains(name) {
                    subdirs.append(item)
                }
            } else {
                fileNames.insert(name)
            }
        }

        // 匹配检测器（O(1) 查找）
        for (configFileName, detector) in detectorMap {
            if fileNames.contains(configFileName) {
                let configPath = dir.appendingPathComponent(configFileName)
                if let project = detector.parse(configPath: configPath, folderPath: dir) {
                    results.append(project)
                }
            }
        }

        // 递归子目录
        for subdir in subdirs {
            scanDirectory(subdir, depth: depth + 1, maxDepth: maxDepth, skipDirs: skipDirs, detectorMap: detectorMap, results: &results)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
