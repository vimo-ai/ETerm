# ETerm Plugin SDK 开发指南

> 版本: 0.0.1-beta.1 | 最后更新: 2024-12

## 架构概述

ETerm 采用进程隔离的插件架构：

```
ETerm.app (主进程)
    │
    ├── Plugin Views (SwiftUI 视图，从 Bundle 加载)
    │   └── 通过 NotificationCenter 与 Logic 通信
    │
    ↓ Unix Domain Socket IPC

ETermExtensionHost (插件宿主进程)
    │
    └── Plugin Logic (业务逻辑，崩溃不影响主应用)
```

**核心优势**：
- 插件逻辑崩溃不影响主程序
- 视图可直接使用 SwiftUI
- 共享 `ETermKit.framework` SDK

---

## 快速开始

### 1. 创建插件

```bash
cd Plugins
./create-plugin.sh MyPlugin              # ID: com.eterm.my-plugin
./create-plugin.sh MyPlugin com.foo.bar  # 自定义 ID
```

### 2. 生成的目录结构

```
MyPluginKit/
├── Package.swift              # SPM 配置
├── build.sh                   # 构建脚本
├── Resources/
│   └── manifest.json          # 插件清单（核心配置）
└── Sources/MyPluginKit/
    ├── MyPluginLogic.swift    # 业务逻辑（Extension Host 进程）
    └── MyPluginViewProvider.swift  # 视图提供（主进程，可选）
```

### 3. 构建安装

```bash
cd MyPluginKit
./build.sh                     # 构建并安装到 ~/.eterm/plugins/
```

重启 ETerm 后插件自动加载。

---

## 核心概念

### 插件组成

| 组件 | 运行位置 | 职责 |
|------|----------|------|
| `*Logic.swift` | Extension Host | 业务逻辑、数据处理、与主进程通信 |
| `*ViewProvider.swift` | 主进程 | 提供 SwiftUI 视图 |
| `manifest.json` | - | 插件配置、能力声明 |

### 通信机制

```
Logic (Extension Host)          View (主进程)
        │                              │
        │ host.updateViewModel()       │
        ├─────────────────────────────►│
        │                              │ NotificationCenter
        │ handleRequest()              │    监听更新
        │◄─────────────────────────────┤
        │                              │
```

---

## Manifest 配置

`Resources/manifest.json`:

```json
{
    "id": "com.eterm.my-plugin",
    "name": "My Plugin",
    "version": "0.0.1-beta.1",
    "minHostVersion": "0.0.1-beta.1",
    "sdkVersion": "0.0.1-beta.1",
    "dependencies": [],
    "capabilities": ["ui.sidebar"],
    "principalClass": "MyPluginLogic",
    "viewProviderClass": "MyPluginViewProvider",
    "sidebarTabs": [
        {
            "id": "my-plugin-tab",
            "title": "My Plugin",
            "icon": "star.fill",
            "viewClass": "MyPluginView",
            "renderMode": "tab"
        }
    ],
    "commands": [
        {
            "id": "my-plugin.refresh",
            "title": "Refresh",
            "handler": "handleRefresh"
        }
    ],
    "subscribes": ["core.terminal.didCreate"],
    "emits": ["plugin.my-plugin.dataChanged"]
}
```

### 字段说明

| 字段 | 必需 | 说明 |
|------|------|------|
| `id` | ✓ | 唯一标识符 (反向域名格式) |
| `name` | ✓ | 显示名称 |
| `version` | ✓ | 语义化版本号 |
| `minHostVersion` | ✓ | 最低 ETerm 版本要求 |
| `sdkVersion` | ✓ | SDK 版本 |
| `principalClass` | ✓ | Logic 入口类名 (需 @objc 导出) |
| `viewProviderClass` | | ViewProvider 类名 (需 @objc 导出) |
| `capabilities` | | 声明的能力列表 |
| `sidebarTabs` | | 侧边栏标签页配置 |
| `commands` | | 注册的命令 |
| `subscribes` | | 订阅的事件列表 |
| `emits` | | 发出的事件列表 |

### Capabilities 能力声明

| 能力 | 说明 |
|------|------|
| `ui.sidebar` | 添加侧边栏标签页 |
| `terminal.read` | 读取终端输出 |
| `terminal.write` | 写入终端 |
| `service.register` | 注册服务供其他插件调用 |
| `service.call` | 调用其他插件服务 |

---

## 代码示例

### Logic 层（Extension Host 进程）

```swift
import Foundation
import ETermKit

@objc(MyPluginLogic)
public final class MyPluginLogic: NSObject, PluginLogic, @unchecked Sendable {

    public static var id: String { "com.eterm.my-plugin" }

    // 串行队列保护可变状态
    private let stateQueue = DispatchQueue(label: "com.eterm.my-plugin.state")
    private var _host: HostBridge?

    private var host: HostBridge? {
        get { stateQueue.sync { _host } }
        set { stateQueue.sync { _host = newValue } }
    }

    public required override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host
        // 发送初始状态到 View
        updateUI()
    }

    public func deactivate() {
        host = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 处理订阅的事件
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "my-plugin.refresh":
            updateUI()
        default:
            break
        }
    }

    public func handleRequest(_ requestId: String, params: [String: Any]) -> [String: Any] {
        // 处理 View 发来的请求
        switch requestId {
        case "getData":
            return ["success": true, "data": "Hello"]
        default:
            return ["success": false, "error": "Unknown request"]
        }
    }

    private func updateUI() {
        host?.updateViewModel(Self.id, data: [
            "message": "Hello from Logic",
            "count": 42
        ])
    }
}
```

### ViewProvider 层（主进程）

```swift
import Foundation
import SwiftUI
import ETermKit

@objc(MyPluginViewProvider)
public final class MyPluginViewProvider: NSObject, PluginViewProvider {

    public required override init() {
        super.init()
    }

    @MainActor
    public func createSidebarView(tabId: String, viewModel: Any?) -> AnyView {
        switch tabId {
        case "my-plugin-tab":
            return AnyView(MyPluginView())
        default:
            return AnyView(Text("Unknown tab"))
        }
    }
}

// MARK: - View

struct MyPluginView: View {
    @StateObject private var state = MyPluginViewState()

    var body: some View {
        VStack {
            Text(state.message)
            Text("Count: \(state.count)")

            Button("Refresh") {
                state.sendRequest("getData", params: [:])
            }
        }
        .onAppear { state.startListening() }
        .onDisappear { state.stopListening() }
    }
}

// MARK: - View State

final class MyPluginViewState: ObservableObject {
    @Published var message: String = ""
    @Published var count: Int = 0

    private var observer: Any?

    func startListening() {
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ETerm.UpdateViewModel"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleUpdate(notification)
        }

        // 请求初始数据
        sendRequest("getData", params: [:])
    }

    func stopListening() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let pluginId = userInfo["pluginId"] as? String,
              pluginId == "com.eterm.my-plugin",
              let data = userInfo["data"] as? [String: Any] else {
            return
        }

        if let msg = data["message"] as? String {
            message = msg
        }
        if let cnt = data["count"] as? Int {
            count = cnt
        }
    }

    func sendRequest(_ requestId: String, params: [String: Any]) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.PluginRequest"),
            object: nil,
            userInfo: [
                "pluginId": "com.eterm.my-plugin",
                "requestId": requestId,
                "params": params
            ]
        )
    }
}
```

---

## HostBridge API

Logic 通过 `HostBridge` 与主进程通信：

```swift
// 更新 ViewModel 数据（触发 View 刷新）
host.updateViewModel(pluginId, data: [
    "key": "value"
])

// 发送事件
host.emit(eventName: "plugin.my-plugin.dataChanged", payload: ["id": 123])

// 调用其他插件服务
let result = host.callService(
    pluginId: "com.eterm.workspace",
    name: "getFolders",
    params: [:]
)
```

---

## Package.swift 配置

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MyPluginKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MyPluginKit",
            type: .dynamic,
            targets: ["MyPluginKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "MyPluginKit",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
```

---

## 内置插件分发

内置插件会随 ETerm.app 打包分发，首次启动时自动安装到 `~/.eterm/plugins/`。

**开发流程**:
1. 修改插件代码
2. Cmd+B 构建（自动打包到 app bundle）
3. 运行 ETerm（自动复制到用户目录）
4. 插件生效

---

## 常见问题

### Q: 插件加载失败 "Bundle.load() failed"
检查 dylib 链接路径，确保 `build.sh` 正确修复了 ETermKit 链接。

### Q: @objc 类型转换失败
确保 `@objc(ClassName)` 与 manifest 中的 `principalClass` / `viewProviderClass` 一致。

### Q: 如何调试
查看 Xcode Console 日志，搜索 `[PluginName]` 前缀。

### Q: View 数据不更新
1. 确认 Logic 调用了 `host.updateViewModel()`
2. 确认 View 在 `onAppear` 时调用了 `startListening()`
3. 确认 pluginId 匹配

---

## 示例插件

参考现有插件实现：

| 插件 | 说明 |
|------|------|
| `WorkspaceKit` | 完整示例：Logic + ViewProvider + 树形视图 |
| `TranslationKit` | 简单示例：侧边栏标签页 |
| `WritingAssistantKit` | 写作辅助功能 |
| `MCPRouterKit` | MCP 服务器管理（带 Rust dylib） |

---

## 版本历史

- **0.0.1-beta.1**: 初始 SDK 架构，支持 Logic/ViewProvider 分离
