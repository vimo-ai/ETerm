//
//  SessionEvent.swift
//  ETerm
//
//  会话事件定义 - 用于录制和回放用户操作
//
//  设计原则：
//  - 只记录结构化事件，不记录敏感内容（如输入文本）
//  - 事件可序列化，支持持久化和传输
//  - 支持确定性回放
//

import Foundation
import CoreGraphics
import AppKit

// MARK: - 会话事件

/// 会话事件 - 记录用户操作
///
/// 所有可录制的用户交互都通过此枚举表示
/// 每个事件携带足够的信息以支持回放
enum SessionEvent: Codable, Equatable {

    // MARK: - Page 事件

    /// 创建 Page
    case pageCreate(pageId: UUID, title: String)

    /// 关闭 Page
    case pageClose(pageId: UUID)

    /// 切换 Page
    case pageSwitch(fromPageId: UUID?, toPageId: UUID)

    /// 重命名 Page
    case pageRename(pageId: UUID, oldTitle: String, newTitle: String)

    /// Page 重排序
    case pageReorder(pageIds: [UUID])

    /// Page 拖拽开始
    case pageDragStart(pageId: UUID, position: CGPoint)

    /// Page 拖拽结束
    case pageDragEnd(pageId: UUID, position: CGPoint, targetIndex: Int?)

    /// Page 跨窗口移动
    case pageMoveToWindow(pageId: UUID, sourceWindowNumber: Int, targetWindowNumber: Int)

    // MARK: - Tab 事件

    /// 创建 Tab
    case tabCreate(panelId: UUID, tabId: UUID, contentType: String)

    /// 关闭 Tab
    case tabClose(panelId: UUID, tabId: UUID)

    /// 切换 Tab
    case tabSwitch(panelId: UUID, fromTabId: UUID?, toTabId: UUID)

    /// Tab 重排序
    case tabReorder(panelId: UUID, tabIds: [UUID])

    /// Tab 拖拽开始
    case tabDragStart(panelId: UUID, tabId: UUID, position: CGPoint)

    /// Tab 拖拽结束
    case tabDragEnd(panelId: UUID, tabId: UUID, position: CGPoint, targetPanelId: UUID?, targetIndex: Int?)

    // MARK: - Panel 事件

    /// 分割 Panel
    case panelSplit(panelId: UUID, direction: String, newPanelId: UUID)

    /// 关闭 Panel
    case panelClose(panelId: UUID)

    /// Panel 激活（焦点变化）
    case panelActivate(fromPanelId: UUID?, toPanelId: UUID)

    /// Panel 尺寸调整
    case panelResize(panelId: UUID, ratio: CGFloat)

    // MARK: - 焦点事件

    /// 焦点变化
    case focusChange(fromElement: FocusElement?, toElement: FocusElement)

    /// 焦点请求（如点击终端）
    case focusRequest(element: FocusElement)

    // MARK: - 窗口事件

    /// 创建窗口
    case windowCreate(windowNumber: Int)

    /// 关闭窗口
    case windowClose(windowNumber: Int)

    /// 窗口激活
    case windowActivate(windowNumber: Int)

    /// 窗口移动
    case windowMove(windowNumber: Int, frame: CGRect)

    /// 窗口调整大小
    case windowResize(windowNumber: Int, frame: CGRect)

    // MARK: - 键盘事件（不记录实际按键内容，只记录特殊操作）

    /// 快捷键触发
    case shortcutTriggered(commandId: String, context: String?)

    // MARK: - 终端事件（结构化，不含敏感数据）

    /// 终端命令执行（只记录命令类型，不记录具体命令）
    case terminalCommandExecuted(terminalId: UUID, commandType: String)

    /// 终端输出事件（如命令完成）
    case terminalOutputEvent(terminalId: UUID, eventType: String)

    /// 终端内容快照（关键时刻的完整状态）
    /// - terminalId: Tab ID（作为终端标识）
    /// - visibleLines: 可见区域的文本内容（数组，每行一个字符串）
    /// - cursorRow: 光标行号（相对可见区域）
    /// - cursorCol: 光标列号
    /// - scrollbackLines: 回滚缓冲区行数
    case terminalSnapshot(
        terminalId: UUID,
        visibleLines: [String],
        cursorRow: Int,
        cursorCol: Int,
        scrollbackLines: Int
    )

    /// 终端增量输出（两次快照之间的输出内容）
    /// - terminalId: Tab ID
    /// - output: 原始输出内容（包含VT100控制序列）
    /// - timestamp: 相对时间戳（相对session开始时间，秒）
    case terminalIncrementalOutput(
        terminalId: UUID,
        output: String,
        relativeTimestamp: Double
    )

    // MARK: - 自定义事件

    /// 自定义事件（插件扩展用）
    case custom(name: String, payload: [String: String])
}

// MARK: - 焦点元素

/// 焦点元素 - 标识可聚焦的 UI 元素
enum FocusElement: Codable, Equatable {
    /// 终端
    case terminal(panelId: UUID, tabId: UUID)

    /// 搜索框
    case searchBar

    /// Page 标签
    case pageTab(pageId: UUID)

    /// Tab 标签
    case tabItem(panelId: UUID, tabId: UUID)

    /// 侧边栏
    case sidebar

    /// 设置面板
    case settings

    /// 无焦点
    case none
}

// MARK: - 时间戳事件

/// 带时间戳的事件 - 用于录制
struct TimestampedEvent: Codable {
    /// 事件发生时间
    let timestamp: Date

    /// 事件本身
    let event: SessionEvent

    /// 事件发生时的序列号（用于排序）
    let sequence: UInt64

    /// 事件来源（哪个模块产生）
    let source: String?

    init(event: SessionEvent, sequence: UInt64, source: String? = nil) {
        self.timestamp = Date()
        self.event = event
        self.sequence = sequence
        self.source = source
    }
}

// MARK: - 状态快照

/// 状态快照 - 捕获某一时刻的完整状态
struct StateSnapshot: Codable {
    /// 快照时间
    let timestamp: Date

    /// 窗口数量
    let windowCount: Int

    /// 窗口状态摘要
    let windows: [WindowSnapshot]

    /// 活跃窗口编号
    let activeWindowNumber: Int?

    /// 焦点元素
    let focusedElement: FocusElement?
}

/// 窗口快照
struct WindowSnapshot: Codable {
    let windowNumber: Int
    let frame: CGRect
    let pageCount: Int
    let activePageId: UUID?
    let pages: [PageSnapshot]
}

/// Page 快照
struct PageSnapshot: Codable {
    let pageId: UUID
    let title: String
    let panelCount: Int
    let activePanelId: UUID?
}

// MARK: - 调试会话

/// 调试会话 - 完整的录制数据
struct DebugSession: Codable {
    /// 会话 ID
    let sessionId: UUID

    /// 开始时间
    let startTime: Date

    /// 结束时间
    let endTime: Date?

    /// 事件列表
    let events: [TimestampedEvent]

    /// 初始状态快照
    let initialState: StateSnapshot?

    /// 最终状态快照
    let finalState: StateSnapshot?

    /// 系统信息
    let systemInfo: SystemInfo

    /// 崩溃日志（如果有）
    let crashLog: String?

    /// 元数据
    let metadata: [String: String]?

    init(
        sessionId: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        events: [TimestampedEvent],
        initialState: StateSnapshot? = nil,
        finalState: StateSnapshot? = nil,
        systemInfo: SystemInfo = .current,
        crashLog: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = endTime
        self.events = events
        self.initialState = initialState
        self.finalState = finalState
        self.systemInfo = systemInfo
        self.crashLog = crashLog
        self.metadata = metadata
    }
}

// MARK: - 系统信息

/// 系统信息 - 用于重现环境
struct SystemInfo: Codable {
    /// 操作系统版本
    let osVersion: String

    /// 应用版本
    let appVersion: String

    /// 应用构建号
    let buildNumber: String

    /// 屏幕数量
    let screenCount: Int

    /// 主屏幕尺寸
    let mainScreenSize: CGSize

    /// 当前系统信息
    static var current: SystemInfo {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        let screenCount = NSScreen.screens.count
        let mainScreenSize = NSScreen.main?.frame.size ?? .zero

        return SystemInfo(
            osVersion: osVersion,
            appVersion: appVersion,
            buildNumber: buildNumber,
            screenCount: screenCount,
            mainScreenSize: mainScreenSize
        )
    }
}

// MARK: - CGRect Codable

extension CGRect: Codable {
    enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(CGFloat.self, forKey: .x)
        let y = try container.decode(CGFloat.self, forKey: .y)
        let width = try container.decode(CGFloat.self, forKey: .width)
        let height = try container.decode(CGFloat.self, forKey: .height)
        self.init(x: x, y: y, width: width, height: height)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin.x, forKey: .x)
        try container.encode(origin.y, forKey: .y)
        try container.encode(size.width, forKey: .width)
        try container.encode(size.height, forKey: .height)
    }
}

// MARK: - CGPoint Codable

extension CGPoint: Codable {
    enum CodingKeys: String, CodingKey {
        case x, y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(CGFloat.self, forKey: .x)
        let y = try container.decode(CGFloat.self, forKey: .y)
        self.init(x: x, y: y)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }
}

// MARK: - CGSize Codable

extension CGSize: Codable {
    enum CodingKeys: String, CodingKey {
        case width, height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(CGFloat.self, forKey: .width)
        let height = try container.decode(CGFloat.self, forKey: .height)
        self.init(width: width, height: height)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}
