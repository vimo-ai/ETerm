//
//  BuiltinPluginInstaller.swift
//  ETerm
//
//  内置插件安装器
//  负责将 app bundle 内的插件复制到用户目录
//

import Foundation

/// 内置插件安装器
///
/// 启动时静默安装/更新内置插件：
/// - 新安装：直接复制
/// - 有更新（版本号更高）：覆盖安装
/// - 版本相同或更低：跳过
enum BuiltinPluginInstaller {

    /// 内置插件目录（app bundle 内）
    private static var builtinPluginsPath: String? {
        Bundle.main.resourcePath.map { $0 + "/BuiltinPlugins" }
    }

    /// 用户插件目录
    private static var userPluginsPath: String {
        ETermPaths.plugins
    }

    /// 执行安装/更新
    static func installIfNeeded() {
        guard let builtinPath = builtinPluginsPath,
              FileManager.default.fileExists(atPath: builtinPath) else {
            // 没有内置插件目录，跳过
            logInfo("No builtin plugins directory")
            return
        }

        do {
            // 确保用户插件目录存在
            try FileManager.default.createDirectory(
                atPath: userPluginsPath,
                withIntermediateDirectories: true
            )

            // 扫描内置插件（支持嵌套结构）
            // 结构可能是: BuiltinPlugins/Foo.bundle 或 BuiltinPlugins/Foo/Foo.bundle
            let bundles = findBundles(in: builtinPath)

            var installed = 0
            var updated = 0
            var skipped = 0

            logInfo("Found \(bundles.count) builtin plugins")

            for sourcePath in bundles {
                let bundleName = (sourcePath as NSString).lastPathComponent
                let targetPath = (userPluginsPath as NSString).appendingPathComponent(bundleName)

                let action = determineAction(source: sourcePath, target: targetPath)

                switch action {
                case .install:
                    try installPlugin(from: sourcePath, to: targetPath)
                    installed += 1
                    logInfo("Installed: \(bundleName)")

                case .update:
                    try installPlugin(from: sourcePath, to: targetPath)
                    updated += 1
                    logInfo("Updated: \(bundleName)")

                case .skip:
                    skipped += 1
                }
            }

            if installed > 0 || updated > 0 {
                logInfo("Builtin plugins: \(installed) installed, \(updated) updated, \(skipped) skipped")
            }

        } catch {
            logError("Failed to install builtin plugins: \(error)")
        }
    }

    // MARK: - Private

    /// 递归查找所有 .bundle 目录
    private static func findBundles(in directory: String) -> [String] {
        var results: [String] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return results
        }

        for item in contents {
            let itemPath = (directory as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false

            guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            if item.hasSuffix(".bundle") {
                // 直接是 .bundle
                results.append(itemPath)
            } else {
                // 检查子目录里是否有 .bundle
                let subBundles = findBundles(in: itemPath)
                results.append(contentsOf: subBundles)
            }
        }

        return results
    }

    private enum InstallAction {
        case install  // 新安装
        case update   // 版本升级
        case skip     // 跳过
    }

    /// 是否为 Debug 构建
    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 判断安装动作
    private static func determineAction(source: String, target: String) -> InstallAction {
        // 目标不存在 → 新安装
        guard FileManager.default.fileExists(atPath: target) else {
            return .install
        }

        // Debug 模式：总是覆盖（开发时改代码直接生效）
        if isDebugBuild {
            return .update
        }

        // Release 模式：比较版本
        let sourceVersion = readVersion(from: source)
        let targetVersion = readVersion(from: target)

        guard let sv = sourceVersion, let tv = targetVersion else {
            // 无法读取版本，跳过
            return .skip
        }

        if compareVersions(sv, tv) == .orderedDescending {
            // 内置版本更高 → 更新
            return .update
        }

        // 版本相同或更低 → 跳过
        return .skip
    }

    /// 读取插件版本
    private static func readVersion(from bundlePath: String) -> String? {
        let manifestPath = (bundlePath as NSString).appendingPathComponent("Contents/Resources/manifest.json")

        guard let data = FileManager.default.contents(atPath: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return nil
        }

        return version
    }

    /// 比较版本号 (支持 semver + prerelease)
    /// 例如: "0.0.1-beta.1" vs "0.0.1-beta.2"
    private static func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        // 分离主版本和预发布标签
        let parts1 = v1.split(separator: "-", maxSplits: 1)
        let parts2 = v2.split(separator: "-", maxSplits: 1)

        let main1 = String(parts1[0])
        let main2 = String(parts2[0])

        // 先比较主版本号
        let mainResult = compareMainVersions(main1, main2)
        if mainResult != .orderedSame {
            return mainResult
        }

        // 主版本相同，比较预发布标签
        let pre1 = parts1.count > 1 ? String(parts1[1]) : nil
        let pre2 = parts2.count > 1 ? String(parts2[1]) : nil

        // 没有预发布标签 > 有预发布标签 (1.0.0 > 1.0.0-beta.1)
        switch (pre1, pre2) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let p1?, let p2?): return p1.compare(p2, options: .numeric)
        }
    }

    private static func compareMainVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let c1 = v1.split(separator: ".").compactMap { Int($0) }
        let c2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(c1.count, c2.count) {
            let n1 = i < c1.count ? c1[i] : 0
            let n2 = i < c2.count ? c2[i] : 0

            if n1 > n2 { return .orderedDescending }
            if n1 < n2 { return .orderedAscending }
        }

        return .orderedSame
    }

    /// 安装插件（复制）
    private static func installPlugin(from source: String, to target: String) throws {
        let fm = FileManager.default

        // 删除旧版本（如果存在）
        if fm.fileExists(atPath: target) {
            try fm.removeItem(atPath: target)
        }

        // 复制新版本
        try fm.copyItem(atPath: source, toPath: target)
    }
}
