//
//  SessionRecorder.swift
//  ETerm
//
//  会话录制器 - 记录用户操作用于调试和回放
//
//  使用方式：
//  1. SessionRecorder.shared.startRecording()
//  2. SessionRecorder.shared.record(.pageCreate(...))
//  3. SessionRecorder.shared.stopRecording()
//  4. let session = SessionRecorder.shared.exportSession()
//

import Foundation
import AppKit

// MARK: - 录制器配置

/// 录制器配置
struct RecorderConfig {
    /// 最大事件数量（环形缓冲区大小）
    var maxEventCount: Int = 10000

    /// 是否自动启动录制
    var autoStart: Bool = true

    /// 是否记录状态快照
    var captureSnapshots: Bool = true

    /// 快照间隔（秒）
    var snapshotInterval: TimeInterval = 60

    /// 是否写入文件（实时持久化）
    var persistToFile: Bool = false

    /// 默认配置
    static let `default` = RecorderConfig()

    /// 调试配置（更详细的记录）
    static let debug = RecorderConfig(
        maxEventCount: 50000,
        autoStart: true,
        captureSnapshots: true,
        snapshotInterval: 30,
        persistToFile: true
    )

    /// 生产配置（最小开销）
    static let production = RecorderConfig(
        maxEventCount: 5000,
        autoStart: true,
        captureSnapshots: false,
        snapshotInterval: 120,
        persistToFile: false
    )
}

// MARK: - 录制器

/// 会话录制器
///
/// 线程安全的事件录制器，使用环形缓冲区存储最近的事件
/// 支持导出、回放、转换为测试用例
final class SessionRecorder {

    // MARK: - 单例

    static let shared = SessionRecorder()

    // MARK: - 属性

    /// 配置
    private(set) var config: RecorderConfig

    /// 是否正在录制
    private(set) var isRecording: Bool = false

    /// 录制开始时间
    private var startTime: Date?

    /// 事件序列号
    private var sequenceNumber: UInt64 = 0

    /// 事件缓冲区（环形）
    private var events: [TimestampedEvent] = []

    /// 初始状态快照
    private var initialSnapshot: StateSnapshot?

    /// 定期状态快照
    private var snapshots: [StateSnapshot] = []

    /// 快照定时器
    private var snapshotTimer: Timer?

    /// 同步队列
    private let queue = DispatchQueue(label: "com.eterm.session-recorder", attributes: .concurrent)

    /// 文件写入队列
    private let fileQueue = DispatchQueue(label: "com.eterm.session-recorder.file", qos: .background)

    /// 录制文件路径
    private var recordingFilePath: String?

    /// 状态捕获器（外部注入）
    var snapshotProvider: (() -> StateSnapshot)?

    // MARK: - 初始化

    private init(config: RecorderConfig = .default) {
        self.config = config

        // 自动启动
        if config.autoStart {
            startRecording()
        }
    }

    // MARK: - 公共方法

    /// 配置录制器
    func configure(_ config: RecorderConfig) {
        queue.async(flags: .barrier) { [weak self] in
            self?.config = config
        }
    }

    /// 开始录制
    func startRecording() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, !self.isRecording else { return }

            self.isRecording = true
            self.startTime = Date()
            self.sequenceNumber = 0
            self.events.removeAll()
            self.snapshots.removeAll()

            // 捕获初始状态
            if self.config.captureSnapshots {
                self.initialSnapshot = self.snapshotProvider?()
                self.startSnapshotTimer()
            }

            // 设置文件持久化
            if self.config.persistToFile {
                self.setupRecordingFile()
            }

            logInfo("[SessionRecorder] 录制开始")
        }
    }

    /// 停止录制
    func stopRecording() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, self.isRecording else { return }

            self.isRecording = false
            self.snapshotTimer?.invalidate()
            self.snapshotTimer = nil

            logInfo("[SessionRecorder] 录制停止，共 \(self.events.count) 个事件")
        }
    }

    /// 录制事件
    ///
    /// - Parameters:
    ///   - event: 要录制的事件
    ///   - source: 事件来源（可选）
    func record(_ event: SessionEvent, source: String? = nil) {
        guard isRecording else { return }

        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            self.sequenceNumber += 1
            let timestampedEvent = TimestampedEvent(
                event: event,
                sequence: self.sequenceNumber,
                source: source
            )

            // 环形缓冲区
            if self.events.count >= self.config.maxEventCount {
                self.events.removeFirst()
            }
            self.events.append(timestampedEvent)

            // 持久化到文件
            if self.config.persistToFile {
                self.persistEvent(timestampedEvent)
            }

            // 调试日志
            logDebug("[SessionRecorder] 事件 #\(self.sequenceNumber): \(self.eventDescription(event))")
        }
    }

    /// 获取最近的事件
    ///
    /// - Parameter count: 数量
    /// - Returns: 事件列表
    func recentEvents(count: Int) -> [TimestampedEvent] {
        queue.sync {
            let startIndex = max(0, events.count - count)
            return Array(events[startIndex...])
        }
    }

    /// 获取所有事件
    var allEvents: [TimestampedEvent] {
        queue.sync { events }
    }

    /// 导出调试会话
    ///
    /// - Parameter crashLog: 崩溃日志（可选）
    /// - Returns: 调试会话数据
    func exportSession(crashLog: String? = nil) -> DebugSession {
        queue.sync {
            let finalSnapshot = config.captureSnapshots ? snapshotProvider?() : nil

            return DebugSession(
                startTime: startTime ?? Date(),
                endTime: Date(),
                events: events,
                initialState: initialSnapshot,
                finalState: finalSnapshot,
                crashLog: crashLog,
                metadata: [
                    "eventCount": "\(events.count)",
                    "recordingDuration": "\(Date().timeIntervalSince(startTime ?? Date()))s"
                ]
            )
        }
    }

    /// 导出到文件
    ///
    /// - Parameter fileName: 文件名（可选，默认使用时间戳）
    /// - Returns: 文件路径
    @discardableResult
    func exportToFile(fileName: String? = nil) -> URL? {
        let session = exportSession()
        let name = fileName ?? "debug_session_\(formatTimestamp(Date()))"
        let filePath = "\(ETermPaths.logs)/\(name).json"

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            try data.write(to: URL(fileURLWithPath: filePath))

            logInfo("[SessionRecorder] 会话导出到: \(filePath)")
            return URL(fileURLWithPath: filePath)
        } catch {
            logError("[SessionRecorder] 导出失败: \(error)")
            return nil
        }
    }

    /// 清除录制数据
    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            self?.events.removeAll()
            self?.snapshots.removeAll()
            self?.sequenceNumber = 0
            self?.initialSnapshot = nil
        }
    }

    // MARK: - 便捷方法（快捷录制）

    /// 录制 Page 创建
    func recordPageCreate(pageId: UUID, title: String) {
        record(.pageCreate(pageId: pageId, title: title), source: "PageManager")
    }

    /// 录制 Page 关闭
    func recordPageClose(pageId: UUID) {
        record(.pageClose(pageId: pageId), source: "PageManager")
    }

    /// 录制 Page 切换
    func recordPageSwitch(from: UUID?, to: UUID) {
        record(.pageSwitch(fromPageId: from, toPageId: to), source: "PageManager")
    }

    /// 录制 Tab 创建
    func recordTabCreate(panelId: UUID, tabId: UUID, contentType: String) {
        record(.tabCreate(panelId: panelId, tabId: tabId, contentType: contentType), source: "TabManager")
    }

    /// 录制 Tab 关闭
    func recordTabClose(panelId: UUID, tabId: UUID) {
        record(.tabClose(panelId: panelId, tabId: tabId), source: "TabManager")
    }

    /// 录制 Tab 切换
    func recordTabSwitch(panelId: UUID, from: UUID?, to: UUID) {
        record(.tabSwitch(panelId: panelId, fromTabId: from, toTabId: to), source: "TabManager")
    }

    /// 录制焦点变化
    func recordFocusChange(from: FocusElement?, to: FocusElement) {
        record(.focusChange(fromElement: from, toElement: to), source: "FocusManager")
    }

    /// 录制 Panel 激活
    func recordPanelActivate(from: UUID?, to: UUID) {
        record(.panelActivate(fromPanelId: from, toPanelId: to), source: "PanelManager")
    }

    /// 录制快捷键触发
    func recordShortcut(commandId: String, context: String? = nil) {
        record(.shortcutTriggered(commandId: commandId, context: context), source: "KeyboardService")
    }

    // MARK: - 私有方法

    private func startSnapshotTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.snapshotTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.snapshotInterval,
                repeats: true
            ) { [weak self] _ in
                self?.captureSnapshot()
            }
        }
    }

    private func captureSnapshot() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, let snapshot = self.snapshotProvider?() else { return }

            // 限制快照数量
            if self.snapshots.count >= 100 {
                self.snapshots.removeFirst()
            }
            self.snapshots.append(snapshot)
        }
    }

    private func setupRecordingFile() {
        let timestamp = formatTimestamp(Date())
        recordingFilePath = "\(ETermPaths.logs)/recording_\(timestamp).jsonl"

        // 创建文件
        FileManager.default.createFile(atPath: recordingFilePath!, contents: nil, attributes: nil)
    }

    private func persistEvent(_ event: TimestampedEvent) {
        guard let filePath = recordingFilePath else { return }

        fileQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(event)

                if let jsonString = String(data: data, encoding: .utf8) {
                    let line = jsonString + "\n"
                    if let fileHandle = FileHandle(forWritingAtPath: filePath) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(line.data(using: .utf8)!)
                        fileHandle.closeFile()
                    }
                }
            } catch {
                logError("[SessionRecorder] 持久化失败: \(error)")
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private func eventDescription(_ event: SessionEvent) -> String {
        switch event {
        case .pageCreate(let pageId, let title):
            return "pageCreate(\(pageId.uuidString.prefix(8)), \"\(title)\")"
        case .pageClose(let pageId):
            return "pageClose(\(pageId.uuidString.prefix(8)))"
        case .pageSwitch(_, let toPageId):
            return "pageSwitch(to: \(toPageId.uuidString.prefix(8)))"
        case .tabCreate(let panelId, let tabId, let contentType):
            return "tabCreate(panel: \(panelId.uuidString.prefix(8)), tab: \(tabId.uuidString.prefix(8)), type: \(contentType))"
        case .tabClose(let panelId, let tabId):
            return "tabClose(panel: \(panelId.uuidString.prefix(8)), tab: \(tabId.uuidString.prefix(8)))"
        case .tabSwitch(let panelId, _, let toTabId):
            return "tabSwitch(panel: \(panelId.uuidString.prefix(8)), to: \(toTabId.uuidString.prefix(8)))"
        case .focusChange(_, let toElement):
            return "focusChange(to: \(toElement))"
        case .panelActivate(_, let toPanelId):
            return "panelActivate(to: \(toPanelId.uuidString.prefix(8)))"
        case .shortcutTriggered(let commandId, _):
            return "shortcut(\(commandId))"
        default:
            return "\(event)"
        }
    }
}

// MARK: - 全局便捷函数

/// 录制事件（全局便捷函数）
func recordEvent(_ event: SessionEvent, source: String? = nil) {
    SessionRecorder.shared.record(event, source: source)
}
