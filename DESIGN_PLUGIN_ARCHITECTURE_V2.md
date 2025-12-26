# ETerm 插件架构 V2 设计讨论

> 状态：讨论中 | 创建：2024-12

## 背景

当前插件架构采用进程隔离设计（Logic 在子进程，View 在主进程），带来了不必要的复杂性。本文档记录架构重构讨论。

---

## 一、架构简化：单进程方案

### 问题：为什么要拆分 View 和 Logic 到不同进程？

**当前设计**：
```
主进程                          子进程
┌─────────────┐                ┌─────────────┐
│ ViewProvider│◄─── IPC ──────│   Logic     │
│  + View     │  (Socket)      │             │
└─────────────┘                └─────────────┘
```

**初衷**：Logic 崩溃不影响主程序

**矛盾点**：
1. View 代码已经在主进程，View 崩溃照样让主程序挂
2. 大部分插件 Logic 很轻量，不太会崩
3. 为"隔离 Logic"付出的代价过高：
   - IPC 通信复杂性
   - NotificationCenter 桥接
   - 数据序列化
   - 状态同步问题
   - 开发者心智负担

### 决策：简化为单进程

**新设计**：
```
主进程
┌───────────────────────────────────┐
│  Plugin Bundle                    │
│  ┌─────────┐    ┌──────────────┐  │
│  │  Logic  │◄───│    View      │  │
│  │         │    │  (SwiftUI)   │  │
│  └─────────┘    └──────────────┘  │
└───────────────────────────────────┘
```

**优势**：
- 插件开发极其简单
- 无需考虑进程通信
- View 和 Logic 自然协作
- 性能更好（无序列化开销）

**劣势**：
- 插件崩溃会影响主程序 → 需要崩溃保护机制

---

## 二、双模式架构

### 设计：同时支持主进程模式和隔离模式

插件可通过 `manifest.json` 声明运行模式：

```json
{
    "id": "com.eterm.my-plugin",
    "runMode": "main",  // "main" | "isolated"
    ...
}
```

### 模式对比

| 特性 | `main` (主进程) | `isolated` (进程隔离) |
|------|----------------|----------------------|
| 开发复杂度 | 简单 | 需要处理 IPC |
| View ↔ Logic | 直接引用 | NotificationCenter + IPC |
| 崩溃影响 | 影响主程序 | 仅子进程挂 |
| 性能 | 更好 | 有序列化开销 |
| 适用场景 | 内置插件、轻量插件 | 第三方、重型/不稳定插件 |

### 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      ETerm.app (主进程)                      │
│                                                             │
│  ┌─────────────────────┐    ┌─────────────────────────────┐ │
│  │  runMode: "main"    │    │  runMode: "isolated"        │ │
│  │  ┌───────┬───────┐  │    │  ┌───────────────────────┐  │ │
│  │  │ Logic │ View  │  │    │  │ ViewProvider + View   │  │ │
│  │  │ 直接协作       │  │    │  └───────────┬───────────┘  │ │
│  │  └───────┴───────┘  │    │              │ IPC          │ │
│  │                     │    │              ▼              │ │
│  │  WorkspaceKit       │    │  ┌───────────────────────┐  │ │
│  │  TranslationKit     │    │  │ Extension Host 子进程  │  │ │
│  │  ...                │    │  │  ┌─────────────────┐  │  │ │
│  └─────────────────────┘    │  │  │     Logic       │  │  │ │
│                             │  │  └─────────────────┘  │  │ │
│                             │  └───────────────────────┘  │ │
│                             │                             │ │
│                             │  ThirdPartyPlugin           │ │
│                             └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 三、统一 PluginHost 接口

### 问题：两种模式的协议不同，主程序如何统一调用？

### 方案：适配器模式

主程序通过统一的 `PluginHost` 接口调用插件，不关心底层是哪种模式：

```swift
/// 主程序使用的统一接口（内部用）
@MainActor
protocol PluginHost {
    var id: String { get }

    // UI
    func sidebarView(for tabId: String) -> AnyView?
    func bottomDockView(for id: String) -> AnyView?
    func infoPanelView(for id: String) -> AnyView?
    func bubbleView(for id: String) -> AnyView?

    // 事件/命令
    func sendEvent(_ eventName: String, payload: [String: Any])
    func sendCommand(_ commandId: String)
}
```

### 两种模式的适配器

```swift
// MARK: - 主进程模式适配器

final class MainModePluginHost: PluginHost {
    private let plugin: Plugin

    var id: String { type(of: plugin).id }

    func sidebarView(for tabId: String) -> AnyView? {
        plugin.sidebarView(for: tabId)
    }

    func sendEvent(_ eventName: String, payload: [String: Any]) {
        plugin.handleEvent(eventName, payload: payload)  // 直接调用
    }
}

// MARK: - 隔离模式适配器

final class IsolatedModePluginHost: PluginHost {
    private let viewProvider: PluginViewProvider
    private let ipcBridge: PluginIPCBridge

    func sidebarView(for tabId: String) -> AnyView? {
        viewProvider.view(for: tabId)
    }

    func sendEvent(_ eventName: String, payload: [String: Any]) {
        ipcBridge.sendEvent(...)  // 通过 IPC 发到子进程
    }
}
```

### 加载器逻辑

```swift
func loadPlugin(at path: URL) -> PluginHost? {
    let manifest = loadManifest(from: path)

    switch manifest.runMode ?? .main {  // 默认主进程
    case .main:
        // Bundle 加载，获取 Plugin 实例
        let plugin = loadPluginInstance(path, manifest)
        return MainModePluginHost(plugin: plugin)

    case .isolated:
        // 保持现有逻辑
        let viewProvider = loadViewProvider(...)
        extensionHostManager.loadLogic(manifest)
        return IsolatedModePluginHost(viewProvider: viewProvider, ipc: ipcBridge)
    }
}
```

---

## 四、Plugin 协议设计（主进程模式）

### 统一的 Plugin 协议

```swift
/// 插件协议（主进程模式）
@MainActor
public protocol Plugin: AnyObject {

    static var id: String { get }

    init()

    // 生命周期
    func activate(host: HostBridge)
    func deactivate()

    // 事件处理
    func handleEvent(_ eventName: String, payload: [String: Any])
    func handleCommand(_ commandId: String)

    // UI 提供
    func sidebarView(for tabId: String) -> AnyView?
    func bottomDockView(for id: String) -> AnyView?
    func infoPanelView(for id: String) -> AnyView?
    func bubbleView(for id: String) -> AnyView?
}
```

### 使用示例

```swift
@objc(WorkspacePlugin)
public final class WorkspacePlugin: NSObject, Plugin {

    public static var id = "com.eterm.workspace"

    @Published private var folders: [Folder] = []

    public func activate(host: HostBridge) { ... }
    public func deactivate() { ... }

    public func handleEvent(_ eventName: String, payload: [String: Any]) { ... }
    public func handleCommand(_ commandId: String) { ... }

    public func sidebarView(for tabId: String) -> AnyView? {
        guard tabId == "workspace-tab" else { return nil }
        return AnyView(WorkspaceView(folders: $folders))  // 直接绑定
    }
}
```

---

## 五、崩溃保护机制

### 问题：插件崩溃导致主程序无法启动

如果某插件的 `Bundle.load()` 或初始化代码崩溃，主程序每次启动都会挂。

### 方案：加载状态追踪 + 自动禁用

**状态文件**：`~/.eterm/plugin_load_state.json`
```json
{
    "loading": "com.eterm.translation",
    "disabled": ["com.eterm.bad-plugin"],
    "crashCount": {
        "com.eterm.translation": 0,
        "com.eterm.workspace": 1
    },
    "lastCleanExit": true
}
```

**加载流程**：
```
┌─────────────────────────────────────────────────────────────┐
│ 启动                                                        │
│   │                                                         │
│   ▼                                                         │
│ 检查 lastCleanExit                                          │
│   │                                                         │
│   ├─ true → 正常流程                                        │
│   │                                                         │
│   └─ false → 检查 loading 字段                              │
│        │                                                    │
│        └─ 有值 → 该插件导致崩溃，加入 disabled 列表          │
│                  弹窗提示用户                                │
│                                                             │
│ 遍历插件列表                                                 │
│   │                                                         │
│   ▼                                                         │
│ 对每个插件：                                                 │
│   1. 检查是否在 disabled 列表 → 跳过                         │
│   2. 设置 loading = pluginId, lastCleanExit = false         │
│   3. Bundle.load() + 初始化                                 │
│   4. 清除 loading, 设置 lastCleanExit = true                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**用户恢复入口**：
- 插件管理界面显示被禁用的插件
- 提供"重新启用"按钮
- 显示禁用原因

**安全模式**：
- 连续 3 次启动崩溃 → 禁用所有插件
- 弹窗提示用户进入安全模式

### Codex 反馈的改进点

| 问题 | 改进 |
|------|------|
| 运行时崩溃未覆盖 | 考虑调用插件代码时写标记，或心跳机制 |
| "3次全禁"太粗暴 | 改为按插件计数，无法归因时才全禁 |
| 缺少版本信息 | state.json 加 pluginVersion，更新后重置 crashCount |
| 误禁用恢复 | 添加安全模式启动快捷键 (Option+启动) |

**状态文件 v2**：
```json
{
    "schemaVersion": 1,
    "loading": null,
    "disabled": {
        "com.eterm.bad-plugin": {
            "reason": "crash_on_load",
            "version": "1.0.0",
            "disabledAt": "2024-12-26T10:00:00Z"
        }
    },
    "crashCount": {
        "com.eterm.workspace": {
            "count": 1,
            "version": "1.0.0"
        }
    },
    "consecutiveCrashes": 0,
    "lastCleanExit": true
}
```

---

## 六、待讨论问题

### 3.1 插件 API 设计

- [ ] 简化后的 Plugin 协议设计
- [ ] HostBridge 是否需要调整
- [ ] View 和 Logic 如何自然协作（直接引用 vs ViewModel）

### 3.2 Bundle 加载

- [ ] 是否继续用 `.bundle` 格式
- [ ] 动态库链接问题
- [ ] ETermKit framework 如何分发

### 3.3 主程序交互

- [ ] 插件如何获取终端事件
- [ ] 插件如何调用主程序能力
- [ ] 插件间通信机制

### 3.4 生命周期

- [ ] 插件 activate/deactivate 时机
- [ ] 插件热重载
- [ ] 插件更新机制

### 3.5 安全性

- [ ] 是否需要沙盒
- [ ] 权限声明机制
- [ ] 第三方插件审核

---

## 四、讨论记录

### 2024-12-XX：架构简化讨论

**共识**：
1. 进程隔离带来的复杂性不值得
2. 简化为单进程方案
3. 需要崩溃保护机制

**待定**：
- （继续添加讨论内容）

---

## 五、参考

- 当前 SDK 文档：[Plugins/PLUGIN_SDK.md](Plugins/PLUGIN_SDK.md)
- 当前构建系统：[ETerm/docs/PLUGIN_SYSTEM_README.md](ETerm/docs/PLUGIN_SYSTEM_README.md)
