//
//  DistributionManifest.swift
//  ETerm
//
//  分发相关的数据模型
//

import Foundation

/// 分发信息（manifest 中的 distribution 字段）
struct DistributionInfo: Codable {
    let description: String?
    let size: Int64?
    let sha256: String?
    let runtimeDeps: [RuntimeDependency]?

    enum CodingKeys: String, CodingKey {
        case description
        case size
        case sha256
        case runtimeDeps = "runtime_deps"
    }
}

/// 运行时依赖
struct RuntimeDependency: Codable {
    /// 组件名称，如 "libai_cli_session_db"
    let name: String
    /// 最低版本要求
    let minVersion: String
    /// 安装路径（相对于 ~/.vimo/），如 "lib/libai_cli_session_db.dylib"
    let path: String
    /// SHA256 校验值（CI 自动填充）
    let sha256: String?
    /// 下载地址（CI 自动填充）
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case minVersion = "min_version"
        case path
        case sha256
        case downloadUrl = "download_url"
    }
}

/// 可下载插件信息（用于插件市场列表）
struct DownloadablePlugin: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let size: Int64?
    let downloadUrl: String
    let sha256: String?
    let runtimeDeps: [RuntimeDependency]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case description
        case size
        case downloadUrl = "download_url"
        case sha256
        case runtimeDeps = "runtime_deps"
    }

    /// 格式化的大小显示
    var formattedSize: String {
        guard let size = size else { return "未知" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

/// 插件索引（从远程获取的可用插件列表）
struct PluginIndex: Codable {
    let version: String
    let plugins: [DownloadablePlugin]
}
