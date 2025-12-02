# ETerm 插件开发指南（AI 专用）

> **目标读者**: AI 代码助手
> **文档用途**: 快速生成符合规范的 ETerm 插件代码
> **系统状态**: MVP 阶段，底层代码可按需修改

---

## 📋 目录

1. [架构概览](#架构概览)
2. [核心类型定义](#核心类型定义)
3. [插件开发模板](#插件开发模板)
4. [系统能力清单](#系统能力清单)
5. [开发规范](#开发规范)
6. [常见模式](#常见模式)

---

## 架构概览

### 核心组件关系

```
PluginManager (单例)
    │
    ├─> PluginContext (注入容器)
    │       ├─> CommandService   (命令注册/执行)
    │       ├─> EventService     (事件发布/订阅)
    │       └─> KeyboardService  (快捷键绑定)
    │
    └─> [Plugin1, Plugin2, ...] (插件实例)
```

### 插件生命周期

```
1. PluginManager.loadPlugin(PluginType.self)
2. plugin = PluginType.init()
3. plugin.activate(context: PluginContext)
   ├─> 注册命令 (context.commands.register)
   ├─> 订阅事件 (context.events.subscribe)
   └─> 绑定快捷键 (context.keyboard.bind)
4. [插件运行中...]
5. plugin.deactivate()
   ├─> 注销命令
   ├─> 取消订阅
   └─> 清理资源
```

---

## 核心类型定义

### 1. Plugin 协议

**文件位置**: `ETerm/ETerm/Plugins/Framework/Plugin.swift`

```swift
protocol Plugin: AnyObject {
    // 插件元信息
    static var id: String { get }        // 唯一标识符，如 "translation"
    static var name: String { get }      // 显示名称，如 "划词翻译"
    static var version: String { get }   // 版本号，如 "1.0.0"

    // 生命周期
    init()                                      // 无参构造器
    func activate(context: PluginContext)       // 激活插件
    func deactivate()                           // 停用插件
}
```

### 2. PluginContext 协议

**文件位置**: `ETerm/ETerm/Plugins/Framework/PluginContext.swift`

```swift
protocol PluginContext: AnyObject {
    var commands: CommandService { get }   // 命令服务
    var events: EventService { get }       // 事件服务
    var keyboard: KeyboardService { get }  // 键盘服务
}
```

### 3. CommandService 协议

**文件位置**: `ETerm/ETerm/Application/Command/CommandService.swift`

```swift
protocol CommandService: AnyObject {
    func register(_ command: Command)                      // 注册命令
    func unregister(_ id: CommandID)                       // 注销命令
    func execute(_ id: CommandID, context: CommandContext) // 执行命令
    func exists(_ id: CommandID) -> Bool                   // 检查命令是否存在
    func allCommands() -> [Command]                        // 获取所有命令
}
```

**Command 结构**:

```swift
struct Command {
    let id: CommandID                            // 命令 ID，如 "translation.show"
    let title: String                            // 显示名称，如 "显示翻译"
    let icon: String?                            // SF Symbols 图标名（可选）
    let handler: (CommandContext) -> Void        // 命令处理器
}
```

**CommandContext 结构**:

```swift
struct CommandContext {
    weak var coordinator: TerminalWindowCoordinator?  // 窗口协调器（弱引用）
    weak var window: NSWindow?                        // 当前窗口（弱引用）
    var arguments: [String: Any]                      // 命令参数（键值对）

    var activeTerminalId: UInt32? {                   // 当前活跃终端 ID
        coordinator?.getActiveTerminalId()
    }
}
```

### 4. EventService 协议

**文件位置**: `ETerm/ETerm/Application/Event/EventService.swift`

```swift
protocol EventService: AnyObject {
    // 订阅事件（返回订阅对象用于取消）
    func subscribe<T>(_ eventId: String, handler: @escaping (T) -> Void) -> EventSubscription

    // 发布事件
    func publish<T>(_ eventId: String, payload: T)
}

// 事件订阅管理
final class EventSubscription {
    func unsubscribe()  // 取消订阅
    deinit              // 自动取消订阅
}
```

**已定义的事件**:

```swift
enum TerminalEvent {
    static let selectionEnd = "terminal.selectionEnd"  // 选区结束事件
    static let output = "terminal.output"              // 终端输出事件
}

struct SelectionEndPayload {
    let text: String              // 选中的文本
    let screenRect: NSRect        // 选区屏幕位置
    weak var sourceView: NSView?  // 触发视图
}
```

### 5. KeyboardService 协议

**文件位置**: `ETerm/ETerm/Application/Keyboard/KeyboardService.swift`

```swift
protocol KeyboardService: AnyObject {
    // 绑定快捷键到命令
    func bind(_ keyStroke: KeyStroke, to commandId: CommandID, when: String?)

    // 解除快捷键绑定
    func unbind(_ keyStroke: KeyStroke)
}

// KeyStroke 便捷构造器（实际定义见 KeyboardSystem.swift）
extension KeyStroke {
    static func cmd(_ key: String) -> KeyStroke     // Cmd + Key
    static func cmdShift(_ key: String) -> KeyStroke // Cmd + Shift + Key
    // ... 更多修饰键组合
}
```

---

## 插件开发模板

### 基础插件模板

```swift
import Foundation
import AppKit

/// <插件功能描述>
///
/// 功能：
/// - <功能点 1>
/// - <功能点 2>
final class <PluginName>Plugin: Plugin {
    // MARK: - Plugin 元信息

    static let id = "<plugin-id>"           // 如 "my-feature"
    static let name = "<插件名称>"           // 如 "我的功能"
    static let version = "1.0.0"

    // MARK: - 私有属性

    /// 插件上下文（弱引用避免循环引用）
    private weak var context: PluginContext?

    /// 事件订阅集合（用于清理）
    private var subscriptions: [EventSubscription] = []

    // MARK: - 初始化

    required init() {}

    // MARK: - Plugin 生命周期

    func activate(context: PluginContext) {
        self.context = context

        // 1. 注册命令
        registerCommands(context: context)

        // 2. 订阅事件
        subscribeEvents(context: context)

        // 3. 绑定快捷键（如果需要）
        bindKeyboard(context: context)

        print("✅ \(Self.name) 已激活")
    }

    func deactivate() {
        // 1. 取消事件订阅
        subscriptions.forEach { $0.unsubscribe() }
        subscriptions.removeAll()

        // 2. 注销命令
        context?.commands.unregister("<plugin-id>.command1")
        context?.commands.unregister("<plugin-id>.command2")

        // 3. 解绑快捷键
        context?.keyboard.unbind(.cmd("k"))

        // 4. 清理其他资源
        // ...

        print("🔌 \(Self.name) 已停用")
    }

    // MARK: - 注册命令

    private func registerCommands(context: PluginContext) {
        // 命令 1
        context.commands.register(Command(
            id: "<plugin-id>.command1",
            title: "<命令名称>",
            icon: "sparkles"  // 可选 SF Symbols 图标
        ) { [weak self] ctx in
            self?.handleCommand1(ctx)
        })

        // 命令 2
        context.commands.register(Command(
            id: "<plugin-id>.command2",
            title: "<命令名称 2>"
        ) { [weak self] ctx in
            self?.handleCommand2(ctx)
        })
    }

    // MARK: - 订阅事件

    private func subscribeEvents(context: PluginContext) {
        // 订阅选区结束事件
        let sub1 = context.events.subscribe(TerminalEvent.selectionEnd) { [weak self] (payload: SelectionEndPayload) in
            self?.onSelectionEnd(payload)
        }
        subscriptions.append(sub1)

        // 订阅其他事件...
    }

    // MARK: - 绑定快捷键

    private func bindKeyboard(context: PluginContext) {
        // 绑定 Cmd+K 到命令
        context.keyboard.bind(.cmd("k"), to: "<plugin-id>.command1", when: nil)
    }

    // MARK: - 命令处理器

    private func handleCommand1(_ context: CommandContext) {
        // 访问窗口协调器
        guard let coordinator = context.coordinator else { return }

        // 获取活跃终端 ID
        let terminalId = context.activeTerminalId

        // 实现命令逻辑...
    }

    private func handleCommand2(_ context: CommandContext) {
        // 实现命令逻辑...
    }

    // MARK: - 事件处理器

    private func onSelectionEnd(_ payload: SelectionEndPayload) {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 处理选中文本...
    }
}
```

### 注册插件

**文件位置**: `ETerm/ETerm/Plugins/Framework/PluginManager.swift:37`

在 `loadBuiltinPlugins()` 方法中添加：

```swift
func loadBuiltinPlugins() {
    loadPlugin(TranslationPlugin.self)
    loadPlugin(WritingAssistantPlugin.self)
    loadPlugin(<YourPlugin>.self)  // 添加你的插件
    print("🔌 插件管理器已初始化")
}
```

---

## 系统能力清单

### 可用的命令执行上下文

通过 `CommandContext` 可访问：

- `coordinator: TerminalWindowCoordinator?` - 窗口协调器
  - `coordinator.showInlineComposer: Bool` - 控制内联编辑器显示
  - `coordinator.getActiveTerminalId() -> UInt32?` - 获取活跃终端 ID
  - `coordinator.activePanelId: UUID?` - 活跃面板 ID
  - `coordinator.terminalWindow: TerminalWindow` - 终端窗口聚合根
- `window: NSWindow?` - 当前窗口
- `arguments: [String: Any]` - 自定义参数
- `activeTerminalId: UInt32?` - 便捷访问活跃终端 ID

### 可订阅的事件

| 事件 ID | 事件载荷 | 触发时机 | 用途 |
|--------|---------|---------|------|
| `TerminalEvent.selectionEnd` | `SelectionEndPayload` | 用户完成文本选择 | 划词翻译、文本操作 |
| `TerminalEvent.output` | (待定义) | 终端输出新内容 | 日志分析、关键词监控 |

### KeyStroke 快捷键定义

常用快捷键构造器（需查看 `KeyboardSystem.swift` 确认）：

```swift
.cmd("k")           // Cmd + K
.cmdShift("c")      // Cmd + Shift + C
.ctrl("a")          // Ctrl + A
// ... 按需扩展
```

### SF Symbols 图标

常用图标名称（可选）：

- `"sparkles"` - 魔法棒（AI 功能）
- `"doc.text"` - 文档
- `"globe"` - 地球（翻译）
- `"pencil"` - 编辑
- `"arrow.clockwise"` - 刷新
- `"gear"` - 设置

---

## 开发规范

### 1. 命名规范

| 类型 | 规范 | 示例 |
|-----|------|------|
| **插件类名** | `<Feature>Plugin` | `TranslationPlugin` |
| **Plugin ID** | `<feature>` (kebab-case) | `"translation"`, `"writing-assistant"` |
| **命令 ID** | `<plugin-id>.<action>` | `"translation.show"`, `"writing.toggle"` |
| **事件 ID** | `<domain>.<event>` | `"terminal.selectionEnd"` |

### 2. 资源管理规范

**必须遵守的规则**：

1. **事件订阅**: 必须保存 `EventSubscription` 并在 `deactivate()` 中取消
2. **弱引用**: `PluginContext`、`CommandContext` 的引用必须是 `weak`
3. **命令注销**: `deactivate()` 中必须注销所有已注册的命令
4. **快捷键解绑**: `deactivate()` 中必须解绑所有快捷键

### 3. 防抖和节流

对于高频事件（如选区变化），使用防抖：

```swift
private var debounceTimer: DispatchWorkItem?

private func onHighFrequencyEvent() {
    debounceTimer?.cancel()
    let workItem = DispatchWorkItem {
        // 实际处理逻辑
    }
    debounceTimer = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
}

func deactivate() {
    debounceTimer?.cancel()
    debounceTimer = nil
}
```

### 4. 异步操作规范

事件处理器应该快速返回，耗时操作必须异步：

```swift
private func onEvent(_ payload: SomePayload) {
    // ✅ 正确：异步处理
    DispatchQueue.main.async {
        // 耗时操作...
    }
}

// ❌ 错误：阻塞事件总线
private func onEvent(_ payload: SomePayload) {
    Thread.sleep(forTimeInterval: 1.0)  // 阻塞！
}
```

### 5. 错误处理

命令处理器应该捕获异常，避免崩溃：

```swift
private func handleCommand(_ context: CommandContext) {
    guard let coordinator = context.coordinator else {
        print("⚠️ 命令执行失败：coordinator 不可用")
        return
    }

    do {
        // 可能抛出异常的操作
    } catch {
        print("❌ 命令执行错误: \(error)")
    }
}
```

---

## 常见模式

### 模式 1: 划词响应插件

**场景**: 监听文本选中，触发某种操作（翻译、搜索、高亮等）

```swift
final class SelectionHandlerPlugin: Plugin {
    static let id = "selection-handler"
    static let name = "选区处理器"
    static let version = "1.0.0"

    private weak var context: PluginContext?
    private var subscription: EventSubscription?
    private var debounceTimer: DispatchWorkItem?

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 订阅选区结束事件
        subscription = context.events.subscribe(TerminalEvent.selectionEnd) { [weak self] (payload: SelectionEndPayload) in
            self?.onSelectionEnd(payload)
        }
    }

    func deactivate() {
        subscription?.unsubscribe()
        debounceTimer?.cancel()
    }

    private func onSelectionEnd(_ payload: SelectionEndPayload) {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 防抖：1 秒后执行
        debounceTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processSelection(text: text, rect: payload.screenRect, view: payload.sourceView)
        }
        debounceTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func processSelection(text: String, rect: NSRect, view: NSView?) {
        // 处理选中文本的逻辑...
    }
}
```

### 模式 2: 快捷键命令插件

**场景**: 注册命令并绑定快捷键（如 Cmd+K 触发写作助手）

```swift
final class ShortcutCommandPlugin: Plugin {
    static let id = "shortcut-command"
    static let name = "快捷命令"
    static let version = "1.0.0"

    private weak var context: PluginContext?

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 注册命令
        context.commands.register(Command(
            id: "shortcut.toggle",
            title: "切换功能",
            icon: "sparkles"
        ) { [weak self] ctx in
            self?.handleToggle(ctx)
        })

        // 绑定快捷键
        context.keyboard.bind(.cmd("k"), to: "shortcut.toggle", when: nil)
    }

    func deactivate() {
        context?.commands.unregister("shortcut.toggle")
        context?.keyboard.unbind(.cmd("k"))
    }

    private func handleToggle(_ context: CommandContext) {
        guard let coordinator = context.coordinator else { return }
        // 执行切换逻辑...
    }
}
```

### 模式 3: 状态管理插件

**场景**: 插件需要维护全局状态（如翻译模式开关）

```swift
// 独立的状态存储（单例）
final class MyFeatureState: ObservableObject {
    static let shared = MyFeatureState()
    @Published var isEnabled: Bool = false
    private init() {}
}

final class StatefulPlugin: Plugin {
    static let id = "stateful"
    static let name = "有状态插件"
    static let version = "1.0.0"

    private weak var context: PluginContext?
    private let state = MyFeatureState.shared

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 注册切换命令
        context.commands.register(Command(
            id: "stateful.toggle",
            title: "切换状态"
        ) { [weak self] _ in
            self?.state.isEnabled.toggle()
            print("状态已切换: \(self?.state.isEnabled ?? false)")
        })

        // 订阅事件，根据状态处理
        context.events.subscribe(TerminalEvent.selectionEnd) { [weak self] (payload: SelectionEndPayload) in
            guard let self = self, self.state.isEnabled else { return }
            // 仅在启用状态下处理...
        }
    }

    func deactivate() {
        context?.commands.unregister("stateful.toggle")
    }
}
```

### 模式 4: 多命令插件

**场景**: 插件提供多个相关命令（显示、隐藏、切换等）

```swift
final class MultiCommandPlugin: Plugin {
    static let id = "multi-command"
    static let name = "多命令插件"
    static let version = "1.0.0"

    private weak var context: PluginContext?
    private var isVisible = false

    required init() {}

    func activate(context: PluginContext) {
        self.context = context

        // 显示命令
        context.commands.register(Command(
            id: "multi.show",
            title: "显示功能"
        ) { [weak self] _ in
            self?.isVisible = true
            // 显示逻辑...
        })

        // 隐藏命令
        context.commands.register(Command(
            id: "multi.hide",
            title: "隐藏功能"
        ) { [weak self] _ in
            self?.isVisible = false
            // 隐藏逻辑...
        })

        // 切换命令
        context.commands.register(Command(
            id: "multi.toggle",
            title: "切换功能"
        ) { [weak self] ctx in
            guard let self = self else { return }
            if self.isVisible {
                context.commands.execute("multi.hide", context: ctx)
            } else {
                context.commands.execute("multi.show", context: ctx)
            }
        })

        // 绑定快捷键到切换命令
        context.keyboard.bind(.cmd("t"), to: "multi.toggle", when: nil)
    }

    func deactivate() {
        context?.commands.unregister("multi.show")
        context?.commands.unregister("multi.hide")
        context?.commands.unregister("multi.toggle")
        context?.keyboard.unbind(.cmd("t"))
    }
}
```

---

## 扩展系统能力

### 添加新事件

**场景**: 需要插件监听新的系统事件（如光标移动、窗口切换）

**步骤**:

1. 在 `EventPayloads.swift` 中定义事件和载荷：

```swift
// 文件: ETerm/ETerm/Application/Event/EventPayloads.swift

enum TerminalEvent {
    static let selectionEnd = "terminal.selectionEnd"
    static let output = "terminal.output"

    // 新增事件
    static let cursorMoved = "terminal.cursorMoved"
}

struct CursorMovedPayload {
    let terminalId: UInt32
    let row: Int
    let col: Int
}
```

2. 在适当位置发布事件：

```swift
// 在处理光标移动的代码中
EventBus.shared.publish(TerminalEvent.cursorMoved, payload: CursorMovedPayload(
    terminalId: currentTerminalId,
    row: newRow,
    col: newCol
))
```

3. 插件中订阅：

```swift
let sub = context.events.subscribe(TerminalEvent.cursorMoved) { (payload: CursorMovedPayload) in
    print("光标移动到: \(payload.row), \(payload.col)")
}
```

### 扩展 CommandContext

**场景**: 命令需要访问更多系统能力

**步骤**:

1. 修改 `CommandContext.swift`：

```swift
struct CommandContext {
    weak var coordinator: TerminalWindowCoordinator?
    weak var window: NSWindow?
    var arguments: [String: Any]

    // 新增便捷访问属性
    var currentTheme: Theme? {
        // 从某处获取主题...
    }
}
```

2. 插件中使用：

```swift
private func handleCommand(_ context: CommandContext) {
    if let theme = context.currentTheme {
        // 使用主题信息...
    }
}
```

---

## 调试技巧

### 1. 日志输出

插件中使用统一的日志格式：

```swift
print("✅ \(Self.name) 已激活")         // 成功
print("⚠️ \(Self.name): 警告信息")     // 警告
print("❌ \(Self.name): 错误信息")     // 错误
print("🔌 \(Self.name) 已停用")        // 卸载
print("⌨️ 绑定快捷键: \(keyStroke)")  // 键盘
print("💬 命令执行: \(commandId)")     // 命令
```

### 2. 验证插件加载

在 `ETermApp.swift` 或启动日志中查看：

```
🔌 插件管理器已初始化
✅ 划词翻译 v1.0.0 已加载
✅ 写作助手 v1.0.0 已加载
✅ 你的插件名 v1.0.0 已加载
```

### 3. 检查命令注册

```swift
// 在某处添加调试代码
let allCommands = CommandRegistry.shared.allCommands()
allCommands.forEach { cmd in
    print("已注册命令: \(cmd.id) - \(cmd.title)")
}
```

---

## 常见问题

### Q1: 插件无法访问 coordinator？

**原因**: `CommandContext` 中的 `coordinator` 是弱引用，可能为 nil

**解决**:

```swift
private func handleCommand(_ context: CommandContext) {
    guard let coordinator = context.coordinator else {
        print("⚠️ coordinator 不可用，命令无法执行")
        return
    }
    // 继续处理...
}
```

### Q2: 事件订阅没有触发？

**检查清单**:

1. 事件 ID 是否拼写正确？
2. 载荷类型是否匹配？
3. 订阅是否在 `activate()` 中完成？
4. 订阅对象是否被保存（否则会被立即释放）？

### Q3: 快捷键不生效？

**检查清单**:

1. 快捷键是否与系统/其他插件冲突？
2. `KeyStroke` 构造是否正确？
3. 命令 ID 是否已注册？
4. 查看 `KeyboardSystem.swift:67` - 命令系统的快捷键优先级最高

### Q4: 如何在插件间通信？

**推荐方案**: 通过事件总线

```swift
// 插件 A 发布自定义事件
context.events.publish("plugin-a.dataReady", payload: myData)

// 插件 B 订阅
context.events.subscribe("plugin-a.dataReady") { (data: MyDataType) in
    // 处理数据...
}
```

---

## 快速检查清单

在生成插件代码后，确认以下内容：

- [ ] 实现了 `Plugin` 协议的所有要求
- [ ] `static let id/name/version` 已定义
- [ ] `required init()` 已实现
- [ ] `activate()` 中注册了命令/订阅了事件/绑定了快捷键
- [ ] `deactivate()` 中正确清理了所有资源
- [ ] 使用了 `weak` 引用避免循环引用
- [ ] 事件订阅对象被保存到数组中
- [ ] 高频事件使用了防抖
- [ ] 命令 ID 遵循 `<plugin-id>.<action>` 格式
- [ ] 在 `PluginManager.loadBuiltinPlugins()` 中注册了插件

---

## 版本历史

- **v1.0.0** (2025-12-02): 初始版本，支持基础插件开发
- **当前状态**: MVP 阶段，核心框架稳定，细节可按需调整

---

## 附录: 完整示例

参考现有插件实现：

- **TranslationPlugin** (`ETerm/ETerm/Plugins/Translation/TranslationPlugin.swift`)
  - 事件订阅 + 防抖 + 命令注册
- **WritingAssistantPlugin** (`ETerm/ETerm/Plugins/WritingAssistant/WritingAssistantPlugin.swift`)
  - 快捷键绑定 + 命令切换
- **OneLineCommandPlugin** (`ETerm/ETerm/Plugins/OneLineCommand/OneLineCommandPlugin.swift`)
  - 后台命令执行 + SwiftUI 输入框 + CWD 获取

---

**文档维护**: 当底层代码发生变化时（新增事件、扩展 Context 等），请同步更新本文档。
