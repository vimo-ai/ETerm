//
//  VersionManager.swift
//  ETerm
//
//  管理已安装组件的版本信息 (~/.vimo/version.json)
//

import Foundation

/// 已安装组件信息
struct InstalledComponent: Codable {
    let version: String
    let sha256: String?
    let installedBy: String?
    let installedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version
        case sha256
        case installedBy = "installed_by"
        case installedAt = "installed_at"
    }
}

/// 已安装插件信息
struct InstalledPlugin: Codable {
    let version: String
    let installedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version
        case installedAt = "installed_at"
    }
}

/// 插件状态
enum PluginStatus: Equatable {
    case notInstalled           // 显示"安装"按钮
    case installed              // 显示"已安装"标签
    case updateAvailable(from: String, to: String)  // 显示"更新"按钮
}

/// version.json 数据结构
struct VersionFile: Codable {
    var runtimeVersion: String
    var components: [String: InstalledComponent]
    var plugins: [String: InstalledPlugin]

    enum CodingKeys: String, CodingKey {
        case runtimeVersion = "runtime_version"
        case components
        case plugins
    }

    init() {
        self.runtimeVersion = "0.0.1-beta.1"
        self.components = [:]
        self.plugins = [:]
    }
}

/// 版本管理器
final class VersionManager {
    static let shared = VersionManager()

    private let versionFilePath: String
    private var versionFile: VersionFile

    private init() {
        self.versionFilePath = ETermPaths.vimoRoot + "/version.json"
        self.versionFile = VersionManager.loadVersionFile(from: versionFilePath)
    }

    // MARK: - 组件查询

    /// 检查组件是否已安装
    func isComponentInstalled(_ name: String) -> Bool {
        versionFile.components[name] != nil
    }

    /// 获取已安装组件的版本
    func getComponentVersion(_ name: String) -> String? {
        versionFile.components[name]?.version
    }

    /// 检查组件版本是否满足要求
    func isComponentVersionSatisfied(_ name: String, minVersion: String) -> Bool {
        guard let installed = versionFile.components[name] else {
            return false
        }
        return compareVersions(installed.version, minVersion) >= 0
    }

    /// 获取组件的 SHA256
    func getComponentSha256(_ name: String) -> String? {
        versionFile.components[name]?.sha256
    }

    // MARK: - 插件查询

    /// 检查插件是否已安装（兼容旧代码，检查文件存在性）
    func isPluginInstalled(_ id: String) -> Bool {
        isPluginFileExists(id)
    }

    /// 获取已安装插件的版本
    func getPluginVersion(_ id: String) -> String? {
        versionFile.plugins[id]?.version
    }

    /// 获取插件状态（用于 UI 显示）
    /// - Parameters:
    ///   - id: 插件 ID
    ///   - remoteVersion: 远程版本号
    /// - Returns: 插件状态
    func getPluginStatus(id: String, remoteVersion: String) -> PluginStatus {
        let fileExists = isPluginFileExists(id)

        guard fileExists else {
            // 插件文件不存在 → notInstalled
            return .notInstalled
        }

        // 插件文件存在，检查版本记录
        guard let localVersion = versionFile.plugins[id]?.version else {
            // 文件存在但 version.json 无记录 → 视为本地 build，已安装
            return .installed
        }

        // 比较版本
        if compareVersions(localVersion, remoteVersion) < 0 {
            // 本地版本 < 远程版本 → 有更新
            return .updateAvailable(from: localVersion, to: remoteVersion)
        }

        // 版本 >= 远程版本 → 已安装
        return .installed
    }

    /// 检查插件文件是否存在
    private func isPluginFileExists(_ id: String) -> Bool {
        let pluginDir = ETermPaths.plugins + "/\(id)"
        return FileManager.default.fileExists(atPath: pluginDir)
    }

    // MARK: - 组件注册

    /// 注册已安装的组件
    func registerComponent(
        name: String,
        version: String,
        sha256: String?,
        installedBy: String
    ) {
        versionFile.components[name] = InstalledComponent(
            version: version,
            sha256: sha256,
            installedBy: installedBy,
            installedAt: Date()
        )
        save()
    }

    /// 注销组件
    func unregisterComponent(_ name: String) {
        versionFile.components.removeValue(forKey: name)
        save()
    }

    // MARK: - 插件注册

    /// 注册已安装的插件
    func registerPlugin(id: String, version: String) {
        versionFile.plugins[id] = InstalledPlugin(
            version: version,
            installedAt: Date()
        )
        save()
    }

    /// 注销插件
    func unregisterPlugin(_ id: String) {
        versionFile.plugins.removeValue(forKey: id)
        save()
    }

    // MARK: - 私有方法

    private static func loadVersionFile(from path: String) -> VersionFile {
        guard FileManager.default.fileExists(atPath: path) else {
            return VersionFile()
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VersionFile.self, from: data)
        } catch {
            return VersionFile()
        }
    }

    private func save() {
        do {
            try ETermPaths.ensureParentDirectory(for: versionFilePath)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(versionFile)

            try data.write(to: URL(fileURLWithPath: versionFilePath))
        } catch {
            // 保存失败，静默处理
        }
    }

    /// 简单的版本比较（支持 semver 格式）
    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 != p2 {
                return p1 - p2
            }
        }
        return 0
    }
}
