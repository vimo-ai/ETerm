//
//  EventLogWriter.swift
//  ETerm
//
//  事件网关 - 日志写入器
//  按天滚动，保留最近 7 天
//

import Foundation

/// 事件日志写入器
final class EventLogWriter {

    /// 日志目录
    private let logDirectory: String

    /// 当前日志文件句柄
    private var fileHandle: FileHandle?

    /// 当前日志文件日期
    private var currentDate: String?

    /// 写入队列
    private let writeQueue = DispatchQueue(label: "com.eterm.event-log-writer")

    /// 单文件最大大小（100MB）
    private let maxFileSize: UInt64 = 100 * 1024 * 1024

    /// 保留天数
    private let retentionDays = 7

    /// 日期格式器
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(logDirectory: String) {
        self.logDirectory = logDirectory
    }

    // MARK: - Lifecycle

    /// 启动日志写入器
    func start() {
        // 确保目录存在
        try? FileManager.default.createDirectory(
            atPath: logDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // 打开当天日志文件
        openCurrentLogFile()

        // 清理旧日志
        cleanupOldLogs()
    }

    /// 停止日志写入器
    func stop() {
        writeQueue.sync {
            closeCurrentLogFile()
        }
    }

    // MARK: - Writing

    /// 写入事件
    func write(_ event: GatewayEvent) {
        writeQueue.async { [weak self] in
            self?.doWrite(event)
        }
    }

    private func doWrite(_ event: GatewayEvent) {
        // 检查日期是否变化
        let today = dateFormatter.string(from: Date())
        if currentDate != today {
            closeCurrentLogFile()
            openCurrentLogFile()
        }

        // 检查文件大小
        if let handle = fileHandle {
            let currentSize = handle.offsetInFile
            if currentSize >= maxFileSize {
                rotateLogFile()
            }
        }

        // 写入事件
        guard let jsonLine = event.toJSONLine(),
              let data = jsonLine.data(using: .utf8),
              let handle = fileHandle else {
            return
        }

        handle.write(data)
    }

    // MARK: - File Management

    private func openCurrentLogFile() {
        let today = dateFormatter.string(from: Date())
        currentDate = today

        let filePath = logFilePath(for: today)

        // 创建文件（如果不存在）
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        }

        // 打开文件（追加模式）
        if let handle = FileHandle(forWritingAtPath: filePath) {
            handle.seekToEndOfFile()
            fileHandle = handle
        }
    }

    private func closeCurrentLogFile() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentDate = nil
    }

    /// 日志文件路径
    private func logFilePath(for date: String) -> String {
        return "\(logDirectory)/events.\(date).jsonl"
    }

    /// 日志滚动（文件过大时）
    private func rotateLogFile() {
        guard let date = currentDate else { return }

        closeCurrentLogFile()

        // 重命名当前文件（添加序号）
        let basePath = logFilePath(for: date)
        var sequence = 1

        while FileManager.default.fileExists(atPath: "\(basePath).\(sequence)") {
            sequence += 1
        }

        try? FileManager.default.moveItem(
            atPath: basePath,
            toPath: "\(basePath).\(sequence)"
        )

        // 打开新文件
        openCurrentLogFile()
    }

    /// 清理旧日志
    private func cleanupOldLogs() {
        let fileManager = FileManager.default
        let calendar = Calendar.current

        guard let contents = try? fileManager.contentsOfDirectory(atPath: logDirectory) else {
            return
        }

        let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()

        for filename in contents {
            // 匹配 events.YYYY-MM-DD.jsonl 格式
            guard filename.hasPrefix("events."),
                  filename.contains(".jsonl") else {
                continue
            }

            // 提取日期部分
            let components = filename.components(separatedBy: ".")
            guard components.count >= 3,
                  let fileDate = dateFormatter.date(from: components[1]) else {
                continue
            }

            // 删除过期文件
            if fileDate < cutoffDate {
                let filePath = "\(logDirectory)/\(filename)"
                try? fileManager.removeItem(atPath: filePath)
            }
        }
    }
}
