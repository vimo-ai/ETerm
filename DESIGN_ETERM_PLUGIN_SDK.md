# ETerm 开放插件 SDK 设计

## 愿景

打造 AI CLI 时代**最自由、最开放、最可自定义**的 Terminal。

## 设计原则

1. **完全开放** - 核心能暴露的都暴露，不替用户做决定
2. **崩溃隔离** - 插件逻辑崩溃不影响主应用
3. **UI 自由** - 插件可提供完整 SwiftUI 视图
4. **类型安全** - 编译期检查，告别 String-based 事件
5. **声明式配置** - Manifest 驱动，便于审核和市场展示

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│  ETerm.app 主进程                                                    │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Plugin Views (从 Bundle 加载的 SwiftUI 视图)                   │ │
│  │  - MCPRouterSettingsView                                       │ │
│  │  - ClaudeMonitorView                                           │ │
│  │  (纯 UI 代码，崩溃概率极低)                                      │ │
│  └────────────────────────────────────────────────────────────────┘ │
│         ▲                                                            │
│         │ 数据绑定 (@ObservedObject)                                 │
│         ▼                                                            │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  ViewModel Layer (主进程托管的 ObservableObject)                │ │
│  │  - 接收 Extension Host 的数据更新                               │ │
│  │  - 触发 SwiftUI 视图刷新                                        │ │
│  └────────────────────────────────────────────────────────────────┘ │
│         ▲                                                            │
│         │ IPC 消息                                                   │
└─────────┼────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Extension Host 进程                                                 │
│                                                                      │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   │
│  │ MCP-Router  │ │ Claude      │ │ DevHelper   │ │ Workspace   │   │
│  │ Logic       │ │ Monitor     │ │ Logic       │ │ Logic       │   │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘   │
│                                                                      │
│  💥 这里崩溃 → 不影响主应用 UI → Extension Host 自动重启             │
└─────────────────────────────────────────────────────────────────────┘
```

### 崩溃隔离分析

| 崩溃位置 | 影响 | 恢复方式 |
|----------|------|----------|
| View 代码 (主进程) | 主应用崩溃 | 概率极低（纯 UI 声明） |
| ViewModel (主进程) | 主应用崩溃 | 概率低（只是数据容器） |
| Plugin Logic (Host) | 不影响主应用 | 自动重启 Host |

#### View 崩溃缓解策略

虽然 SwiftUI View 运行在主进程，但通过以下机制降低风险：

1. **SafePluginView 容器** - 所有插件 View 包裹在防御性容器中，记录活跃插件用于崩溃归因
2. **ViewModel 防御性更新** - `update(from:)` 使用可选解包，静默忽略无效数据，绝不抛出异常
3. **崩溃追踪** - 记录当前渲染的插件 View，崩溃时可定位责任插件

---

## 一、插件 Bundle 结构

```
MyPlugin.bundle/
├── Contents/
│   ├── Info.plist                    # Bundle 元信息
│   ├── MacOS/
│   │   └── MyPluginLogic             # 插件逻辑（在 Host 进程运行）
│   ├── Resources/
│   │   ├── manifest.json             # 插件声明（核心配置）
│   │   └── Assets/                   # 资源文件
│   └── Views/
│       ├── MyPluginView.swift        # SwiftUI 视图（在主进程加载）
│       └── MyPluginViewModel.swift   # ViewModel
```

---

## 二、Manifest 配置

```json
{
    "id": "com.example.mcp-router",
    "name": "MCP Router",
    "version": "1.0.0",
    "minHostVersion": "2.0.0",
    "sdkVersion": "1.0.0",

    "dependencies": [
        { "id": "com.eterm.claude", "minVersion": "1.0.0" }
    ],

    "capabilities": [
        "terminal.write",
        "terminal.read",
        "ui.sidebar",
        "ui.tabDecoration"
    ],

    // 能力必须声明才能使用，运行时强制检查

    "principalClass": "MCPRouterPlugin",
    "viewModelClass": "MCPRouterViewModel",

    "sidebarTabs": [
        {
            "id": "mcp-settings",
            "title": "MCP Router",
            "icon": "server.rack",
            "viewClass": "MCPRouterSettingsView"
        }
    ],

    "commands": [
        {
            "id": "mcp.showSettings",
            "title": "显示 MCP 设置",
            "handler": "handleShowSettings",
            "keyBinding": "cmd+shift+m"
        }
    ],

    "subscribes": [
        "core.terminal.didCreate",
        "core.terminal.didOutput",
        "core.terminal.didChangeCwd"
    ]
}
```

### Manifest 字段说明

| 字段 | 必需 | 说明 |
|------|------|------|
| id | ✅ | 插件唯一标识，反向域名格式 |
| name | ✅ | 显示名称 |
| version | ✅ | 语义化版本 |
| minHostVersion | ✅ | 最低 ETerm 版本要求 |
| sdkVersion | ✅ | 使用的 SDK 版本 |
| dependencies | | 依赖的其他插件 |
| capabilities | | 需要的能力声明 |
| principalClass | ✅ | 插件逻辑入口类 |
| viewModelClass | | ViewModel 类名 |
| sidebarTabs | | 侧边栏注册 |
| commands | | 命令注册 |
| subscribes | | 订阅的事件列表 |

---

## 三、SDK 层设计 (ETermKit)

### 3.1 目录结构

```
ETermKit/
├── Package.swift
└── Sources/ETermKit/
    ├── Protocols/
    │   ├── PluginLogic.swift          # 插件逻辑协议
    │   ├── PluginViewModel.swift      # ViewModel 协议
    │   └── HostBridge.swift           # 主应用暴露的能力
    │
    ├── Events/
    │   ├── DomainEvent.swift          # 事件基础协议
    │   ├── CoreEvents.swift           # 核心 Lifecycle 事件
    │   └── EventPayload.swift         # 可序列化事件载荷
    │
    ├── Types/
    │   ├── HostInfo.swift             # 主应用信息
    │   ├── PluginManifest.swift       # Manifest 解析
    │   ├── TabDecoration.swift        # Tab 装饰
    │   └── PluginError.swift          # 错误类型
    │
    └── IPC/
        ├── IPCMessage.swift           # 进程间消息定义
        └── IPCConnection.swift        # 连接管理
```

### 3.2 PluginLogic 协议（插件逻辑层实现）

```swift
/// 插件逻辑协议 - 在 Extension Host 进程中运行
public protocol PluginLogic: AnyObject {
    /// 插件 ID（从 manifest 读取）
    static var id: String { get }

    /// 无参初始化器
    init()

    /// 激活插件
    /// - Parameter host: 主应用桥接，用于调用服务
    func activate(host: HostBridge)

    /// 停用插件
    func deactivate()

    /// 处理事件（由 Host 进程推送）
    /// - Parameters:
    ///   - eventName: 事件名称
    ///   - payload: 事件载荷（可序列化字典）
    func handleEvent(_ eventName: String, payload: [String: Any])

    /// 处理命令
    /// - Parameter commandId: 命令 ID
    func handleCommand(_ commandId: String)
}
```

### 3.3 PluginViewModel 协议（主进程运行）

```swift
/// 插件 ViewModel 协议 - 在主进程中运行
public protocol PluginViewModel: ObservableObject {
    /// 无参初始化器
    init()

    /// 从 IPC 消息更新状态
    /// - Parameter data: 序列化的状态数据
    func update(from data: [String: Any])
}
```

### 3.4 HostBridge 协议

```swift
/// 主应用桥接协议 - 插件通过此协议调用主应用能力
/// 所有方法都是异步的（通过 IPC 通信）
public protocol HostBridge: AnyObject {

    // MARK: - 主应用信息

    /// 获取主应用信息
    var hostInfo: HostInfo { get }

    // MARK: - UI 更新（发送数据给 ViewModel）

    /// 更新 ViewModel 数据
    /// - Parameters:
    ///   - viewModelId: ViewModel 标识
    ///   - data: 状态数据（必须可序列化）
    func updateViewModel(_ viewModelId: String, data: [String: Any])

    // MARK: - Tab 装饰

    /// 设置 Tab 装饰
    func setTabDecoration(terminalId: Int, decoration: TabDecoration?)

    /// 清除 Tab 装饰
    func clearTabDecoration(terminalId: Int)

    // MARK: - Tab 标题

    /// 设置 Tab 标题
    func setTabTitle(terminalId: Int, title: String)

    /// 清除 Tab 标题
    func clearTabTitle(terminalId: Int)

    // MARK: - 终端操作

    /// 写入终端
    func writeToTerminal(terminalId: Int, data: String)

    /// 获取终端信息
    func getTerminalInfo(terminalId: Int) -> TerminalInfo?

    // MARK: - 服务注册

    /// 注册服务（供其他插件调用）
    func registerService(name: String, handler: @escaping ([String: Any]) -> [String: Any]?)

    /// 调用其他插件的服务
    func callService(pluginId: String, name: String, params: [String: Any]) -> [String: Any]?

    // MARK: - 事件发射

    /// 发射自定义事件
    func emit(eventName: String, payload: [String: Any])
}
```

---

## 四、事件系统

### 4.1 事件通信流程

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  ETerm 核心层    │     │    主进程        │     │  Extension Host │
│  (领域事件产生)  │────►│   EventBus      │────►│   Plugin Logic  │
│                 │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                                                        │ handleEvent()
                                                        ▼
                                                ┌─────────────────┐
                                                │  处理业务逻辑    │
                                                │  调用 host.xxx  │
                                                └─────────────────┘
```

### 4.2 CoreEvents（核心事件）

事件通过 IPC 传递，payload 必须可序列化。

```swift
/// 核心事件名称常量
public enum CoreEventNames {
    // App
    public static let appDidLaunch = "core.app.didLaunch"
    public static let appWillTerminate = "core.app.willTerminate"

    // Window
    public static let windowDidCreate = "core.window.didCreate"
    public static let windowWillClose = "core.window.willClose"
    public static let windowDidBecomeKey = "core.window.didBecomeKey"

    // Page
    public static let pageDidCreate = "core.page.didCreate"
    public static let pageDidActivate = "core.page.didActivate"

    // Panel
    public static let panelDidCreate = "core.panel.didCreate"
    public static let panelDidSplit = "core.panel.didSplit"

    // Tab
    public static let tabDidCreate = "core.tab.didCreate"
    public static let tabDidActivate = "core.tab.didActivate"
    public static let tabDidClose = "core.tab.didClose"

    // Terminal
    public static let terminalDidCreate = "core.terminal.didCreate"
    public static let terminalDidOutput = "core.terminal.didOutput"
    public static let terminalDidChangeCwd = "core.terminal.didChangeCwd"
    public static let terminalDidExit = "core.terminal.didExit"
    public static let terminalDidFocus = "core.terminal.didFocus"
    public static let terminalDidBlur = "core.terminal.didBlur"
    public static let terminalDidResize = "core.terminal.didResize"
    public static let terminalDidBell = "core.terminal.didBell"

    // Plugin
    public static let pluginDidActivate = "core.plugin.didActivate"
    public static let pluginDidDeactivate = "core.plugin.didDeactivate"
}
```

### 4.3 事件 Payload 示例

```swift
// Terminal 创建事件
[
    "terminalId": 1,
    "tabId": "550e8400-e29b-41d4-a716-446655440000",
    "panelId": "550e8400-e29b-41d4-a716-446655440001",
    "cwd": "/Users/demo"
]

// Terminal 输出事件
[
    "terminalId": 1,
    "data": "base64EncodedString..."  // Base64 编码的输出数据
]
```

---

## 五、插件加载流程

### 5.1 Preflight 检查

```swift
class PluginLoader {
    func loadPlugin(at bundlePath: String) throws {
        // 1. 读取 manifest.json
        let manifest = try loadManifest(bundlePath)

        // 2. 版本兼容性检查
        guard isCompatible(manifest.minHostVersion) else {
            throw PluginError.incompatibleVersion(
                required: manifest.minHostVersion,
                current: hostVersion
            )
        }

        // 3. SDK 版本检查
        guard isSDKCompatible(manifest.sdkVersion) else {
            throw PluginError.incompatibleSDK(
                required: manifest.sdkVersion,
                current: sdkVersion
            )
        }

        // 4. 依赖检查
        for dep in manifest.dependencies {
            guard isPluginLoaded(dep.id, minVersion: dep.minVersion) else {
                throw PluginError.missingDependency(dep.id)
            }
        }

        // 5. 加载 View Bundle（主进程）
        try loadViews(from: bundlePath, manifest: manifest)

        // 6. 通知 Extension Host 加载逻辑
        extensionHost.loadPluginLogic(bundlePath, manifest: manifest)
    }
}
```

### 5.2 依赖拓扑排序

使用 Kahn 算法按依赖关系排序加载，必须完整实现以下逻辑：

1. **构建依赖图** - 计算每个插件的入度
2. **BFS 遍历** - 从入度为 0 的插件开始加载
3. **循环检测** - 遍历结束后检查是否所有插件都已处理，否则存在循环依赖

### 5.3 依赖处理规范

| 场景 | 处理方式 |
|------|----------|
| **循环依赖** | 检测到循环后，所有参与循环的插件都不加载，记录错误日志 |
| **依赖缺失** | 跳过该插件及所有依赖它的插件，向用户显示提示 |
| **版本不满足** | 视为依赖缺失处理 |
| **依赖加载失败** | 级联跳过所有依赖该插件的下游插件 |

### 5.4 失败恢复

- 依赖加载失败时，记录 `skippedPlugins` 列表
- 在设置页面显示跳过的插件及原因
- 用户可以选择 "重试加载" 或 "禁用该插件"

---

## 六、Extension Host

### 6.1 职责

- 运行所有插件的业务逻辑
- 与主进程通过 IPC 通信
- 崩溃后可自动重启

### 6.2 生命周期

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   启动       │────►│   运行中     │────►│   崩溃      │
│             │     │             │     │             │
└─────────────┘     └─────────────┘     └──────┬──────┘
                           ▲                    │
                           │     自动重启        │
                           └────────────────────┘
```

### 6.3 IPC 消息格式

```swift
struct IPCMessage: Codable {
    let id: UUID
    let type: MessageType
    let pluginId: String?
    let payload: [String: AnyCodable]

    enum MessageType: String, Codable {
        // Host → Plugin
        case activate
        case deactivate
        case event
        case commandInvoke

        // Plugin → Host
        case updateViewModel
        case setTabDecoration
        case writeTerminal
        case registerService
        case callService
        case emit

        // 双向
        case response        // 请求响应
        case error           // 错误响应
    }
}
```

### 6.4 IPC 合约规范

| 要求 | 说明 |
|------|------|
| **协议版本** | 消息头必须包含 `protocolVersion` 字段，不兼容版本拒绝连接 |
| **请求-响应** | 所有请求必须有对应的 `response` 或 `error` 响应，通过 `id` 关联 |
| **超时处理** | 请求超时（默认 30s）必须返回 `error` 类型响应 |
| **错误格式** | 错误响应必须包含 `errorCode` + `errorMessage` |
| **幂等性** | 相同 `id` 的重复请求返回缓存的响应 |
| **有序性** | 同一插件的消息保证 FIFO 顺序 |

### 6.5 IPC 权限检查

所有 Plugin → Host 的请求在执行前必须验证：
1. 插件是否声明了对应的 `capability`
2. 未声明能力的请求返回 `error(code: "PERMISSION_DENIED")`

---

## 七、插件开发示例

### 7.1 插件逻辑 (Extension Host 进程)

```swift
import ETermKit

public final class MCPRouterPlugin: PluginLogic {
    public static var id: String { "com.eterm.mcp-router" }

    private var host: HostBridge?
    private var servers: [ServerInfo] = []

    public init() {}

    public func activate(host: HostBridge) {
        self.host = host

        // 加载配置
        loadServerConfigs()

        // 更新 UI
        updateUI()
    }

    public func deactivate() {
        // 清理资源
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case CoreEventNames.terminalDidChangeCwd:
            if let cwd = payload["newCwd"] as? String {
                // 根据目录切换 workspace
                switchWorkspace(for: cwd)
            }
        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "mcp.showSettings":
            // 通知主进程显示设置
            host?.updateViewModel("mcp-router", data: [
                "action": "showSettings"
            ])
        default:
            break
        }
    }

    private func updateUI() {
        host?.updateViewModel("mcp-router", data: [
            "servers": servers.map { $0.toDictionary() },
            "isRunning": true,
            "port": 19104
        ])
    }
}
```

### 7.2 ViewModel (主进程)

```swift
import SwiftUI
import ETermKit

public final class MCPRouterViewModel: PluginViewModel, ObservableObject {
    @Published var servers: [ServerInfo] = []
    @Published var isRunning: Bool = false
    @Published var port: Int = 19104

    public init() {}

    public func update(from data: [String: Any]) {
        if let serversData = data["servers"] as? [[String: Any]] {
            servers = serversData.compactMap { ServerInfo(from: $0) }
        }
        if let running = data["isRunning"] as? Bool {
            isRunning = running
        }
        if let p = data["port"] as? Int {
            port = p
        }
    }
}
```

### 7.3 View (主进程)

```swift
import SwiftUI

public struct MCPRouterSettingsView: View {
    @ObservedObject var viewModel: MCPRouterViewModel

    public var body: some View {
        VStack {
            HStack {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isRunning ? "运行中" : "已停止")
                Text("端口: \(viewModel.port)")
            }

            List(viewModel.servers) { server in
                ServerRow(server: server)
            }
        }
    }
}
```

---

## 八、插件安装位置

| 位置 | 用途 | 加载优先级 |
|------|------|-----------|
| `ETerm.app/Contents/PlugIns/` | 内置插件 | 1 (最先) |
| `~/.eterm/plugins/` | 用户安装 | 2 |
| `$ETERM_PLUGIN_PATH` | 开发调试 | 3 (覆盖) |

---

## 九、安全与稳定性

### 9.1 崩溃归因

必须实现完整的崩溃追踪机制：

1. **活跃插件记录** - 持续记录当前活跃的插件列表到 UserDefaults
2. **View 渲染追踪** - 记录当前正在渲染的插件 View
3. **Extension Host 崩溃** - 记录崩溃时正在处理的插件和消息
4. **启动检查** - 检测上次是否异常退出，如果是则显示崩溃恢复对话框，列出可疑插件

### 9.2 安全模式

| 模式 | 触发方式 | 加载范围 |
|------|----------|----------|
| **正常模式** | 默认启动 | 所有已启用插件 |
| **安全模式** | 按住 Shift 启动 | 仅内置插件 |
| **诊断模式** | 崩溃恢复对话框选择 | 排除可疑插件 |
| **最小模式** | 命令行 `--no-plugins` | 不加载任何插件 |

### 9.3 Capabilities 运行时强制

插件在 manifest 中声明的 capabilities 必须在运行时强制执行：

| Capability | 控制范围 |
|------------|----------|
| `terminal.write` | `writeToTerminal()` |
| `terminal.read` | 接收 `terminalDidOutput` 事件 |
| `ui.sidebar` | `registerSidebarTab()` |
| `ui.tabDecoration` | `setTabDecoration()` |
| `ui.tabSlot` | `registerTabSlot()` |
| `service.register` | `registerService()` |
| `service.call` | `callService()` |

未声明对应 capability 的调用必须返回权限错误。

### 9.4 插件更新安全

| 要求 | 说明 |
|------|------|
| **签名验证** | 更新包必须验证开发者签名 |
| **版本检查** | 禁止降级安装（除非用户明确确认） |
| **权限变更提示** | 新版本请求额外 capabilities 时必须提示用户 |
| **重启生效** | 更新后必须重启 ETerm 才能加载新版本 |

---

## 十、事件命名规范

| 类型 | 前缀 | 示例 |
|------|------|------|
| 核心事件 | `core.` | `core.terminal.didCreate` |
| 插件事件 | `plugin.<id>.` | `plugin.mcp-router.didRefresh` |

---

## 十一、设计决策

| 问题 | 决策 | 理由 |
|------|------|------|
| 进程模型 | View 主进程 + Logic 独立进程 | 崩溃隔离 + UI 自由 |
| 通信方式 | Unix Domain Socket | 易于重连/超时/多路复用，错误隔离清晰 |
| 消息分帧 | Length-prefixed framing | 4 字节长度前缀 + JSON 消息体 |
| 编解码 | JSON（可升级 MessagePack） | 先跑通，后续可优化 |
| 接口风格 | 表面 async、内部可同步 | 协议层异步，业务层可提供 sync sugar |
| 配置方式 | 声明式 Manifest | 便于审核、市场展示 |
| SDK 分发 | SwiftPM 包 | 易于依赖管理 |
| 事件传递 | 字符串名 + 字典 payload | 可序列化跨进程 |
| 热加载 | 不支持代码热换 | Swift Bundle 限制 |
| 更新方式 | 重启生效 | 接受限制，体验优化 |

---

## 十二、实现约束

**以下约束必须严格遵守，不允许简化或临时方案：**

| 约束 | 说明 |
|------|------|
| **依赖循环检测** | 必须完整实现，检测到循环时正确处理，不能假设无循环 |
| **IPC 请求-响应** | 每个请求必须有响应，必须实现超时机制，不能 fire-and-forget |
| **Capability 检查** | 必须运行时检查，不能只在加载时检查或跳过 |
| **崩溃追踪** | 必须完整实现活跃插件记录和恢复对话框 |
| **ViewModel 防御** | `update(from:)` 必须防御性实现，不能假设数据格式正确 |
| **错误传递** | 所有错误必须有明确的 errorCode 和 message，不能静默失败 |
| **安全模式** | 所有四种模式必须完整实现 |
| **过期代码标注** | 被新架构替代的旧代码必须标注 `@available(*, deprecated)` 或 `// DEPRECATED:`，迁移完成后统一删除 |
| **不妥协原则** | 遇到复杂问题不做临时方案，不自作主张做架构决策，先讨论再实现 |
