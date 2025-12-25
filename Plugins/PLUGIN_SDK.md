# ETerm Plugin SDK 开发指南

## 架构概述

ETerm 采用进程隔离的插件架构：

```
ETerm.app (主进程)
    ↓ Unix Domain Socket IPC
ETermExtensionHost (插件宿主进程)
    ↓ 动态加载
Plugin.bundle (插件逻辑)
```

- 插件逻辑在独立进程中运行，崩溃不影响主程序
- 通过 IPC 与主进程通信
- 共享 `ETermKit.framework` SDK

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
├── Package.swift           # SPM 配置
├── build.sh               # 构建脚本
├── Resources/
│   └── manifest.json      # 插件清单
└── Sources/MyPlugin/
    └── MyPluginLogic.swift # 插件逻辑入口
```

### 3. 编辑插件逻辑

`Sources/MyPlugin/MyPluginLogic.swift`:

```swift
import Foundation
import ETermKit

@objc(MyPluginLogic)
public final class MyPluginLogic: NSObject, PluginLogic {
    public static var id: String { "com.eterm.my-plugin" }

    private var host: HostBridge?

    public required override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host
        // 插件激活时调用
    }

    public func deactivate() {
        // 插件停用时调用
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 处理来自主进程的事件
    }

    public func handleCommand(_ commandId: String) {
        // 处理命令调用
    }
}
```

### 4. 配置清单

`Resources/manifest.json`:

```json
{
    "id": "com.eterm.my-plugin",
    "name": "My Plugin",
    "version": "1.0.0",
    "minHostVersion": "1.0.0",
    "sdkVersion": "1.0.0",
    "principalClass": "MyPluginLogic",
    "capabilities": ["ui.sidebar"],
    "commands": [
        {
            "id": "my-plugin.do-something",
            "title": "Do Something",
            "handler": "handleDoSomething"
        }
    ],
    "sidebarTabs": [
        {
            "id": "my-plugin-tab",
            "title": "My Plugin",
            "icon": "star.fill",
            "viewClass": "MyPluginView"
        }
    ],
    "subscribes": ["terminal.output", "terminal.title"]
}
```

### 5. 构建安装

```bash
cd MyPlugin
./build.sh
```

输出: `~/.eterm/plugins/MyPlugin.bundle`

### 6. 测试

重启 ETerm，查看 Console 日志确认插件加载成功。

---

## API 参考

### PluginLogic 协议

```swift
public protocol PluginLogic: NSObject {
    static var id: String { get }

    init()
    func activate(host: HostBridge)
    func deactivate()
    func handleEvent(_ eventName: String, payload: [String: Any])
    func handleCommand(_ commandId: String)
}
```

### HostBridge (与主进程通信)

```swift
// 更新 ViewModel 数据（主进程 UI 会自动刷新）
host.updateViewModel(pluginId, data: [
    "isRunning": true,
    "message": "Hello"
])

// 发送事件到主进程
host.sendEvent("my-plugin.status-changed", payload: ["status": "ready"])

// 调用主进程服务
host.callService("terminal", method: "write", params: ["text": "hello"])
```

### Manifest 字段

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| id | String | ✓ | 唯一标识符 (如 com.eterm.xxx) |
| name | String | ✓ | 显示名称 |
| version | String | ✓ | 版本号 |
| principalClass | String | ✓ | 入口类名 (需 @objc 导出) |
| capabilities | [String] | | 声明的能力 |
| commands | [Command] | | 注册的命令 |
| sidebarTabs | [Tab] | | 侧边栏标签页 |
| subscribes | [String] | | 订阅的事件 |

### Capabilities

- `ui.sidebar` - 添加侧边栏标签页
- `terminal.read` - 读取终端输出
- `terminal.write` - 写入终端
- `fs.read` - 读取文件系统
- `fs.write` - 写入文件系统

---

## 迁移现有插件

如果要将现有 Swift 代码迁移为 SDK 插件：

1. 创建插件骨架: `./create-plugin.sh PluginName`
2. 将业务逻辑移入 `PluginNameLogic.swift`
3. 使用 `PluginLogic` 协议包装
4. UI 部分需要通过 `host.updateViewModel()` 与主进程通信
5. 配置 `manifest.json` 声明能力和命令

---

## 常见问题

### Q: 插件加载失败 "Bundle.load() failed"
A: 检查 dylib 链接路径，确保 `build.sh` 正确修复了 ETermKit 链接。

### Q: 类型转换失败
A: 确保 `@objc(ClassName)` 与 manifest 中的 `principalClass` 一致。

### Q: 如何调试
A: 查看 Xcode Console 或 `~/.eterm/logs/` 中的日志。

---

## 示例插件

参考 `MCPRouterSDK` 插件的实现：
- `Plugins/MCPRouterSDK/`
