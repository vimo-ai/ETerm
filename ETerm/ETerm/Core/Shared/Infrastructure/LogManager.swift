//
//  LogManager.swift
//  ETerm
//
//  统一的日志管理
//  支持日志级别、文件输出、调试模式
//

import Foundation

/// 日志级别
enum LogLevel: String, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warn: return "⚠️"
        case .error: return "❌"
        }
    }

    /// 级别优先级（用于比较）
    var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.priority < rhs.priority
    }
}

/// 统一日志管理器
class LogManager {

    // MARK: - Singleton

    static let shared = LogManager()

    // MARK: - Properties

    /// 是否启用调试输出到 stderr
    var debugEnabled: Bool = false

    /// 是否启用文件日志
    var fileLoggingEnabled: Bool = true

    /// 最小日志级别（低于此级别的日志会被忽略）
    /// - debug: 记录所有日志
    /// - info: 忽略 debug
    /// - warn: 只记录 warn 和 error
    /// - error: 只记录 error
    var minimumLevel: LogLevel = .info

    /// 当前日志文件路径
    private var currentLogFile: String?

    /// 日志文件句柄
    private var fileHandle: FileHandle?

    /// 串行队列，保证线程安全
    private let queue = DispatchQueue(label: "com.eterm.log", qos: .background)

    // MARK: - Initialization

    private init() {
        setupLogFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    // MARK: - Setup

    /// 初始化日志文件
    private func setupLogFile() {
        do {
            try ETermPaths.ensureDirectory(ETermPaths.logs)

            let logFilePath = ETermPaths.logFile()
            currentLogFile = logFilePath

            let fileManager = FileManager.default

            // 如果文件不存在，创建它
            if !fileManager.fileExists(atPath: logFilePath) {
                fileManager.createFile(atPath: logFilePath, contents: nil, attributes: nil)
            }

            // 打开文件句柄（追加模式）
            fileHandle = FileHandle(forWritingAtPath: logFilePath)
            fileHandle?.seekToEndOfFile()

        } catch {
            // 日志系统初始化失败，输出到 stderr
            fputs("❌ LogManager setup failed: \(error)\n", stderr)
        }
    }

    // MARK: - Public Logging Methods

    /// 记录 debug 日志
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .debug, file: file, function: function, line: line)
    }

    /// 记录 info 日志
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, file: file, function: function, line: line)
    }

    /// 记录 warn 日志
    func warn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .warn, file: file, function: function, line: line)
    }

    /// 记录 error 日志
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, file: file, function: function, line: line)
    }

    // MARK: - Core Logging

    /// 核心日志方法
    private func log(
        _ message: String,
        level: LogLevel,
        file: String,
        function: String,
        line: Int
    ) {
        // 级别过滤
        guard level >= minimumLevel else { return }

        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.formatTimestamp()
            let fileName = (file as NSString).lastPathComponent
            let location = "\(fileName):\(line) \(function)"

            // 格式：[时间] [级别] [位置] 消息
            let logMessage = "[\(timestamp)] [\(level.rawValue)] [\(location)] \(message)\n"

            // 输出到 stderr（调试模式）
            if self.debugEnabled {
                let consoleMessage = "\(level.emoji) [\(level.rawValue)] \(message)\n"
                fputs(consoleMessage, stderr)
            }

            // 输出到文件
            if self.fileLoggingEnabled, let data = logMessage.data(using: .utf8) {
                self.writeToFile(data)
            }
        }
    }

    // MARK: - Helper Methods

    /// 格式化时间戳
    private func formatTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    /// 写入日志文件
    private func writeToFile(_ data: Data) {
        // 检查是否需要切换日志文件（跨天）
        let todayLogFile = ETermPaths.logFile()
        if currentLogFile != todayLogFile {
            setupLogFile()
        }

        // 写入数据
        fileHandle?.write(data)
    }

    // MARK: - File Management

    /// 清理旧日志（保留最近 N 天）
    func cleanOldLogs(keepDays: Int = 7) {
        queue.async {
            do {
                let fileManager = FileManager.default
                let logFiles = try fileManager.contentsOfDirectory(atPath: ETermPaths.logs)

                let calendar = Calendar.current
                let cutoffDate = calendar.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()

                for fileName in logFiles where fileName.hasPrefix("debug-") && fileName.hasSuffix(".log") {
                    let filePath = "\(ETermPaths.logs)/\(fileName)"

                    if let attributes = try? fileManager.attributesOfItem(atPath: filePath),
                       let modificationDate = attributes[.modificationDate] as? Date,
                       modificationDate < cutoffDate {

                        try? fileManager.removeItem(atPath: filePath)
                        LogManager.shared.info("Cleaned old log file: \(fileName)")
                    }
                }
            } catch {
                LogManager.shared.error("Failed to clean old logs: \(error)")
            }
        }
    }
}

// MARK: - Global Convenience Functions

/// 全局 debug 日志函数
func logDebug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    LogManager.shared.debug(message, file: file, function: function, line: line)
}

/// 全局 info 日志函数
func logInfo(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    LogManager.shared.info(message, file: file, function: function, line: line)
}

/// 全局 warn 日志函数
func logWarn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    LogManager.shared.warn(message, file: file, function: function, line: line)
}

/// 全局 error 日志函数
func logError(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    LogManager.shared.error(message, file: file, function: function, line: line)
}
