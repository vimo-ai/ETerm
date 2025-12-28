//
//  FileSnapshotStore.swift
//  HistoryKit
//
//  基于文件系统的快照存储实现

import Foundation
import Compression
import ETermKit

// MARK: - FileSnapshotStore

/// 基于文件系统的快照存储
public actor FileSnapshotStore: SnapshotStore {

    /// 历史数据根目录 ($ETERM_HOME/history/)
    private let historyRoot: URL

    /// 目录扫描器
    private let scanner: DirectoryScanner

    /// 上次快照时间（用于防抖）
    private var lastSnapshotTime: [String: Date] = [:]

    /// 防抖间隔（秒）
    private let debounceInterval: TimeInterval = 30

    public init() {
        self.historyRoot = URL(fileURLWithPath: ETermPaths.root)
            .appendingPathComponent("history")
        self.scanner = DirectoryScanner()

        // 确保根目录存在
        try? FileManager.default.createDirectory(
            at: historyRoot,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    /// 检查是否应该创建快照（防抖）
    public func shouldSnapshot(cwd: String) -> Bool {
        guard let last = lastSnapshotTime[cwd] else { return true }
        return Date().timeIntervalSince(last) > debounceInterval
    }

    public func createSnapshot(
        projectPath: String,
        label: String?,
        source: String?
    ) async throws -> Snapshot {
        let hash = projectHash(for: projectPath)
        let snapshotId = String(Int(Date().timeIntervalSince1970 * 1000))

        // 1. 获取上一个快照的 manifest（用于增量比较）
        let lastManifest = await getLastManifest(projectHash: hash)
        let lastFiles: [String: FileEntry] = lastManifest?.files.reduce(into: [:]) { $0[$1.path] = $1 } ?? [:]

        // 2. 扫描目录
        let currentFiles = try scanner.scan(projectPath: projectPath)

        // 3. 比较差异，决定哪些文件需要存储
        var fileEntries: [FileEntry] = []
        var changedCount = 0
        var storedSize: Int64 = 0

        for file in currentFiles {
            if let last = lastFiles[file.path],
               last.size == file.size && last.mtime == file.mtime {
                // 未变化，引用上一个快照
                let referenceId = last.stored ? lastManifest!.id : last.reference
                fileEntries.append(FileEntry(
                    path: file.path,
                    size: file.size,
                    mtime: file.mtime,
                    mode: file.mode,
                    stored: false,
                    reference: referenceId
                ))
            } else {
                // 变化了，需要存储
                changedCount += 1
                let compressedSize = try storeFile(
                    projectHash: hash,
                    snapshotId: snapshotId,
                    file: file
                )
                storedSize += compressedSize

                fileEntries.append(FileEntry(
                    path: file.path,
                    size: file.size,
                    mtime: file.mtime,
                    mode: file.mode,
                    stored: true,
                    reference: nil
                ))
            }
        }

        // 4. 保存 manifest
        let manifest = SnapshotManifest(
            id: snapshotId,
            timestamp: Date(),
            label: label,
            source: source,
            files: fileEntries,
            stats: SnapshotStats(
                totalFiles: fileEntries.count,
                changedFiles: changedCount,
                storedSize: storedSize
            )
        )
        try saveManifest(projectHash: hash, manifest: manifest)

        // 5. 更新防抖时间
        lastSnapshotTime[projectPath] = Date()

        // 6. 触发清理（异步，不阻塞）
        Task.detached(priority: .background) { [self] in
            try? await self.cleanup(projectPath: projectPath, keepCount: 50)
        }

        return Snapshot(from: manifest)
    }

    public func listSnapshots(
        projectPath: String,
        limit: Int
    ) async -> [Snapshot] {
        let hash = projectHash(for: projectPath)
        let snapshotsDir = projectDir(for: hash).appendingPathComponent("snapshots")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // 获取所有快照目录（按时间戳倒序）
        let snapshotDirs = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)

        var snapshots: [Snapshot] = []

        for dir in snapshotDirs {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data) {
                snapshots.append(Snapshot(from: manifest))
            }
        }

        return snapshots
    }

    public func getSnapshot(
        projectPath: String,
        snapshotId: String
    ) async -> SnapshotManifest? {
        let hash = projectHash(for: projectPath)
        return getManifest(projectHash: hash, snapshotId: snapshotId)
    }

    public func restoreSnapshot(
        projectPath: String,
        snapshotId: String
    ) async throws {
        let hash = projectHash(for: projectPath)

        // 1. 先创建一个备份快照
        _ = try await createSnapshot(
            projectPath: projectPath,
            label: "pre-restore-backup",
            source: "history-kit"
        )

        // 2. 加载目标 manifest
        guard let manifest = getManifest(projectHash: hash, snapshotId: snapshotId) else {
            throw HistoryError.snapshotNotFound
        }

        // 3. 恢复每个文件
        for file in manifest.files {
            let content = try loadFileContent(
                projectHash: hash,
                snapshotId: snapshotId,
                file: file
            )

            let targetPath = URL(fileURLWithPath: projectPath)
                .appendingPathComponent(file.path)

            // 确保目录存在
            try FileManager.default.createDirectory(
                at: targetPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // 写入文件
            try content.write(to: targetPath)

            // 恢复权限
            try FileManager.default.setAttributes(
                [.posixPermissions: file.mode],
                ofItemAtPath: targetPath.path
            )
        }

        // 4. 删除目标快照中不存在的文件
        let manifestPaths = Set(manifest.files.map { $0.path })
        let currentFiles = try scanner.scan(projectPath: projectPath)

        for current in currentFiles {
            if !manifestPaths.contains(current.path) {
                try? FileManager.default.removeItem(at: current.absolutePath)
            }
        }
    }

    public func deleteSnapshot(
        projectPath: String,
        snapshotId: String
    ) async throws {
        let hash = projectHash(for: projectPath)
        let snapshotDir = projectDir(for: hash)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(snapshotId)

        try FileManager.default.removeItem(at: snapshotDir)
    }

    public func cleanup(
        projectPath: String,
        keepCount: Int
    ) async throws {
        let hash = projectHash(for: projectPath)
        let snapshotsDir = projectDir(for: hash).appendingPathComponent("snapshots")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // 获取所有快照目录（按时间戳排序）
        let snapshotDirs = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        // 删除超出保留数量的快照
        if snapshotDirs.count > keepCount {
            let toDelete = snapshotDirs.suffix(from: keepCount)
            for dir in toDelete {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    // MARK: - Private Helpers

    /// 项目目录
    private func projectDir(for projectHash: String) -> URL {
        historyRoot
            .appendingPathComponent("projects")
            .appendingPathComponent(projectHash)
    }

    /// 获取最新的 manifest
    private func getLastManifest(projectHash: String) async -> SnapshotManifest? {
        let snapshotsDir = projectDir(for: projectHash).appendingPathComponent("snapshots")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // 找到最新的快照目录
        let latestDir = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .max { $0.lastPathComponent < $1.lastPathComponent }

        guard let dir = latestDir else { return nil }

        return getManifest(atDir: dir)
    }

    /// 获取指定快照的 manifest
    private func getManifest(projectHash: String, snapshotId: String) -> SnapshotManifest? {
        let snapshotDir = projectDir(for: projectHash)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(snapshotId)
        return getManifest(atDir: snapshotDir)
    }

    /// 从目录读取 manifest
    private func getManifest(atDir dir: URL) -> SnapshotManifest? {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(SnapshotManifest.self, from: data)
    }

    /// 保存 manifest
    private func saveManifest(projectHash: String, manifest: SnapshotManifest) throws {
        let snapshotDir = projectDir(for: projectHash)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(manifest.id)

        try FileManager.default.createDirectory(
            at: snapshotDir,
            withIntermediateDirectories: true
        )

        let manifestURL = snapshotDir.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)
    }

    /// 存储文件（压缩，失败时 fallback 到原始存储）
    private func storeFile(
        projectHash: String,
        snapshotId: String,
        file: ScannedFile
    ) throws -> Int64 {
        // 读取文件内容
        let data = try Data(contentsOf: file.absolutePath)

        // 尝试压缩，失败时 fallback
        let (storedData, isCompressed) = compressWithFallback(data)

        // 构建存储路径（根据是否压缩选择后缀）
        let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file.path
        let suffix = isCompressed ? ".gz" : ".raw"
        let storePath = projectDir(for: projectHash)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(snapshotId)
            .appendingPathComponent("files")
            .appendingPathComponent(encodedPath + suffix)

        // 确保目录存在
        try FileManager.default.createDirectory(
            at: storePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 写入文件
        try storedData.write(to: storePath)

        return Int64(storedData.count)
    }

    /// 压缩数据，失败时返回原始数据
    private func compressWithFallback(_ data: Data) -> (Data, Bool) {
        do {
            let compressed = try compress(data)
            return (compressed, true)
        } catch {
            // 压缩失败，返回原始数据
            return (data, false)
        }
    }

    /// 加载文件内容（解压）
    private func loadFileContent(projectHash: String, file: FileEntry) throws -> Data {
        // 确定快照 ID
        let snapshotId: String
        if file.stored {
            // 这个文件存储在某个快照中，但我们需要知道是哪个快照
            // 由于 stored=true 意味着当前快照存储了这个文件，我们需要从调用者获取快照 ID
            // 这里假设调用者会传入正确的上下文
            throw HistoryError.fileNotFound(file.path)
        } else {
            guard let ref = file.reference else {
                throw HistoryError.fileNotFound(file.path)
            }
            snapshotId = ref
        }

        let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file.path
        let storePath = projectDir(for: projectHash)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(snapshotId)
            .appendingPathComponent("files")
            .appendingPathComponent(encodedPath + ".gz")

        let compressed = try Data(contentsOf: storePath)
        return try decompress(compressed)
    }

    /// 从快照恢复文件内容（需要快照 ID，支持 .gz 和 .raw 格式）
    private func loadFileContent(
        projectHash: String,
        snapshotId: String,
        file: FileEntry
    ) throws -> Data {
        // 确定实际存储位置
        let actualSnapshotId = file.stored ? snapshotId : (file.reference ?? snapshotId)

        let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file.path
        let baseStorePath = projectDir(for: projectHash)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(actualSnapshotId)
            .appendingPathComponent("files")
            .appendingPathComponent(encodedPath)

        // 优先尝试 .gz（压缩格式）
        let gzPath = baseStorePath.appendingPathExtension("gz")
        if FileManager.default.fileExists(atPath: gzPath.path) {
            let compressed = try Data(contentsOf: gzPath)
            return try decompress(compressed)
        }

        // 再尝试 .raw（未压缩格式）
        let rawPath = baseStorePath.appendingPathExtension("raw")
        if FileManager.default.fileExists(atPath: rawPath.path) {
            return try Data(contentsOf: rawPath)
        }

        throw HistoryError.fileNotFound(file.path)
    }

    // MARK: - Compression

    /// 压缩数据（动态分配缓冲区）
    private func compress(_ data: Data) throws -> Data {
        // zlib 最坏情况：源数据 + 0.1% + 12 字节
        // 使用更保守的估算：源数据 * 1.01 + 1024
        let destinationSize = Int(Double(data.count) * 1.01) + 1024
        var compressedData = Data()

        let sourceBuffer = [UInt8](data)
        var destinationBuffer = [UInt8](repeating: 0, count: destinationSize)

        let algorithm = COMPRESSION_ZLIB
        let compressedSize = compression_encode_buffer(
            &destinationBuffer,
            destinationBuffer.count,
            sourceBuffer,
            sourceBuffer.count,
            nil,
            algorithm
        )

        guard compressedSize > 0 else {
            throw HistoryError.compressionFailed
        }

        compressedData.append(contentsOf: destinationBuffer.prefix(compressedSize))
        return compressedData
    }

    /// 解压数据（动态分配缓冲区，支持重试扩容）
    private func decompress(_ data: Data) throws -> Data {
        let sourceBuffer = [UInt8](data)
        let algorithm = COMPRESSION_ZLIB

        // 从保守估算开始，失败时扩容重试
        var multiplier = 10
        let maxMultiplier = 100  // 最大 100 倍（10MB 压缩数据 → 1GB 解压上限）

        while multiplier <= maxMultiplier {
            let estimatedSize = max(data.count * multiplier, 1024 * 1024)
            var destinationBuffer = [UInt8](repeating: 0, count: estimatedSize)

            let decompressedSize = compression_decode_buffer(
                &destinationBuffer,
                destinationBuffer.count,
                sourceBuffer,
                sourceBuffer.count,
                nil,
                algorithm
            )

            if decompressedSize > 0 {
                var decompressedData = Data()
                decompressedData.append(contentsOf: destinationBuffer.prefix(decompressedSize))
                return decompressedData
            }

            // 缓冲区可能不够，扩容重试
            multiplier *= 2
        }

        throw HistoryError.decompressionFailed
    }
}

// MARK: - Restore Helper

extension FileSnapshotStore {
    /// 从指定快照恢复（内部使用，知道快照 ID）
    func restoreFile(
        projectPath: String,
        snapshotId: String,
        file: FileEntry
    ) throws -> Data {
        let hash = projectHash(for: projectPath)
        return try loadFileContent(projectHash: hash, snapshotId: snapshotId, file: file)
    }
}
