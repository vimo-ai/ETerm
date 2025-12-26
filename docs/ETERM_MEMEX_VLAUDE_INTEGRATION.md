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
│              │  libmemex.dylib │   │ libvlaude.dylib │          │
│              │                 │   │                 │          │
│              │  - 索引会话     │   │  - 直连 server  │          │
│              │  - 搜索         │   │  - 状态同步     │          │
│              │  - MCP 能力     │   │  - 远程注入     │          │
│              └─────────────────┘   └─────────────────┘          │
│                       │                     │                   │
│                       ▼                     ▼                   │
│              ┌─────────────────┐   ┌─────────────────┐          │
│              │  ~/memex-data/  │   │  vlaude-server  │          │
│              │  (本地存储)     │   │  (远端)         │          │
│              └─────────────────┘   └─────────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

## 事件协议

### ClaudePlugin 广播的事件

```swift
// 已有事件 (ETerm/ETerm/Features/Plugins/Claude/)
struct ClaudeEvents {

    struct SessionStart: Event {
        let sessionId: String
        let terminalId: Int
        let projectPath: String
    }

    struct ResponseComplete: Event {
        let sessionId: String
        let terminalId: Int
        let projectPath: String
    }

    struct SessionEnd: Event {
        let sessionId: String
        let terminalId: Int
    }
}
```

### 扩展事件数据

MemexKit 需要的额外信息:

```swift
extension ClaudeEvents {
    struct SessionUpdate: Event {
        let sessionId: String
        let terminalId: Int
        let projectPath: String
        let jsonlPath: String      // JSONL 文件路径，直接索引
        let encodedDirName: String // Claude 编码目录名
    }
}
```

### 事件传递方式

**方案: SDK 事件系统**

```json
// MemexKit/manifest.json
{
    "subscribes": ["claude.sessionStart", "claude.responseComplete", "claude.sessionEnd"]
}

// VlaudeKit/manifest.json
{
    "subscribes": ["claude.sessionStart", "claude.responseComplete", "claude.sessionEnd"]
}
```

ClaudePlugin 通过 HostBridge 发射事件:

```swift
// ClaudePlugin
host.emit("claude.responseComplete", payload: [
    "sessionId": sessionId,
    "terminalId": terminalId,
    "projectPath": projectPath,
    "jsonlPath": jsonlPath
])
```

SDK 插件通过 handleEvent 接收:

```swift
// MemexKit
public func handleEvent(_ eventName: String, payload: [String: Any]) {
    switch eventName {
    case "claude.responseComplete":
        let jsonlPath = payload["jsonlPath"] as? String
        memexBridge.indexSession(jsonlPath)
    // ...
    }
}
```

## MemexKit 设计

### Rust Core (libmemex.dylib)

```
memex-core/
├── 依赖 ai-cli-session-collector
├── 不包含:
│   ├── file watcher (ETerm 不需要)
│   ├── HTTP server (ETerm 不需要)
│   └── 定时任务 (ETerm 不需要)
└── 包含:
    ├── SQLite + FTS5
    ├── Ollama embedding
    ├── LanceDB 向量
    └── 搜索引擎
```

### FFI 接口

```rust
// memex-core/src/ffi.rs

#[no_mangle]
pub extern "C" fn memex_init(data_dir: *const c_char) -> *mut MemexHandle;

#[no_mangle]
pub extern "C" fn memex_index_session(
    handle: *mut MemexHandle,
    jsonl_path: *const c_char,
    project_path: *const c_char,
) -> i32;

#[no_mangle]
pub extern "C" fn memex_search(
    handle: *mut MemexHandle,
    query: *const c_char,
    mode: *const c_char,  // "fts" | "vector" | "hybrid"
    limit: u32,
) -> *mut SearchResults;

#[no_mangle]
pub extern "C" fn memex_get_session(
    handle: *mut MemexHandle,
    session_id: *const c_char,
) -> *mut SessionDetail;

#[no_mangle]
pub extern "C" fn memex_free(handle: *mut MemexHandle);
```

### Swift SDK 插件

```
Plugins/MemexKit/
├── Package.swift
├── Sources/MemexKit/
│   ├── MemexPlugin.swift       # 插件入口
│   ├── MemexBridge.swift       # FFI 桥接
│   ├── MemexBridge.h           # C Header
│   └── Views/
│       └── MemexSearchView.swift
├── Resources/
│   ├── manifest.json
│   └── Libs/
│       └── libmemex.dylib
└── build.sh
```

### manifest.json

```json
{
    "id": "com.eterm.memex",
    "name": "Memex",
    "version": "1.0.0",
    "entry": "MemexPlugin",
    "subscribes": [
        "claude.sessionStart",
        "claude.responseComplete",
        "claude.sessionEnd"
    ],
    "sidebarTabs": [
        {
            "id": "memex-search",
            "title": "搜索历史",
            "icon": "magnifyingglass"
        }
    ],
    "commands": [
        {
            "id": "memex.search",
            "title": "搜索会话历史",
            "shortcut": "cmd+shift+f"
        }
    ]
}
```

## VlaudeKit 设计

### Rust Core (libvlaude.dylib)

```
vlaude-core/
├── 依赖 ai-cli-session-collector
├── WebSocket 客户端 (tokio-tungstenite)
├── 直连 vlaude-server
└── 功能:
    ├── connect(server_url)
    ├── report_session_available(session_id, terminal_id, project_path)
    ├── report_session_unavailable(session_id)
    └── on_inject(callback)  // 接收注入请求
```

### FFI 接口

```rust
// vlaude-core/src/ffi.rs

#[no_mangle]
pub extern "C" fn vlaude_init(server_url: *const c_char) -> *mut VlaudeHandle;

#[no_mangle]
pub extern "C" fn vlaude_connect(handle: *mut VlaudeHandle) -> i32;

#[no_mangle]
pub extern "C" fn vlaude_report_available(
    handle: *mut VlaudeHandle,
    session_id: *const c_char,
    terminal_id: i32,
    project_path: *const c_char,
) -> i32;

#[no_mangle]
pub extern "C" fn vlaude_report_unavailable(
    handle: *mut VlaudeHandle,
    session_id: *const c_char,
) -> i32;

// 回调注册
pub type InjectCallback = extern "C" fn(
    session_id: *const c_char,
    terminal_id: i32,
    text: *const c_char,
);

#[no_mangle]
pub extern "C" fn vlaude_set_inject_callback(
    handle: *mut VlaudeHandle,
    callback: InjectCallback,
);

#[no_mangle]
pub extern "C" fn vlaude_disconnect(handle: *mut VlaudeHandle);

#[no_mangle]
pub extern "C" fn vlaude_free(handle: *mut VlaudeHandle);
```

### Swift SDK 插件

```
Plugins/VlaudeKit/
├── Package.swift
├── Sources/VlaudeKit/
│   ├── VlaudePlugin.swift      # 插件入口
│   ├── VlaudeBridge.swift      # FFI 桥接
│   └── VlaudeBridge.h          # C Header
├── Resources/
│   ├── manifest.json
│   └── Libs/
│       └── libvlaude.dylib
└── build.sh
```

### manifest.json

```json
{
    "id": "com.eterm.vlaude",
    "name": "Vlaude Remote",
    "version": "1.0.0",
    "entry": "VlaudePlugin",
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

### Phase 1: 事件协议

1. 确认 ClaudePlugin 现有事件
2. 扩展事件 payload (添加 jsonlPath)
3. 确保 SDK 插件能订阅和接收

### Phase 2: MemexKit

1. memex-rs 添加 FFI 层
2. 编译为 dylib (去掉 watcher/http)
3. 创建 MemexKit SDK 插件
4. 实现事件订阅 + 索引触发
5. 侧边栏搜索 UI
6. MCP 集成

### Phase 3: VlaudeKit

1. 创建 vlaude-core (Rust)
2. 实现 WebSocket 直连 server
3. 创建 VlaudeKit SDK 插件
4. 实现事件订阅 + 状态上报
5. 实现注入回调 + 写入终端
6. Tab Slot (需要 slot 支持)

### Phase 4: 清理

1. 删除内嵌 VlaudePlugin
2. 更新文档
3. daemon 标记为可选 (非 ETerm 用户)

## 相关文件

### 现有代码

- ClaudePlugin: `ETerm/ETerm/Features/Plugins/Claude/`
- VlaudePlugin: `ETerm/ETerm/Features/Plugins/Vlaude/`
- SDK 插件示例: `Plugins/TranslationKit/`

### 外部依赖

- ai-cli-session-collector: `/Users/higuaifan/Desktop/vimo/ai-cli-session-collector`
- memex-rs: `/Users/higuaifan/Desktop/vimo/memex/memex-rs`
- vlaude-daemon: `/Users/higuaifan/Desktop/hi/小工具/claude/packages/vlaude-daemon`
- vlaude-server: `/Users/higuaifan/Desktop/hi/小工具/claude/packages/vlaude-server`

## 对比: ETerm vs 独立版本

| 能力 | 独立版本 | ETerm 版本 |
|------|----------|------------|
| 索引触发 | file watcher 轮询 | ClaudePlugin 事件驱动 |
| 延迟 | 秒级 | 实时 |
| 资源消耗 | 持续监听 | 按需触发 |
| 配置 | 需要安装/配置 | 零配置内置 |
| 进程 | 独立进程 | 插件 dylib |
| daemon | 需要 | 不需要 |
