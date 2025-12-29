# ETerm + Memex + Vlaude 集成设计

> ETerm 内置 memex 和 vlaude 能力，通过 ClaudePlugin 事件驱动，提供比独立版本更好的体验。

## 核心优势

```
独立版本 (memex/vlaude-daemon):
└── file watcher 轮询 ~/.claude/projects/
    └── 延迟检测 + 资源消耗

ETerm 版本:
└── ClaudePlugin 精确知道会话状态
    └── 事件驱动 → 实时 + 高效 + 零配置
```

## 架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                         ETerm                                    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                  ClaudePlugin (协调者)                       ││
│  │                                                             ││
│  │  已有能力:                                                   ││
│  │  - ClaudeSessionMapper (sessionId ↔ terminalId)             ││
│  │  - ClaudeEvents.SessionStart / ResponseComplete / SessionEnd││
│  │                                                             ││
│  │  广播事件 ─────────┬─────────────────────┐                  ││
│  └────────────────────┼─────────────────────┼──────────────────┘│
│                       ▼                     ▼                   │
│              ┌─────────────────┐   ┌─────────────────┐          │
│              │    MemexKit     │   │   VlaudeKit     │          │
│              │   (SDK 插件)    │   │   (SDK 插件)    │          │
│              │                 │   │                 │          │
│              │  HTTP 服务模式  │   │  HTTP 服务模式  │          │
│              │                 │   │                 │          │
│              │  - 索引会话     │   │  - 直连 server  │          │
│              │  - 搜索         │   │  - 状态同步     │          │
│              │  - Web UI       │   │  - 远程注入     │          │
│              │  - MCP 能力     │   │                 │          │
│              └────────┬────────┘   └────────┬────────┘          │
│                       │ HTTP                │ WebSocket         │
│                       ▼                     ▼                   │
│              ┌─────────────────┐   ┌─────────────────┐          │
│              │  memex 进程     │   │  vlaude-server  │          │
│              │  localhost:10013│   │  (NAS 远端)     │          │
│              └─────────────────┘   └─────────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

## 方案选择：HTTP 服务模式 vs FFI 模式

### 为什么选择 HTTP 服务模式

| 考虑因素 | FFI 模式 | HTTP 服务模式 |
|----------|----------|---------------|
| Web UI 支持 | ❌ 无法提供 | ✅ 内嵌 WebView |
| MCP 服务 | ❌ 需要额外实现 | ✅ 原生支持 |
| 外部工具调用 | ❌ 仅限 ETerm | ✅ curl/浏览器 |
| 实现复杂度 | 高（FFI 层） | 低（HTTP API） |
| 性能 | 最优 | 略有开销（可接受） |

**结论**：为了支持沉浸式 Web UI 体验和 MCP 能力，选择 HTTP 服务模式。

### 优化点：事件驱动索引

虽然使用 HTTP 模式，但通过事件驱动实现精确索引，去掉 file watcher 的延迟：

```
┌─────────────────────────────────────────────────────────────────┐
│  ClaudePlugin                                                    │
│      │                                                          │
│      │ emit("claude.responseComplete", { transcriptPath: ... }) │
│      ▼                                                          │
│  MemexKit.handleEvent()                                         │
│      │                                                          │
│      │ POST /api/index { path: transcriptPath }                 │
│      ▼                                                          │
│  memex 进程                                                      │
│      │                                                          │
│      └── 精确索引该 JSONL 文件（无需扫描整个目录）               │
└─────────────────────────────────────────────────────────────────┘
```

## 事件协议

### ClaudePlugin 广播的事件

```swift
// ETerm/ETerm/Features/Plugins/Claude/
struct ClaudeEvents {

    struct SessionStart: Event {
        let sessionId: String
        let terminalId: Int
        let projectPath: String
        let transcriptPath: String  // JSONL 文件路径
    }

    struct ResponseComplete: Event {
        let sessionId: String
        let terminalId: Int
        let projectPath: String
        let transcriptPath: String  // JSONL 文件路径
    }

    struct SessionEnd: Event {
        let sessionId: String
        let terminalId: Int
    }
}
```

### SDK 事件订阅

```json
// MemexKit/manifest.json
{
    "subscribes": ["claude.responseComplete"]
}

// VlaudeKit/manifest.json
{
    "subscribes": ["claude.sessionStart", "claude.responseComplete", "claude.sessionEnd"]
}
```

### 事件处理

```swift
// MemexKit
public func handleEvent(_ eventName: String, payload: [String: Any]) {
    guard eventName == "claude.responseComplete" else { return }
    guard let transcriptPath = payload["transcriptPath"] as? String else { return }

    Task {
        // 调用 HTTP API 触发精确索引
        try? await MemexService.shared.indexSession(path: transcriptPath)
    }
}

// VlaudeKit
public func handleEvent(_ eventName: String, payload: [String: Any]) {
    switch eventName {
    case "claude.sessionStart":
        // 上报 session 可用
        let sessionId = payload["sessionId"] as? String
        vlaudeClient.reportSessionAvailable(sessionId: sessionId, ...)

    case "claude.responseComplete":
        // 更新 session 状态
        vlaudeClient.reportSessionUpdate(...)

    case "claude.sessionEnd":
        // 上报 session 不可用
        vlaudeClient.reportSessionUnavailable(...)
    }
}
```

## MemexKit 设计

### 架构

```
MemexKit (SDK 插件)
    │
    ├── MemexPlugin.swift      # 插件入口，handleEvent 触发索引
    ├── MemexService.swift     # HTTP 客户端，管理 memex 进程
    ├── MemexView.swift        # 原生状态仪表盘
    └── MemexWebView.swift     # 内嵌 Web UI
            │
            │ HTTP (localhost:10013)
            ▼
    memex 进程 (Rust 二进制)
        ├── HTTP API (/api/search, /api/index, /api/stats)
        ├── Web UI (静态文件服务)
        ├── MCP Server (/api/mcp)
        └── SQLite + LanceDB (本地存储)
```

### memex-rs 需要添加的 API

```rust
// POST /api/index
// 精确索引单个 JSONL 文件
#[derive(Deserialize)]
struct IndexRequest {
    path: String,  // JSONL 文件路径
}

async fn index_session(Json(req): Json<IndexRequest>) -> Result<Json<IndexResponse>> {
    // 1. 解析 JSONL 文件
    // 2. 更新 SQLite (FTS5)
    // 3. 更新向量索引 (LanceDB)
    // 4. 返回索引结果
}
```

### manifest.json

```json
{
    "id": "com.eterm.memex",
    "name": "Memex",
    "version": "1.0.0",
    "minHostVersion": "0.0.1-beta.1",
    "sdkVersion": "0.0.1-beta.1",
    "runMode": "main",
    "loadPriority": "immediate",
    "dependencies": [{"id": "com.eterm.claude", "minVersion": "1.0.0"}],
    "principalClass": "MemexPlugin",
    "subscribes": ["claude.responseComplete"],
    "sidebarTabs": [
        {
            "id": "memex",
            "title": "Memex",
            "icon": "brain.head.profile",
            "viewClass": "MemexView",
            "renderMode": "tab"
        }
    ]
}
```

## VlaudeKit 设计

### 架构

```
VlaudeKit (SDK 插件)
    │
    ├── VlaudePlugin.swift     # 插件入口，handleEvent 上报状态
    ├── VlaudeClient.swift     # WebSocket 客户端
    └── (无 UI，仅 Tab Slot)
            │
            │ WebSocket (wss://...)
            ▼
    vlaude-server (NAS)
        ├── 管理 session 状态
        ├── 转发远程注入请求
        └── 推送 Mobile 查看状态
```

### manifest.json

```json
{
    "id": "com.eterm.vlaude",
    "name": "Vlaude Remote",
    "version": "1.0.0",
    "minHostVersion": "0.0.1-beta.1",
    "sdkVersion": "0.0.1-beta.1",
    "runMode": "main",
    "dependencies": [{"id": "com.eterm.claude", "minVersion": "1.0.0"}],
    "principalClass": "VlaudePlugin",
    "subscribes": [
        "claude.sessionStart",
        "claude.responseComplete",
        "claude.sessionEnd"
    ],
    "tabSlots": [
        {
            "id": "vlaude-mobile-viewing",
            "priority": 50
        }
    ]
}
```

## 实施路线

### Phase 1: 事件协议 ✅ 已完成

1. ✅ ClaudePlugin 事件已包含 transcriptPath
2. ✅ SDK 事件系统已支持 subscribes + handleEvent

### Phase 2: MemexKit 精确索引 ✅ 已完成

1. [x] MemexKit 基础框架（Plugin、Service、UI）
2. [x] Web UI 内嵌（MemexWebView）
3. [x] **memex-rs 添加 `POST /api/index` 接口**
4. [x] **MemexKit handleEvent 调用索引 API**
5. [ ] 测试事件驱动索引

### Phase 3: VlaudeKit

1. [ ] 创建 VlaudeKit SDK 插件
2. [ ] WebSocket 客户端（直连 server，不经过 daemon）
3. [ ] 实现 handleEvent 上报 session 状态
4. [ ] 实现远程注入回调
5. [ ] Tab Slot（显示 Mobile 查看图标）

### Phase 4: 清理

1. [ ] 删除内嵌 VlaudePlugin
2. [ ] 更新文档
3. [ ] daemon 标记为可选（非 ETerm 用户仍可使用）

## 相关文件

### 现有代码

- ClaudePlugin: `ETerm/ETerm/Features/Plugins/Claude/`
- VlaudePlugin (待迁移): `ETerm/ETerm/Features/Plugins/Vlaude/`
- MemexKit: `Plugins/MemexKit/`

### 外部依赖

- memex-rs: `/Users/higuaifan/Desktop/vimo/memex/memex-rs`
- ai-cli-session-collector: `/Users/higuaifan/Desktop/vimo/ai-cli-session-collector`
- vlaude-server: `/Users/higuaifan/Desktop/hi/小工具/claude/packages/vlaude-server`

## 对比: ETerm vs 独立版本

| 能力 | 独立版本 | ETerm 版本 |
|------|----------|------------|
| 索引触发 | file watcher 轮询 | **事件驱动精确索引** |
| 延迟 | 秒级 | **实时** |
| 资源消耗 | 持续监听 | **按需触发** |
| 配置 | 需要安装/配置 | 零配置内置 |
| Web UI | 浏览器访问 | **内嵌沉浸式** |
| MCP | 需要配置 | 自动可用 |
| daemon | 需要运行 | **不需要** |
