//
//  DebugSessionExporter.swift
//  ETerm
//
//  调试会话导出工具 - 提供多种导出格式和一键导出功能
//
//  使用方式：
//  1. 用户报 bug 时：DebugSessionExporter.shared.exportForBugReport()
//  2. 导出为测试用例：DebugSessionExporter.shared.exportAsTestCase(name: "test_xxx")
//

import Foundation
import AppKit
import ETermKit

// MARK: - 导出格式

/// 导出格式
enum ExportFormat {
    /// JSON 格式（完整会话）
    case json

    /// JSONL 格式（每行一个事件，流式）
    case jsonl

    /// Swift 测试代码
    case swiftTest

    /// Markdown 报告
    case markdown

    /// 压缩包（包含日志、会话、系统信息）
    case archive
}

// MARK: - 导出结果

/// 导出结果
struct ExportResult {
    let success: Bool
    let filePath: URL?
    let error: String?
    let fileSize: Int64?
}

// MARK: - 导出器

/// 调试会话导出器
final class DebugSessionExporter {

    // MARK: - 单例

    static let shared = DebugSessionExporter()

    // MARK: - 属性

    /// 导出目录
    private let exportDirectory: String

    /// 状态捕获器
    var snapshotProvider: (() -> StateSnapshot)?

    // MARK: - 初始化

    private init() {
        exportDirectory = ETermPaths.logs + "/exports"

        // 确保导出目录存在
        try? ETermPaths.ensureDirectory(exportDirectory)
    }

    // MARK: - 公共方法

    /// 一键导出 Bug 报告
    ///
    /// 导出包含：
    /// - 最近事件录制
    /// - 当前状态快照
    /// - 系统信息
    /// - 最近日志
    ///
    /// - Returns: 导出文件路径
    @discardableResult
    func exportForBugReport() -> ExportResult {
        let timestamp = formatTimestamp(Date())
        let folderName = "bug_report_\(timestamp)"
        let folderPath = "\(exportDirectory)/\(folderName)"

        do {
            // 创建报告目录
            try FileManager.default.createDirectory(
                atPath: folderPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // 1. 导出会话 JSON
            let session = SessionRecorder.shared.exportSession()
            let sessionPath = "\(folderPath)/session.json"
            try exportJSON(session, to: sessionPath)

            // 2. 导出系统信息
            let systemInfoPath = "\(folderPath)/system_info.json"
            try exportJSON(SystemInfo.current, to: systemInfoPath)

            // 3. 复制最近日志
            copyRecentLogs(to: folderPath)

            // 4. 生成 Markdown 报告
            let reportPath = "\(folderPath)/report.md"
            try generateMarkdownReport(session: session, to: reportPath)

            // 5. 创建压缩包
            let archivePath = "\(exportDirectory)/\(folderName).zip"
            try createArchive(from: folderPath, to: archivePath)

            // 清理临时目录
            try? FileManager.default.removeItem(atPath: folderPath)

            let fileSize = try FileManager.default.attributesOfItem(atPath: archivePath)[.size] as? Int64

            logInfo("[DebugSessionExporter] Bug 报告导出成功: \(archivePath)")

            return ExportResult(
                success: true,
                filePath: URL(fileURLWithPath: archivePath),
                error: nil,
                fileSize: fileSize
            )

        } catch {
            logError("[DebugSessionExporter] 导出失败: \(error)")
            return ExportResult(
                success: false,
                filePath: nil,
                error: error.localizedDescription,
                fileSize: nil
            )
        }
    }

    /// 导出为测试用例
    ///
    /// - Parameters:
    ///   - testName: 测试名称
    ///   - session: 会话（可选，默认使用当前录制）
    /// - Returns: 导出结果
    @discardableResult
    func exportAsTestCase(testName: String, session: DebugSession? = nil) -> ExportResult {
        let targetSession = session ?? SessionRecorder.shared.exportSession()
        let testCode = TestCaseGenerator.generateTestCase(from: targetSession, testName: testName)

        let timestamp = formatTimestamp(Date())
        let fileName = "test_\(testName)_\(timestamp).swift"
        let filePath = "\(exportDirectory)/\(fileName)"

        do {
            try testCode.write(toFile: filePath, atomically: true, encoding: .utf8)

            let fileSize = try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64

            logInfo("[DebugSessionExporter] 测试用例导出成功: \(filePath)")

            return ExportResult(
                success: true,
                filePath: URL(fileURLWithPath: filePath),
                error: nil,
                fileSize: fileSize
            )
        } catch {
            logError("[DebugSessionExporter] 测试用例导出失败: \(error)")
            return ExportResult(
                success: false,
                filePath: nil,
                error: error.localizedDescription,
                fileSize: nil
            )
        }
    }

    /// 导出指定格式
    ///
    /// - Parameters:
    ///   - format: 导出格式
    ///   - session: 会话（可选）
    ///   - fileName: 文件名（可选）
    /// - Returns: 导出结果
    @discardableResult
    func export(format: ExportFormat, session: DebugSession? = nil, fileName: String? = nil) -> ExportResult {
        let targetSession = session ?? SessionRecorder.shared.exportSession()
        let timestamp = formatTimestamp(Date())

        switch format {
        case .json:
            let name = fileName ?? "session_\(timestamp).json"
            return exportAsJSON(session: targetSession, fileName: name)

        case .jsonl:
            let name = fileName ?? "events_\(timestamp).jsonl"
            return exportAsJSONL(events: targetSession.events, fileName: name)

        case .swiftTest:
            let name = fileName ?? "generated_test"
            return exportAsTestCase(testName: name, session: targetSession)

        case .markdown:
            let name = fileName ?? "report_\(timestamp).md"
            return exportAsMarkdown(session: targetSession, fileName: name)

        case .archive:
            return exportForBugReport()
        }
    }

    /// 在 Finder 中显示导出目录
    func revealExportDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: exportDirectory)
    }

    /// 获取所有导出文件
    func listExportedFiles() -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: exportDirectory) else {
            return []
        }

        return contents.map { URL(fileURLWithPath: "\(exportDirectory)/\($0)") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 清理旧导出文件
    ///
    /// - Parameter keepDays: 保留天数
    func cleanOldExports(keepDays: Int = 7) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: exportDirectory) else {
            return
        }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()

        for fileName in contents {
            let filePath = "\(exportDirectory)/\(fileName)"
            if let attributes = try? fileManager.attributesOfItem(atPath: filePath),
               let modificationDate = attributes[.modificationDate] as? Date,
               modificationDate < cutoffDate {
                try? fileManager.removeItem(atPath: filePath)
                logInfo("[DebugSessionExporter] 清理旧导出: \(fileName)")
            }
        }
    }

    // MARK: - 私有方法

    private func exportAsJSON(session: DebugSession, fileName: String) -> ExportResult {
        let filePath = "\(exportDirectory)/\(fileName)"

        do {
            try exportJSON(session, to: filePath)
            let fileSize = try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64

            return ExportResult(
                success: true,
                filePath: URL(fileURLWithPath: filePath),
                error: nil,
                fileSize: fileSize
            )
        } catch {
            return ExportResult(
                success: false,
                filePath: nil,
                error: error.localizedDescription,
                fileSize: nil
            )
        }
    }

    private func exportAsJSONL(events: [TimestampedEvent], fileName: String) -> ExportResult {
        let filePath = "\(exportDirectory)/\(fileName)"

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var lines: [String] = []
            for event in events {
                let data = try encoder.encode(event)
                if let jsonString = String(data: data, encoding: .utf8) {
                    lines.append(jsonString)
                }
            }

            let content = lines.joined(separator: "\n")
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)

            let fileSize = try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64

            return ExportResult(
                success: true,
                filePath: URL(fileURLWithPath: filePath),
                error: nil,
                fileSize: fileSize
            )
        } catch {
            return ExportResult(
                success: false,
                filePath: nil,
                error: error.localizedDescription,
                fileSize: nil
            )
        }
    }

    private func exportAsMarkdown(session: DebugSession, fileName: String) -> ExportResult {
        let filePath = "\(exportDirectory)/\(fileName)"

        do {
            try generateMarkdownReport(session: session, to: filePath)
            let fileSize = try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64

            return ExportResult(
                success: true,
                filePath: URL(fileURLWithPath: filePath),
                error: nil,
                fileSize: fileSize
            )
        } catch {
            return ExportResult(
                success: false,
                filePath: nil,
                error: error.localizedDescription,
                fileSize: nil
            )
        }
    }

    private func exportJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func copyRecentLogs(to directory: String) {
        let fileManager = FileManager.default

        // 复制今天和昨天的日志
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today

        for date in [today, yesterday] {
            let logPath = ETermPaths.logFile(date: date)
            if fileManager.fileExists(atPath: logPath) {
                let fileName = (logPath as NSString).lastPathComponent
                let destPath = "\(directory)/\(fileName)"
                try? fileManager.copyItem(atPath: logPath, toPath: destPath)
            }
        }
    }

    private func generateMarkdownReport(session: DebugSession, to path: String) throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var report = """
        # ETerm Debug Report

        ## 基本信息

        | 属性 | 值 |
        |------|-----|
        | 会话 ID | `\(session.sessionId)` |
        | 开始时间 | \(dateFormatter.string(from: session.startTime)) |
        | 结束时间 | \(session.endTime.map { dateFormatter.string(from: $0) } ?? "进行中") |
        | 事件数量 | \(session.events.count) |

        ## 系统信息

        | 属性 | 值 |
        |------|-----|
        | 操作系统 | \(session.systemInfo.osVersion) |
        | 应用版本 | \(session.systemInfo.appVersion) (\(session.systemInfo.buildNumber)) |
        | 屏幕数量 | \(session.systemInfo.screenCount) |
        | 主屏幕尺寸 | \(Int(session.systemInfo.mainScreenSize.width)) x \(Int(session.systemInfo.mainScreenSize.height)) |

        ## 事件时间线

        """

        // 添加最近 50 个事件
        let recentEvents = session.events.suffix(50)
        for (index, event) in recentEvents.enumerated() {
            let time = dateFormatter.string(from: event.timestamp)
            let desc = eventDescription(event.event)
            report += "- **#\(session.events.count - 50 + index)** [\(time)] \(desc)\n"
        }

        if session.events.count > 50 {
            report += "\n> 仅显示最近 50 个事件，完整事件请查看 session.json\n"
        }

        // 添加状态信息
        if let finalState = session.finalState {
            report += """

            ## 最终状态

            - 窗口数量: \(finalState.windowCount)
            - 活跃窗口: \(finalState.activeWindowNumber ?? -1)
            - 焦点元素: \(finalState.focusedElement.map { "\($0)" } ?? "无")

            """
        }

        // 添加崩溃日志
        if let crashLog = session.crashLog {
            report += """

            ## 崩溃日志

            ```
            \(crashLog)
            ```

            """
        }

        report += """

        ---
        *由 ETerm 自动生成*
        """

        try report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func createArchive(from directory: String, to archivePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", archivePath, "."]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "DebugSessionExporter",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "压缩失败"]
            )
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private func eventDescription(_ event: SessionEvent) -> String {
        switch event {
        case .pageCreate(_, let title):
            return "创建 Page「\(title)」"
        case .pageClose:
            return "关闭 Page"
        case .pageSwitch:
            return "切换 Page"
        case .pageRename(_, _, let newTitle):
            return "重命名 Page 为「\(newTitle)」"
        case .tabCreate(_, _, let contentType):
            return "创建 Tab (\(contentType))"
        case .tabClose:
            return "关闭 Tab"
        case .tabSwitch:
            return "切换 Tab"
        case .panelSplit(_, let direction, _):
            return "分割 Panel (\(direction))"
        case .panelActivate:
            return "激活 Panel"
        case .focusChange(_, let toElement):
            return "焦点变化 -> \(toElement)"
        case .shortcutTriggered(let commandId, _):
            return "快捷键 \(commandId)"
        default:
            return "\(event)"
        }
    }
}

// MARK: - 菜单集成

extension DebugSessionExporter {

    /// 创建调试菜单项
    func createDebugMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // 导出 Bug 报告
        let exportItem = NSMenuItem(
            title: "导出调试报告...",
            action: #selector(handleExportBugReport),
            keyEquivalent: ""
        )
        exportItem.target = self
        items.append(exportItem)

        // 导出为测试用例
        let testItem = NSMenuItem(
            title: "导出为测试用例...",
            action: #selector(handleExportTestCase),
            keyEquivalent: ""
        )
        testItem.target = self
        items.append(testItem)

        // 分隔线
        items.append(NSMenuItem.separator())

        // 打开导出目录
        let revealItem = NSMenuItem(
            title: "在 Finder 中显示导出",
            action: #selector(handleRevealExports),
            keyEquivalent: ""
        )
        revealItem.target = self
        items.append(revealItem)

        return items
    }

    @objc private func handleExportBugReport() {
        let result = exportForBugReport()

        if result.success, let path = result.filePath {
            // 显示成功提示
            let alert = NSAlert()
            alert.messageText = "导出成功"
            alert.informativeText = "调试报告已保存到:\n\(path.path)"
            alert.addButton(withTitle: "在 Finder 中显示")
            alert.addButton(withTitle: "确定")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.selectFile(path.path, inFileViewerRootedAtPath: "")
            }
        } else {
            // 显示错误提示
            let alert = NSAlert()
            alert.messageText = "导出失败"
            alert.informativeText = result.error ?? "未知错误"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func handleExportTestCase() {
        // 弹出输入框获取测试名称
        let alert = NSAlert()
        alert.messageText = "导出为测试用例"
        alert.informativeText = "请输入测试名称（将用于生成 test_xxx 函数）"

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "例如: tab_drag_focus_loss"
        alert.accessoryView = textField

        alert.addButton(withTitle: "导出")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            let testName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !testName.isEmpty else { return }

            let result = exportAsTestCase(testName: testName)

            if result.success, let path = result.filePath {
                NSWorkspace.shared.selectFile(path.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    @objc private func handleRevealExports() {
        revealExportDirectory()
    }
}
