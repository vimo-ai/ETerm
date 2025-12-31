//
//  SessionReplayer.swift
//  ETerm
//
//  会话回放器 - 用于重现用户操作序列
//
//  使用方式：
//  1. let session = loadSession(from: url)
//  2. let replayer = SessionReplayer(session: session)
//  3. replayer.replay()
//

import Foundation
import AppKit
import ETermKit

// MARK: - 回放模式

/// 回放模式
enum ReplayMode: Equatable {
    /// 实时回放（按原始时间间隔）
    case realtime

    /// 快速回放（尽快执行）
    case fast

    /// 单步回放（每个事件需要手动触发）
    case stepping

    /// 带延迟的快速回放
    case fastWithDelay(TimeInterval)
}

// MARK: - 回放结果

/// 回放结果
struct ReplayResult {
    /// 是否成功
    let success: Bool

    /// 执行的事件数量
    let eventsExecuted: Int

    /// 失败的事件（如果有）
    let failedEvents: [(index: Int, event: SessionEvent, error: String)]

    /// 状态差异（如果检测到）
    let stateDivergences: [(index: Int, expected: StateSnapshot?, actual: StateSnapshot?)]

    /// 回放耗时
    let duration: TimeInterval
}

// MARK: - 回放委托

/// 回放委托 - 用于执行具体操作和获取状态
protocol SessionReplayerDelegate: AnyObject {
    /// 执行事件
    func execute(event: SessionEvent) throws

    /// 获取当前状态快照
    func captureCurrentState() -> StateSnapshot?

    /// 回放开始
    func replayDidStart()

    /// 回放结束
    func replayDidEnd(result: ReplayResult)

    /// 事件即将执行
    func willExecute(event: SessionEvent, at index: Int)

    /// 事件执行完成
    func didExecute(event: SessionEvent, at index: Int)

    /// 检测到状态差异
    func didDetectDivergence(at index: Int, expected: StateSnapshot?, actual: StateSnapshot?)
}

// 默认实现
extension SessionReplayerDelegate {
    func replayDidStart() {}
    func replayDidEnd(result: ReplayResult) {}
    func willExecute(event: SessionEvent, at index: Int) {}
    func didExecute(event: SessionEvent, at index: Int) {}
    func didDetectDivergence(at index: Int, expected: StateSnapshot?, actual: StateSnapshot?) {}
}

// MARK: - 回放器

/// 会话回放器
final class SessionReplayer {

    // MARK: - 属性

    /// 要回放的会话
    let session: DebugSession

    /// 回放模式
    var mode: ReplayMode = .fast

    /// 是否正在回放
    private(set) var isReplaying: Bool = false

    /// 当前回放索引
    private(set) var currentIndex: Int = 0

    /// 委托
    weak var delegate: SessionReplayerDelegate?

    /// 回放队列
    private let replayQueue = DispatchQueue(label: "com.eterm.session-replayer")

    /// 失败的事件
    private var failedEvents: [(index: Int, event: SessionEvent, error: String)] = []

    /// 状态差异
    private var stateDivergences: [(index: Int, expected: StateSnapshot?, actual: StateSnapshot?)] = []

    /// 回放开始时间
    private var replayStartTime: Date?

    /// 取消标志
    private var isCancelled: Bool = false

    // MARK: - 初始化

    init(session: DebugSession) {
        self.session = session
    }

    /// 从文件加载会话
    static func loadSession(from url: URL) throws -> DebugSession {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DebugSession.self, from: data)
    }

    /// 从 JSONL 文件加载事件
    static func loadEvents(from url: URL) throws -> [TimestampedEvent] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try lines.map { line in
            let data = line.data(using: .utf8)!
            return try decoder.decode(TimestampedEvent.self, from: data)
        }
    }

    // MARK: - 回放控制

    /// 开始回放
    func replay(completion: ((ReplayResult) -> Void)? = nil) {
        guard !isReplaying else {
            logWarn("[SessionReplayer] 已在回放中")
            return
        }

        isReplaying = true
        isCancelled = false
        currentIndex = 0
        failedEvents.removeAll()
        stateDivergences.removeAll()
        replayStartTime = Date()

        delegate?.replayDidStart()

        logInfo("[SessionReplayer] 开始回放，共 \(session.events.count) 个事件，模式: \(mode)")

        replayQueue.async { [weak self] in
            self?.executeReplay(completion: completion)
        }
    }

    /// 暂停回放
    func pause() {
        // 单步模式下有效
        guard mode == .stepping else { return }
        // 暂停逻辑由单步模式自动处理
    }

    /// 继续回放（单步模式）
    func step() {
        guard mode == .stepping, isReplaying else { return }
        executeNextEvent()
    }

    /// 取消回放
    func cancel() {
        isCancelled = true
        isReplaying = false
        logInfo("[SessionReplayer] 回放已取消")
    }

    /// 跳转到指定事件
    func seek(to index: Int) {
        guard index >= 0 && index < session.events.count else { return }
        currentIndex = index
    }

    // MARK: - 私有方法

    private func executeReplay(completion: ((ReplayResult) -> Void)?) {
        var previousTimestamp: Date?

        while currentIndex < session.events.count && !isCancelled {
            let timestampedEvent = session.events[currentIndex]
            let event = timestampedEvent.event

            // 计算延迟
            if let prevTime = previousTimestamp {
                let delay: TimeInterval
                switch mode {
                case .realtime:
                    delay = timestampedEvent.timestamp.timeIntervalSince(prevTime)
                case .fast:
                    delay = 0
                case .stepping:
                    // 单步模式在 step() 方法中处理
                    return
                case .fastWithDelay(let interval):
                    delay = interval
                }

                if delay > 0 {
                    Thread.sleep(forTimeInterval: min(delay, 1.0)) // 最大延迟 1 秒
                }
            }
            previousTimestamp = timestampedEvent.timestamp

            // 执行事件
            executeEvent(event, at: currentIndex)

            currentIndex += 1
        }

        // 回放完成
        finishReplay(completion: completion)
    }

    private func executeNextEvent() {
        guard currentIndex < session.events.count else {
            finishReplay(completion: nil)
            return
        }

        let event = session.events[currentIndex].event
        executeEvent(event, at: currentIndex)
        currentIndex += 1
    }

    private func executeEvent(_ event: SessionEvent, at index: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.willExecute(event: event, at: index)
        }

        do {
            try delegate?.execute(event: event)
            logDebug("[SessionReplayer] 执行事件 #\(index): \(event)")

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didExecute(event: event, at: index)
            }
        } catch {
            let errorMessage = error.localizedDescription
            failedEvents.append((index: index, event: event, error: errorMessage))
            logError("[SessionReplayer] 事件执行失败 #\(index): \(errorMessage)")
        }
    }

    private func finishReplay(completion: ((ReplayResult) -> Void)?) {
        isReplaying = false

        let duration = Date().timeIntervalSince(replayStartTime ?? Date())
        let result = ReplayResult(
            success: failedEvents.isEmpty,
            eventsExecuted: currentIndex,
            failedEvents: failedEvents,
            stateDivergences: stateDivergences,
            duration: duration
        )

        logInfo("[SessionReplayer] 回放完成，执行 \(currentIndex) 个事件，失败 \(failedEvents.count) 个，耗时 \(String(format: "%.2f", duration))s")

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.replayDidEnd(result: result)
            completion?(result)
        }
    }
}

// MARK: - 验证器

/// 回放验证器 - 对比回放结果与预期状态
final class ReplayValidator {

    /// 验证会话回放结果
    static func validate(session: DebugSession, actualFinalState: StateSnapshot?) -> [String] {
        var issues: [String] = []

        // 检查最终状态
        if let expectedFinal = session.finalState, let actualFinal = actualFinalState {
            if expectedFinal.windowCount != actualFinal.windowCount {
                issues.append("窗口数量不匹配: 期望 \(expectedFinal.windowCount), 实际 \(actualFinal.windowCount)")
            }

            // 检查每个窗口
            for (index, expectedWindow) in expectedFinal.windows.enumerated() {
                guard index < actualFinal.windows.count else {
                    issues.append("缺少窗口 #\(index)")
                    continue
                }

                let actualWindow = actualFinal.windows[index]

                if expectedWindow.pageCount != actualWindow.pageCount {
                    issues.append("窗口 #\(index) Page 数量不匹配: 期望 \(expectedWindow.pageCount), 实际 \(actualWindow.pageCount)")
                }

                if expectedWindow.activePageId != actualWindow.activePageId {
                    issues.append("窗口 #\(index) 活跃 Page 不匹配")
                }
            }

            // 检查焦点
            if expectedFinal.focusedElement != actualFinal.focusedElement {
                issues.append("焦点元素不匹配: 期望 \(String(describing: expectedFinal.focusedElement)), 实际 \(String(describing: actualFinal.focusedElement))")
            }
        }

        return issues
    }
}

// MARK: - 测试用例生成器

/// 测试用例生成器 - 将会话转换为 XCTest 代码
final class TestCaseGenerator {

    /// 生成测试代码
    static func generateTestCase(from session: DebugSession, testName: String) -> String {
        var code = """
        func test_\(testName)() {
            // 自动生成自 \(session.sessionId.uuidString)
            // 原始录制时间: \(session.startTime)
            // 事件数量: \(session.events.count)

            let app = TerminalApp(headless: true)

        """

        for (index, timestampedEvent) in session.events.enumerated() {
            let eventCode = generateEventCode(timestampedEvent.event, index: index)
            code += "    \(eventCode)\n"
        }

        // 添加断言
        if let finalState = session.finalState {
            code += """

            // 验证最终状态
            let state = app.captureState()
            XCTAssertEqual(state.windowCount, \(finalState.windowCount))
        """

            if let focusedElement = finalState.focusedElement {
                code += """

            XCTAssertEqual(state.focusedElement, \(focusedElementCode(focusedElement)))
        """
            }
        }

        code += """

        }
        """

        return code
    }

    private static func generateEventCode(_ event: SessionEvent, index: Int) -> String {
        switch event {
        case .pageCreate(let pageId, let title):
            return "app.createPage(id: UUID(uuidString: \"\(pageId)\")!, title: \"\(title)\")  // Event #\(index)"

        case .pageClose(let pageId):
            return "app.closePage(id: UUID(uuidString: \"\(pageId)\")!)  // Event #\(index)"

        case .pageSwitch(_, let toPageId):
            return "app.switchToPage(id: UUID(uuidString: \"\(toPageId)\")!)  // Event #\(index)"

        case .tabCreate(let panelId, let tabId, let contentType):
            return "app.createTab(panelId: UUID(uuidString: \"\(panelId)\")!, tabId: UUID(uuidString: \"\(tabId)\")!, type: \"\(contentType)\")  // Event #\(index)"

        case .tabClose(let panelId, let tabId):
            return "app.closeTab(panelId: UUID(uuidString: \"\(panelId)\")!, tabId: UUID(uuidString: \"\(tabId)\")!)  // Event #\(index)"

        case .tabSwitch(let panelId, _, let toTabId):
            return "app.switchToTab(panelId: UUID(uuidString: \"\(panelId)\")!, tabId: UUID(uuidString: \"\(toTabId)\")!)  // Event #\(index)"

        case .panelActivate(_, let toPanelId):
            return "app.activatePanel(id: UUID(uuidString: \"\(toPanelId)\")!)  // Event #\(index)"

        case .focusChange(_, let toElement):
            return "app.setFocus(\(focusedElementCode(toElement)))  // Event #\(index)"

        case .shortcutTriggered(let commandId, _):
            return "app.executeCommand(\"\(commandId)\")  // Event #\(index)"

        default:
            return "// Unsupported event: \(event)  // Event #\(index)"
        }
    }

    private static func focusedElementCode(_ element: FocusElement) -> String {
        switch element {
        case .terminal(let panelId, let tabId):
            return ".terminal(panelId: UUID(uuidString: \"\(panelId)\")!, tabId: UUID(uuidString: \"\(tabId)\")!)"
        case .searchBar:
            return ".searchBar"
        case .pageTab(let pageId):
            return ".pageTab(pageId: UUID(uuidString: \"\(pageId)\")!)"
        case .tabItem(let panelId, let tabId):
            return ".tabItem(panelId: UUID(uuidString: \"\(panelId)\")!, tabId: UUID(uuidString: \"\(tabId)\")!)"
        case .sidebar:
            return ".sidebar"
        case .settings:
            return ".settings"
        case .none:
            return ".none"
        }
    }
}
