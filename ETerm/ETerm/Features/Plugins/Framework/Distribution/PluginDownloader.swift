//
//  PluginDownloader.swift
//  ETerm
//
//  插件下载器 - 基于 CoreNetworkKit.DownloadClient
//

import Foundation
import Combine
import CoreNetworkKit

/// 插件下载进度（包装 CoreNetworkKit.DownloadProgress）
struct PluginDownloadProgress {
    let bytesDownloaded: Int64
    let totalBytes: Int64?
    let currentFile: String
    let speed: Int64
    let estimatedTimeRemaining: TimeInterval?

    var progress: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(total)
    }

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: bytesDownloaded)
        if let total = totalBytes {
            let totalStr = formatter.string(fromByteCount: total)
            return "\(downloaded) / \(totalStr)"
        }
        return downloaded
    }

    var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: speed) + "/s"
    }
}

/// 插件下载错误
enum PluginDownloadError: LocalizedError {
    case networkError(String)
    case sha256Mismatch(expected: String, actual: String)
    case installFailed(String)
    case cancelled
    case invalidUrl(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "网络错误: \(message)"
        case .sha256Mismatch(let expected, let actual):
            return "校验失败: 期望 \(expected.prefix(8))..., 实际 \(actual.prefix(8))..."
        case .installFailed(let reason):
            return "安装失败: \(reason)"
        case .cancelled:
            return "下载已取消"
        case .invalidUrl(let url):
            return "无效的下载地址: \(url)"
        case .fileNotFound(let path):
            return "文件不存在: \(path)"
        }
    }

    /// 从 CoreNetworkKit.DownloadError 转换
    init(from error: DownloadError) {
        switch error {
        case .sha256Mismatch(let expected, let actual, _):
            self = .sha256Mismatch(expected: expected, actual: actual)
        case .cancelled:
            self = .cancelled
        case .fileNotFound(let path):
            self = .fileNotFound(path)
        case .invalidURL(let url):
            self = .invalidUrl(url)
        default:
            self = .networkError(error.localizedDescription)
        }
    }
}

/// 安装结果
struct InstallResult {
    let pluginId: String
    let success: Bool
    let error: PluginDownloadError?
    let installedComponents: [String]
    let skippedComponents: [String]
}

/// 插件下载器
final class PluginDownloader: ObservableObject {
    static let shared = PluginDownloader()

    // MARK: - 全局下载状态（View 观察这些属性）

    @Published var isDownloading = false
    @Published var downloadingPluginId: String?
    @Published var downloadProgress: Double = 0
    @Published var currentFileName: String?
    @Published var downloadSpeed: String?
    @Published var estimatedTime: String?
    @Published var errorMessage: String?
    @Published var lastFailedPluginId: String?

    private let versionManager = VersionManager.shared
    private let fileManager = FileManager.default
    private var downloadTask: Task<Void, Never>?

    /// CoreNetworkKit 下载客户端
    private let downloadClient: DownloadClient

    private init() {
        // 配置下载客户端：10 分钟资源超时（大文件），3 次重试
        let config = DownloadClient.Configuration(
            requestTimeout: 30,
            resourceTimeout: 600,
            maxRetries: 3,
            retryBaseDelay: 2.0,
            progressUpdateInterval: 0.1
        )
        self.downloadClient = DownloadClient(configuration: config)
    }

    // MARK: - 公开 API

    /// 开始安装插件（非阻塞，状态通过 @Published 属性发布）
    func startInstall(_ plugin: DownloadablePlugin) {
        // 如果已经在下载，忽略
        guard !isDownloading else { return }

        // 重置状态
        isDownloading = true
        downloadingPluginId = plugin.id
        downloadProgress = 0
        currentFileName = nil
        downloadSpeed = nil
        estimatedTime = nil
        errorMessage = nil
        lastFailedPluginId = nil

        // 启动下载任务
        downloadTask = Task {
            do {
                let result = try await performInstall(plugin)
                await MainActor.run {
                    if result.success {
                        PluginManager.shared.objectWillChange.send()
                    }
                    self.resetState()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.errorMessage = "下载已取消"
                    self.resetState()
                }
            } catch let error as PluginDownloadError {
                await MainActor.run {
                    self.errorMessage = error.errorDescription
                    self.lastFailedPluginId = plugin.id
                    self.resetState()
                }
            } catch let error as DownloadError {
                await MainActor.run {
                    self.errorMessage = PluginDownloadError(from: error).errorDescription
                    self.lastFailedPluginId = plugin.id
                    self.resetState()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.lastFailedPluginId = plugin.id
                    self.resetState()
                }
            }
        }
    }

    /// 取消当前下载
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil

        // 取消正在进行的下载
        if let url = currentDownloadURL {
            downloadClient.cancelDownload(for: url)
        }

        errorMessage = "下载已取消"
        resetState()
    }

    /// 清除错误状态
    func clearError() {
        errorMessage = nil
        lastFailedPluginId = nil
    }

    /// 同步安装插件（用于批量安装场景，如 OnboardingView）
    func installPlugin(
        _ plugin: DownloadablePlugin,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> InstallResult {
        let originalHandler = self.batchProgressHandler
        self.batchProgressHandler = progressHandler
        defer { self.batchProgressHandler = originalHandler }

        return try await performInstall(plugin)
    }

    /// 批量安装的进度回调（临时存储）
    private var batchProgressHandler: ((Double) -> Void)?

    /// 当前下载的 URL（用于取消）
    private var currentDownloadURL: URL?

    private func resetState() {
        isDownloading = false
        downloadingPluginId = nil
        currentFileName = nil
        downloadSpeed = nil
        estimatedTime = nil
        currentDownloadURL = nil
    }

    /// 执行安装（内部方法）
    private func performInstall(_ plugin: DownloadablePlugin) async throws -> InstallResult {
        try Task.checkCancellation()

        var installedComponents: [String] = []
        var skippedComponents: [String] = []

        // 1. 安装运行时依赖
        if let deps = plugin.runtimeDeps {
            for dep in deps {
                try Task.checkCancellation()

                // 检查是否已安装且版本满足
                if versionManager.isComponentVersionSatisfied(dep.name, minVersion: dep.minVersion) {
                    skippedComponents.append(dep.name)
                    continue
                }

                // 下载并安装组件
                try await installComponent(dep, installedBy: plugin.id)
                installedComponents.append(dep.name)
            }
        }

        try Task.checkCancellation()

        // 2. 下载插件 bundle
        let bundleUrl = plugin.downloadUrl
        let pluginDir = ETermPaths.plugins + "/\(plugin.id)"
        let bundlePath = pluginDir + "/\(plugin.name).bundle"

        try await downloadAndInstall(
            url: bundleUrl,
            targetPath: bundlePath,
            sha256: plugin.sha256
        )

        // 3. 注册插件
        versionManager.registerPlugin(id: plugin.id, version: plugin.version)

        return InstallResult(
            pluginId: plugin.id,
            success: true,
            error: nil,
            installedComponents: installedComponents,
            skippedComponents: skippedComponents
        )
    }

    /// 卸载插件
    func uninstallPlugin(_ pluginId: String) throws {
        let pluginDir = ETermPaths.plugins + "/\(pluginId)"

        if fileManager.fileExists(atPath: pluginDir) {
            try fileManager.removeItem(atPath: pluginDir)
        }

        versionManager.unregisterPlugin(pluginId)
    }

    // MARK: - 私有方法

    /// 安装组件
    private func installComponent(
        _ dep: RuntimeDependency,
        installedBy: String
    ) async throws {
        guard let urlString = dep.downloadUrl else {
            throw PluginDownloadError.invalidUrl(dep.downloadUrl ?? "nil")
        }

        let targetPath = ETermPaths.vimoRoot + "/" + dep.path

        try await downloadAndInstall(
            url: urlString,
            targetPath: targetPath,
            sha256: dep.sha256
        )

        // 如果是可执行文件，添加执行权限
        if dep.path.hasPrefix("bin/") {
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: targetPath
            )
        }

        // 注册组件
        versionManager.registerComponent(
            name: dep.name,
            version: dep.minVersion,
            sha256: dep.sha256,
            installedBy: installedBy
        )
    }

    /// 下载并原子安装
    private func downloadAndInstall(
        url: String,
        targetPath: String,
        sha256: String?
    ) async throws {
        guard let downloadUrl = URL(string: url) else {
            throw PluginDownloadError.invalidUrl(url)
        }

        // 确保目标目录存在
        let targetDir = (targetPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        // 临时文件路径
        let tmpDir = ETermPaths.vimoRoot + "/tmp"
        try fileManager.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let tmpPath = tmpDir + "/\(UUID().uuidString).downloading"
        let tmpURL = URL(fileURLWithPath: tmpPath)

        defer {
            try? fileManager.removeItem(atPath: tmpPath)
        }

        // 记录当前下载 URL（用于取消）
        currentDownloadURL = downloadUrl
        let fileName = downloadUrl.lastPathComponent

        // 更新 UI 状态
        await MainActor.run {
            self.currentFileName = fileName
            self.downloadProgress = 0
        }

        // 使用 CoreNetworkKit 下载（带 SHA256 校验）
        do {
            _ = try await downloadClient.download(
                from: downloadUrl,
                to: tmpURL,
                expectedSHA256: sha256
            ) { [weak self] progress in
                guard let self = self else { return }

                Task { @MainActor in
                    self.downloadProgress = progress.fractionCompleted
                    self.downloadSpeed = progress.formattedSpeed
                    self.estimatedTime = progress.formattedTimeRemaining
                    self.batchProgressHandler?(progress.fractionCompleted)
                }
            }
        } catch let error as DownloadError {
            throw PluginDownloadError(from: error)
        }

        // 解压（如果是 zip）
        let finalPath: String
        if url.hasSuffix(".zip") {
            let extractDir = tmpDir + "/\(UUID().uuidString).extracted"
            try await unzip(tmpPath, to: extractDir)

            // 查找解压出的 .bundle 文件
            let contents = try fileManager.contentsOfDirectory(atPath: extractDir)
            if let bundleName = contents.first(where: { $0.hasSuffix(".bundle") }) {
                finalPath = extractDir + "/" + bundleName
            } else {
                finalPath = extractDir
            }
        } else {
            finalPath = tmpPath
        }

        // 原子安装
        if fileManager.fileExists(atPath: targetPath) {
            try fileManager.removeItem(atPath: targetPath)
        }
        try fileManager.moveItem(atPath: finalPath, toPath: targetPath)

        // 完成
        await MainActor.run {
            self.downloadProgress = 1.0
        }
    }

    /// 解压 zip 文件
    private func unzip(_ zipPath: String, to destination: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipPath, "-d", destination]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw PluginDownloadError.installFailed("解压失败")
        }
    }
}
