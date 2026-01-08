//
//  PluginDownloader.swift
//  ETerm
//
//  插件下载器 - 下载、校验、原子安装
//

import Foundation
import Combine

/// 下载进度
struct DownloadProgress {
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let currentFile: String

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: bytesDownloaded)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(downloaded) / \(total)"
    }
}

/// 下载错误
enum DownloadError: LocalizedError {
    case networkError(Error)
    case sha256Mismatch(expected: String, actual: String)
    case installFailed(String)
    case cancelled
    case invalidUrl(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
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
}

/// 安装结果
struct InstallResult {
    let pluginId: String
    let success: Bool
    let error: DownloadError?
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
    @Published var errorMessage: String?
    @Published var lastFailedPluginId: String?

    private let versionManager = VersionManager.shared
    private let fileManager = FileManager.default
    private var downloadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

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
            } catch let error as DownloadError {
                await MainActor.run {
                    self.errorMessage = error.errorDescription
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
        errorMessage = "下载已取消"
        resetState()
    }

    /// 清除错误状态
    func clearError() {
        errorMessage = nil
        lastFailedPluginId = nil
    }

    /// 同步安装插件（用于批量安装场景，如 OnboardingView）
    /// - Parameters:
    ///   - plugin: 可下载的插件信息
    ///   - progressHandler: 进度回调（0.0 ~ 1.0）
    /// - Returns: 安装结果
    func installPlugin(
        _ plugin: DownloadablePlugin,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> InstallResult {
        // 设置进度回调（临时存储）
        let originalHandler = self.batchProgressHandler
        self.batchProgressHandler = progressHandler
        defer { self.batchProgressHandler = originalHandler }

        return try await performInstall(plugin)
    }

    /// 批量安装的进度回调（临时存储）
    private var batchProgressHandler: ((Double) -> Void)?

    private func resetState() {
        isDownloading = false
        downloadingPluginId = nil
        currentFileName = nil
    }

    /// 执行安装（内部方法）
    private func performInstall(_ plugin: DownloadablePlugin) async throws -> InstallResult {
        // 检查取消
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
    /// - Parameter pluginId: 插件 ID
    func uninstallPlugin(_ pluginId: String) throws {
        let pluginDir = ETermPaths.plugins + "/\(pluginId)"

        // 删除插件目录
        if fileManager.fileExists(atPath: pluginDir) {
            try fileManager.removeItem(atPath: pluginDir)
        }

        // 注销插件
        versionManager.unregisterPlugin(pluginId)

        // 注意：不删除共享组件（lib/, bin/），因为可能被其他插件使用
    }

    // MARK: - 私有方法

    /// 安装组件
    private func installComponent(
        _ dep: RuntimeDependency,
        installedBy: String
    ) async throws {
        guard let urlString = dep.downloadUrl else {
            throw DownloadError.invalidUrl(dep.downloadUrl ?? "nil")
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
            throw DownloadError.invalidUrl(url)
        }

        // 确保目标目录存在
        let targetDir = (targetPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        // 临时文件路径
        let tmpDir = ETermPaths.vimoRoot + "/tmp"
        try fileManager.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let tmpPath = tmpDir + "/\(UUID().uuidString).downloading"

        defer {
            // 清理临时文件
            try? fileManager.removeItem(atPath: tmpPath)
        }

        // 下载到临时文件（进度会自动更新到全局状态）
        try await downloadWithProgress(
            from: downloadUrl,
            to: tmpPath,
            fileName: (url as NSString).lastPathComponent
        )

        // 校验 SHA256
        if let expectedSha256 = sha256 {
            let actualSha256 = try calculateSha256(of: tmpPath)
            if actualSha256.lowercased() != expectedSha256.lowercased() {
                throw DownloadError.sha256Mismatch(expected: expectedSha256, actual: actualSha256)
            }
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
                // 没有 bundle，可能是直接解压的文件
                finalPath = extractDir
            }
        } else {
            finalPath = tmpPath
        }

        // 原子安装：删除旧文件，移动新文件
        if fileManager.fileExists(atPath: targetPath) {
            try fileManager.removeItem(atPath: targetPath)
        }
        try fileManager.moveItem(atPath: finalPath, toPath: targetPath)
    }

    /// 计算文件的 SHA256
    private func calculateSha256(of path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.sha256String
    }

    /// 解压 zip 文件
    private func unzip(_ zipPath: String, to destination: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipPath, "-d", destination]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw DownloadError.installFailed("解压失败")
        }
    }

    /// 带进度的下载（直接更新全局状态）
    private func downloadWithProgress(
        from url: URL,
        to destinationPath: String,
        fileName: String
    ) async throws {
        // 更新当前文件名
        await MainActor.run {
            self.currentFileName = fileName
            self.downloadProgress = 0
        }

        let request = URLRequest(url: url)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.networkError(
                NSError(domain: "HTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
            )
        }

        let totalBytes = response.expectedContentLength
        var downloadedBytes: Int64 = 0

        // 创建输出文件
        FileManager.default.createFile(atPath: destinationPath, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: destinationPath) else {
            throw DownloadError.installFailed("无法创建临时文件")
        }

        defer {
            try? fileHandle.close()
        }

        // 批量写入 buffer
        let bufferSize = 65536 // 64KB
        var buffer = Data(capacity: bufferSize)

        // 流式下载并报告进度
        for try await byte in asyncBytes {
            // 检查取消
            try Task.checkCancellation()

            buffer.append(byte)
            downloadedBytes += 1

            // buffer 满了就写入文件并报告进度
            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
                await MainActor.run {
                    self.downloadProgress = progress
                    self.batchProgressHandler?(progress)
                }
            }
        }

        // 写入剩余数据
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }

        // 完成
        await MainActor.run {
            self.downloadProgress = 1.0
        }
    }
}

// MARK: - Data SHA256 扩展

import CommonCrypto

extension Data {
    var sha256String: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
