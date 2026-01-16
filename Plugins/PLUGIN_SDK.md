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
MyPlugin/
├── Package.swift              # SPM 配置
├── build.sh                   # 构建脚本
├── Resources/
│   └── manifest.json          # 插件清单（核心配置）
└── Sources/MyPlugin/
    └── MyPluginPlugin.swift   # 插件入口（main 模式）
```

### 3. 构建安装

```bash
cd MyPluginKit
./build.sh                     # 构建并安装到 ~/.vimo/eterm/plugins/
```

重启 ETerm 后插件自动加载。

---

## 核心概念

### 插件组成

| 组件 | 运行位置 | 职责 |
|------|----------|------|
| `*Plugin.swift` | 主进程 | 业务逻辑 + 视图提供（实现 `Plugin` 协议）|
| `manifest.json` | - | 插件配置、能力声明 |

### 运行模式

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| `main` | 在主进程运行，可直接返回 SwiftUI 视图 | 推荐，适合大多数插件 |
| `isolated` | 逻辑运行在独立进程，通过 IPC 通信 | 需要崩溃隔离时使用 |

> **注意**: 当前所有内置插件都使用 `main` 模式。

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

### Plugin 入口（main 模式）

```swift
import Foundation
import SwiftUI
import ETermKit

@objc(MyPluginPlugin)
@MainActor
public final class MyPluginPlugin: NSObject, ETermKit.Plugin {

    public static var id = "com.eterm.my-plugin"

    private var host: HostBridge?
    @Published private var items: [String] = []

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func activate(host: HostBridge) {
        self.host = host
        print("[MyPluginPlugin] Activated")
    }

    public func deactivate() {
        print("[MyPluginPlugin] Deactivated")
    }

    // MARK: - Event Handling

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        switch eventName {
        case "terminal.didCreate":
            if let terminalId = payload["terminalId"] as? Int {
                print("Terminal created: \(terminalId)")
            }
        default:
            break
        }
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "my-plugin.refresh":
            items = ["Item 1", "Item 2"]
        default:
            break
        }
    }

    // MARK: - View Providers

    public func sidebarView(for tabId: String) -> AnyView? {
        switch tabId {
        case "my-plugin-tab":
            return AnyView(MyPluginSidebarView(items: $items))
        default:
            return nil
        }
    }

    // 其他视图方法使用默认实现（返回 nil）
}

// MARK: - View

struct MyPluginSidebarView: View {
    @Binding var items: [String]

    var body: some View {
        List(items, id: \.self) { item in
            Text(item)
        }
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

内置插件会随 ETerm.app 打包分发，首次启动时自动安装到 `~/.vimo/eterm/plugins/`。

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
