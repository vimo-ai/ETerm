# ETerm 插件事件系统设计

## 设计目标

- **最开放的插件体验**：核心能暴露的都暴露，让插件决定用不用
- **类型安全**：告别 String-based 事件，编译期检查
- **DDD 架构**：领域产生，应用协调，基础设施分发
- **信任插件**：给予最大自由，用户选择安装即信任

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│  Domain Layer (领域层)                                       │
│  ├── Aggregate 内部收集事件（DomainEventCollector）           │
│  └── 不依赖具体总线，只记录"发生了什么"                        │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ 返回 Aggregate + 收集的事件
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Application Layer (Coordinator)                             │
│  ├── 从 Aggregate 取出收集的事件                              │
│  ├── 统一发布到 EventBus                                     │
│  └── 可做版本化/兼容层映射                                    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  EventBus (统一事件总线)                                     │
│  ├── Core Events：核心层定义，Coordinator 发射               │
│  ├── Plugin Events：插件层定义，插件自己发射                  │
│  └── 任何插件可订阅任何事件，可发射任何事件                    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Plugin Layer                                                │
│  └── 订阅/发射任何事件（Core 或其他 Plugin 的）               │
└─────────────────────────────────────────────────────────────┘
```

---

## 线程模型

**主线程模型**：所有 Domain 对象在主线程操作，事件 handler 默认在主线程执行。

- 事件携带的对象引用仅在 handler 内访问是安全的
- 如需跨线程使用，请自行复制所需属性
- 可通过 `SubscriptionOptions` 指定其他队列

---

## DomainEvent 协议

```swift
/// 领域事件基础协议
protocol DomainEvent {
    /// 事件名称（用于日志/调试）
    static var name: String { get }

    /// Schema 版本（用于未来兼容性）
    static var schemaVersion: Int { get }

    /// 事件唯一标识（初始化时固定）
    var eventId: UUID { get }

    /// 事件发生时间戳（初始化时固定）
    var timestamp: Date { get }
}

/// 默认实现
extension DomainEvent {
    static var schemaVersion: Int { 1 }
}

/// 事件基类（提供 eventId 和 timestamp 的默认存储）
/// 具体事件可继承此类，或自行实现协议
struct EventMetadata {
    let eventId: UUID
    let timestamp: Date

    init() {
        self.eventId = UUID()
        self.timestamp = Date()
    }
}
```

---

## EventService 协议

```swift
/// 事件服务协议（通过 PluginContext 暴露给插件）
protocol EventService {

    /// 订阅事件
    /// - Parameters:
    ///   - eventType: 事件类型
    ///   - options: 订阅选项（队列、过滤等）
    ///   - handler: 事件处理器
    /// - Returns: 订阅句柄（用于取消订阅）
    func subscribe<E: DomainEvent>(
        _ eventType: E.Type,
        options: SubscriptionOptions,
        handler: @escaping (E) -> Void
    ) -> EventSubscription

    /// 发射事件
    /// - Parameter event: 事件实例
    func emit<E: DomainEvent>(_ event: E)
}

/// 订阅选项
struct SubscriptionOptions {
    /// 执行队列（nil = 同步，在发射线程执行）
    let queue: DispatchQueue?

    /// 默认：主线程异步
    static let `default` = SubscriptionOptions(queue: .main)

    /// 同步执行（在发射事件的线程）
    static let sync = SubscriptionOptions(queue: nil)

    /// 指定队列异步执行
    static func async(on queue: DispatchQueue) -> SubscriptionOptions {
        SubscriptionOptions(queue: queue)
    }
}

/// 订阅句柄
final class EventSubscription {
    private let unsubscribeAction: () -> Void
    private var isUnsubscribed = false

    init(unsubscribe: @escaping () -> Void) {
        self.unsubscribeAction = unsubscribe
    }

    func unsubscribe() {
        guard !isUnsubscribed else { return }
        isUnsubscribed = true
        unsubscribeAction()
    }

    deinit {
        unsubscribe()  // 自动取消订阅
    }
}
```

---

## DomainEventCollector（领域层使用）

```swift
/// 领域事件收集器协议
protocol DomainEventCollector: AnyObject {
    /// 记录事件（不立即发射）
    func record<E: DomainEvent>(_ event: E)

    /// 取出并清空所有收集的事件
    func flush() -> [any DomainEvent]
}

/// 默认实现
final class DefaultEventCollector: DomainEventCollector {
    private var events: [any DomainEvent] = []
    private let lock = NSLock()

    func record<E: DomainEvent>(_ event: E) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func flush() -> [any DomainEvent] {
        lock.lock()
        defer { lock.unlock() }
        let result = events
        events = []
        return result
    }
}
```

---

## Core Events（核心层定义）

文件位置：`Core/Events/CoreEvents.swift`

```swift
/// 核心层领域事件
enum CoreEvents {

    // MARK: - App

    enum App {
        struct DidLaunch: DomainEvent {
            static let name = "app.didLaunch"
            let eventId = UUID()
            let timestamp = Date()
            let launchTime: Date
        }

        struct WillTerminate: DomainEvent {
            static let name = "app.willTerminate"
            let eventId = UUID()
            let timestamp = Date()
        }

        struct DidChangeTheme: DomainEvent {
            static let name = "app.didChangeTheme"
            let eventId = UUID()
            let timestamp = Date()
            let theme: String
        }

        struct DidChangeSettings: DomainEvent {
            static let name = "app.didChangeSettings"
            let eventId = UUID()
            let timestamp = Date()
            let key: String
            let oldValue: Any?
            let newValue: Any?
        }
    }

    // MARK: - Window

    enum Window {
        struct DidCreate: DomainEvent {
            static let name = "window.didCreate"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }

        struct WillClose: DomainEvent {
            static let name = "window.willClose"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }

        struct DidClose: DomainEvent {
            static let name = "window.didClose"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }

        struct DidBecomeKey: DomainEvent {
            static let name = "window.didBecomeKey"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }

        struct DidResignKey: DomainEvent {
            static let name = "window.didResignKey"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }

        struct DidResize: DomainEvent {
            static let name = "window.didResize"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
            let oldFrame: CGRect
            let newFrame: CGRect
        }

        struct DidMove: DomainEvent {
            static let name = "window.didMove"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
            let oldOrigin: CGPoint
            let newOrigin: CGPoint
        }

        struct DidEnterFullScreen: DomainEvent {
            static let name = "window.didEnterFullScreen"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }

        struct DidExitFullScreen: DomainEvent {
            static let name = "window.didExitFullScreen"
            let eventId = UUID()
            let timestamp = Date()
            let windowId: UUID
        }
    }

    // MARK: - Page

    enum Page {
        struct DidCreate: DomainEvent {
            static let name = "page.didCreate"
            let eventId = UUID()
            let timestamp = Date()
            let page: Page
            let windowId: UUID
        }

        struct WillClose: DomainEvent {
            static let name = "page.willClose"
            let eventId = UUID()
            let timestamp = Date()
            let pageId: UUID
            let windowId: UUID
        }

        struct DidClose: DomainEvent {
            static let name = "page.didClose"
            let eventId = UUID()
            let timestamp = Date()
            let pageId: UUID
            let windowId: UUID
        }

        struct DidActivate: DomainEvent {
            static let name = "page.didActivate"
            let eventId = UUID()
            let timestamp = Date()
            let page: Page
            let previousPageId: UUID?
            let windowId: UUID
        }

        struct DidDeactivate: DomainEvent {
            static let name = "page.didDeactivate"
            let eventId = UUID()
            let timestamp = Date()
            let pageId: UUID
            let windowId: UUID
        }

        struct DidChangeTitle: DomainEvent {
            static let name = "page.didChangeTitle"
            let eventId = UUID()
            let timestamp = Date()
            let pageId: UUID
            let oldTitle: String
            let newTitle: String
        }
    }

    // MARK: - Panel

    enum Panel {
        struct DidCreate: DomainEvent {
            static let name = "panel.didCreate"
            let eventId = UUID()
            let timestamp = Date()
            let panel: EditorPanel
            let pageId: UUID
            let windowId: UUID
        }

        struct DidSplit: DomainEvent {
            static let name = "panel.didSplit"
            let eventId = UUID()
            let timestamp = Date()
            let sourcePanel: EditorPanel
            let newPanel: EditorPanel
            let direction: SplitDirection
            let pageId: UUID
            let windowId: UUID
        }

        struct WillClose: DomainEvent {
            static let name = "panel.willClose"
            let eventId = UUID()
            let timestamp = Date()
            let panelId: UUID
            let pageId: UUID
        }

        struct DidClose: DomainEvent {
            static let name = "panel.didClose"
            let eventId = UUID()
            let timestamp = Date()
            let panelId: UUID
            let pageId: UUID
        }

        struct DidActivate: DomainEvent {
            static let name = "panel.didActivate"
            let eventId = UUID()
            let timestamp = Date()
            let panel: EditorPanel
            let previousPanelId: UUID?
            let pageId: UUID
            let windowId: UUID
        }

        struct DidDeactivate: DomainEvent {
            static let name = "panel.didDeactivate"
            let eventId = UUID()
            let timestamp = Date()
            let panelId: UUID
            let pageId: UUID
        }

        struct DidResize: DomainEvent {
            static let name = "panel.didResize"
            let eventId = UUID()
            let timestamp = Date()
            let panelId: UUID
            let oldBounds: CGRect
            let newBounds: CGRect
        }
    }

    // MARK: - Tab

    enum Tab {
        struct DidCreate: DomainEvent {
            static let name = "tab.didCreate"
            let eventId = UUID()
            let timestamp = Date()
            let tab: Tab
            let panelId: UUID
            let pageId: UUID
            let windowId: UUID
        }

        struct WillClose: DomainEvent {
            static let name = "tab.willClose"
            let eventId = UUID()
            let timestamp = Date()
            let tabId: UUID
            let panelId: UUID
            let pageId: UUID
        }

        struct DidClose: DomainEvent {
            static let name = "tab.didClose"
            let eventId = UUID()
            let timestamp = Date()
            let tabId: UUID
            let panelId: UUID
            let pageId: UUID
        }

        struct DidActivate: DomainEvent {
            static let name = "tab.didActivate"
            let eventId = UUID()
            let timestamp = Date()
            let tab: Tab
            let previousTabId: UUID?
            let panelId: UUID
            let pageId: UUID
        }

        struct DidDeactivate: DomainEvent {
            static let name = "tab.didDeactivate"
            let eventId = UUID()
            let timestamp = Date()
            let tabId: UUID
            let panelId: UUID
        }

        struct WillMove: DomainEvent {
            static let name = "tab.willMove"
            let eventId = UUID()
            let timestamp = Date()
            let tab: Tab
            let fromPanelId: UUID
            let toPanelId: UUID
        }

        struct DidMove: DomainEvent {
            static let name = "tab.didMove"
            let eventId = UUID()
            let timestamp = Date()
            let tab: Tab
            let fromPanelId: UUID
            let toPanelId: UUID
            let pageId: UUID
        }

        struct DidReorder: DomainEvent {
            static let name = "tab.didReorder"
            let eventId = UUID()
            let timestamp = Date()
            let tab: Tab
            let panelId: UUID
            let oldIndex: Int
            let newIndex: Int
        }

        struct DidChangeTitle: DomainEvent {
            static let name = "tab.didChangeTitle"
            let eventId = UUID()
            let timestamp = Date()
            let tab: Tab
            let oldTitle: String
            let newTitle: String
        }
    }

    // MARK: - Terminal

    enum Terminal {
        struct DidCreate: DomainEvent {
            static let name = "terminal.didCreate"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let tabId: UUID
            let panelId: UUID
            let cwd: String?
        }

        struct WillClose: DomainEvent {
            static let name = "terminal.willClose"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let tabId: UUID
        }

        struct DidClose: DomainEvent {
            static let name = "terminal.didClose"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let tabId: UUID
        }

        struct DidExit: DomainEvent {
            static let name = "terminal.didExit"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let tabId: UUID
            let exitCode: Int
        }

        struct DidOutput: DomainEvent {
            static let name = "terminal.didOutput"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let data: Data
        }

        struct DidChangeCwd: DomainEvent {
            static let name = "terminal.didChangeCwd"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let oldCwd: String?
            let newCwd: String
        }

        struct DidEndSelection: DomainEvent {
            static let name = "terminal.didEndSelection"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let text: String
            let screenRect: NSRect
        }

        struct DidFocus: DomainEvent {
            static let name = "terminal.didFocus"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let tabId: UUID
        }

        struct DidBlur: DomainEvent {
            static let name = "terminal.didBlur"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let tabId: UUID
        }

        struct DidChangeTitle: DomainEvent {
            static let name = "terminal.didChangeTitle"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let oldTitle: String
            let newTitle: String
        }

        struct DidBell: DomainEvent {
            static let name = "terminal.didBell"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
        }

        struct DidResize: DomainEvent {
            static let name = "terminal.didResize"
            let eventId = UUID()
            let timestamp = Date()
            let terminalId: Int
            let oldSize: (cols: Int, rows: Int)
            let newSize: (cols: Int, rows: Int)
        }
    }

    // MARK: - Plugin

    enum Plugin {
        struct DidActivate: DomainEvent {
            static let name = "plugin.didActivate"
            let eventId = UUID()
            let timestamp = Date()
            let pluginId: String
        }

        struct DidDeactivate: DomainEvent {
            static let name = "plugin.didDeactivate"
            let eventId = UUID()
            let timestamp = Date()
            let pluginId: String
        }
    }
}
```

---

## Plugin Events 示例

文件位置：`Features/Plugins/Claude/ClaudeEvents.swift`

```swift
/// Claude 插件事件（插件层定义，不进入核心代码）
enum ClaudeEvents {

    struct SessionStart: DomainEvent {
        static let name = "claude.sessionStart"
        let eventId = UUID()
        let timestamp = Date()
        let terminalId: Int
        let sessionId: String
        let tabId: UUID
    }

    struct PromptSubmit: DomainEvent {
        static let name = "claude.promptSubmit"
        let eventId = UUID()
        let timestamp = Date()
        let terminalId: Int
        let sessionId: String
        let prompt: String
    }

    struct WaitingInput: DomainEvent {
        static let name = "claude.waitingInput"
        let eventId = UUID()
        let timestamp = Date()
        let terminalId: Int
        let sessionId: String
    }

    struct ResponseComplete: DomainEvent {
        static let name = "claude.responseComplete"
        let eventId = UUID()
        let timestamp = Date()
        let terminalId: Int
        let sessionId: String
    }

    struct SessionEnd: DomainEvent {
        static let name = "claude.sessionEnd"
        let eventId = UUID()
        let timestamp = Date()
        let terminalId: Int
        let sessionId: String
    }
}
```

---

## 使用示例

### Coordinator 发射 Core 事件

```swift
class TerminalWindowCoordinator {
    private let eventBus: EventService

    func createTab(...) {
        // 1. 执行领域逻辑
        let tab = terminalWindow.createTab(...)

        // 2. 从 Aggregate 取出收集的事件
        let events = terminalWindow.flushEvents()

        // 3. 统一发射到 EventBus
        for event in events {
            eventBus.emit(event)
        }
    }
}
```

### Plugin 发射自己的事件

```swift
class ClaudePlugin: Plugin {
    private weak var context: PluginContext?

    func handleHookCallback(terminalId: Int, sessionId: String) {
        // 插件直接发射自己的事件
        context?.events.emit(ClaudeEvents.SessionStart(
            terminalId: terminalId,
            sessionId: sessionId,
            tabId: tabId
        ))
    }
}
```

### Plugin 订阅事件

```swift
class SomePlugin: Plugin {
    private var subscriptions: [EventSubscription] = []

    func activate(context: PluginContext) {
        // 订阅 Core 事件（默认主线程异步）
        subscriptions.append(
            context.events.subscribe(CoreEvents.Terminal.DidCreate.self, options: .default) { event in
                print("Terminal created: \(event.terminalId)")
            }
        )

        // 同步订阅（在发射线程执行）
        subscriptions.append(
            context.events.subscribe(CoreEvents.Tab.WillClose.self, options: .sync) { event in
                // 同步处理，可以影响后续流程
            }
        )

        // 订阅其他插件的事件
        subscriptions.append(
            context.events.subscribe(ClaudeEvents.SessionStart.self, options: .default) { event in
                print("Claude session started: \(event.sessionId)")
            }
        )
    }

    func deactivate() {
        // EventSubscription 在 deinit 时自动取消
        subscriptions.removeAll()
    }
}
```

---

## 迁移计划

### 需要废弃的 NotificationCenter 事件

| 旧事件 | 新事件 |
|--------|--------|
| `terminalDidCreate` | `CoreEvents.Terminal.DidCreate` |
| `terminalDidClose` | `CoreEvents.Terminal.DidClose` |
| `activeTerminalDidChange` | `CoreEvents.Terminal.DidFocus` |
| `tabDidFocus` | `CoreEvents.Tab.DidActivate` |
| `tabDecorationChanged` | 内部 UI 事件，不暴露 |
| `claudeSessionStart` | `ClaudeEvents.SessionStart` |
| `claudeUserPromptSubmit` | `ClaudeEvents.PromptSubmit` |
| `claudeWaitingInput` | `ClaudeEvents.WaitingInput` |
| `claudeResponseComplete` | `ClaudeEvents.ResponseComplete` |
| `claudeSessionEnd` | `ClaudeEvents.SessionEnd` |

### 实施步骤

1. **实现 EventBus** - 类型安全的事件总线，支持同步/异步
2. **实现 DomainEventCollector** - 领域层事件收集
3. **定义 CoreEvents** - 核心事件类型
4. **改造 Coordinator** - 发射 Core 事件
5. **迁移插件** - 使用新 API
6. **删除 NotificationCenter 事件** - 清理旧代码

---

## 设计决策

| 问题 | 决策 | 理由 |
|------|------|------|
| 事件发射位置 | 领域层收集，Coordinator 发射 | DDD 纯净 + 可测试 |
| 事件携带对象 | 完整对象引用 | 插件能访问任何属性 |
| 上下文字段 | 按需携带 | 避免冗余 |
| 生命周期事件 | Will + Did 成对 | 完整性 |
| 命名风格 | DidXxx / WillXxx | Apple 风格一致 |
| Plugin 事件 | 插件层定义，用 EventBus 发射 | 不污染核心层 |
| 事件权限 | 不限制，插件可发射任何事件 | 最大自由度 |
| 线程模型 | 主线程为主，支持自定义队列 | 安全 + 灵活 |
| 同步/异步 | 两者都支持 | 不同场景需求 |

---

## 错误处理

- 单个插件 handler 抛错不影响其他订阅者
- EventBus 捕获异常并记录日志
- 不提供超时/熔断（信任插件）

---

## 注意事项

1. **对象引用时序**：事件携带的对象是发射时刻的引用，如需保存状态请立即复制

2. **Terminal.DidOutput 性能**：事件量大，后续可考虑订阅级别过滤

3. **线程安全**：EventBus 内部线程安全，handler 默认主线程执行

4. **版本兼容**：DomainEvent 包含 schemaVersion，为未来扩展预留

5. **自动取消订阅**：EventSubscription 在 deinit 时自动取消，无需手动管理
