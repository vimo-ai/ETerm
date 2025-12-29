# Vlaude Rust 重构计划

## 背景

### 当前架构
```
vlaude-daemon (Node.js/NestJS)     ← 独立进程，运行在 Mac
    ↓ Socket.IO
vlaude-server (Node.js/NestJS)     ← 运行在 NAS
    ↓ Socket.IO
iOS App / Web Client

VlaudeKit (Swift, ETerm 插件)      ← 伪装 daemon，功能不完整
```

### 问题
1. **技术栈分散**：Node.js daemon + Swift VlaudeKit，代码无法复用
2. **VlaudeKit 功能缺失**：只有状态上报和注入，缺少数据读取
3. **重复实现**：`ai-cli-session-collector` (Rust) 与 `vlaude-shared-core` (TS) 功能重叠
4. **部署复杂**：daemon 需要 Node.js 运行时

### 目标
1. **Rust 重写 daemon**：单二进制，无运行时依赖
2. **代码复用**：daemon 和 VlaudeKit 共享 100% 核心逻辑
3. **技术栈收敛**：Rust 作为核心，Swift 只做薄壳桥接

---

## 新架构

```
┌─────────────────────────────────────────────────────────────┐
│  vlaude-core (Rust Library)                                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                  │
│  │ session-reader  │  │ socket-client   │                  │
│  │ (数据读取层)     │  │ (通信层)         │                  │
│  │                 │  │                 │                  │
│  │ - list_projects │  │ - connect       │                  │
│  │ - list_sessions │  │ - emit/on       │                  │
│  │ - read_messages │  │ - reconnect     │                  │
│  │ - watch_files   │  │                 │                  │
│  └────────┬────────┘  └────────┬────────┘                  │
│           │                    │                           │
│           └──────────┬─────────┘                           │
│                      ▼                                     │
│           ┌─────────────────────┐                          │
│           │   daemon-logic      │                          │
│           │   (业务逻辑层)       │                          │
│           │                     │                          │
│           │ - register/online   │                          │
│           │ - session_available │                          │
│           │ - handle_requests   │                          │
│           │ - file_watching     │                          │
│           │ - eterm_bridge      │                          │
│           └─────────────────────┘                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
   ┌─────────────┐ ┌─────────────┐ ┌─────────────────┐
   │ vlaude-cli  │ │ libvlaude   │ │ sugarloaf-ffi   │
   │ (独立二进制) │ │ (C FFI)     │ │ (已有 FFI)       │
   └─────────────┘ └─────────────┘ └─────────────────┘
          │               │               │
          ▼               ▼               ▼
    命令行 daemon    其他语言集成     ETerm/VlaudeKit
```

---

## 模块设计

### 1. session-reader (基于 ai-cli-session-collector)

已有基础，需要扩展：

```rust
// 现有
pub fn list_sessions() -> Vec<SessionMeta>
pub fn parse_session(meta: &SessionMeta) -> ParseResult

// 需要新增
pub fn list_projects(path: &Path, limit: Option<usize>) -> Vec<ProjectInfo>
pub fn read_messages(session_path: &Path, limit: usize, offset: usize, order: Order) -> MessagesResult
pub fn watch_directory(path: &Path, callback: impl Fn(WatchEvent)) -> Watcher
pub fn find_latest_session(project_path: &Path, within_seconds: u64) -> Option<SessionMeta>
```

### 2. socket-client (新建)

Socket.IO 客户端封装：

```rust
pub struct SocketClient {
    url: String,
    namespace: String,
    socket: Option<SocketIO>,
}

impl SocketClient {
    pub fn new(url: &str, namespace: &str) -> Self
    pub async fn connect(&mut self) -> Result<()>
    pub fn disconnect(&mut self)
    pub fn emit(&self, event: &str, data: Value)
    pub fn emit_with_ack(&self, event: &str, data: Value) -> impl Future<Output = Value>
    pub fn on(&self, event: &str, callback: impl Fn(Value))
    pub fn is_connected(&self) -> bool
}
```

**技术选型**：
- `rust-socketio` - Socket.IO 客户端
- `tokio` - 异步运行时
- `serde_json` - JSON 序列化

### 3. daemon-logic (新建)

核心业务逻辑：

```rust
pub struct DaemonService {
    socket: SocketClient,
    session_reader: SessionReader,
    file_watcher: FileWatcher,

    // 状态
    path_cache: HashMap<String, String>,  // projectPath -> encodedDirName
    watched_sessions: HashMap<String, WatchHandle>,
    paused_sessions: HashSet<String>,

    // ETerm 状态
    eterm_online: bool,
    eterm_sessions: HashMap<String, String>,  // sessionId -> projectPath
}

impl DaemonService {
    // 生命周期
    pub async fn start(&mut self) -> Result<()>
    pub async fn stop(&mut self)

    // 上行事件 (Daemon → Server)
    pub fn register(&self)
    pub fn report_online(&self)
    pub fn report_offline(&self)
    pub fn report_session_available(&self, session_id: &str, project_path: &str)
    pub fn report_session_unavailable(&self, session_id: &str)
    pub fn notify_new_message(&self, session_id: &str, message: &Value)
    pub fn notify_metrics_update(&self, session_id: &str, metrics: &Metrics)

    // 下行事件处理 (Server → Daemon)
    fn handle_request_messages(&self, data: Value) -> Value
    fn handle_start_watching(&self, data: Value)
    fn handle_stop_watching(&self, data: Value)
    fn handle_inject_to_eterm(&self, data: Value)  // 转发给 ETerm
    fn handle_create_session(&self, data: Value)   // 转发给 ETerm

    // ETerm 相关
    pub fn eterm_online(&mut self)
    pub fn eterm_offline(&mut self)
    pub fn eterm_session_available(&mut self, session_id: &str, project_path: &str)
    pub fn eterm_session_unavailable(&mut self, session_id: &str)
}
```

### 4. FFI 层

```rust
// vlaude-ffi/src/lib.rs

/// 创建 daemon 实例
#[no_mangle]
pub extern "C" fn vlaude_create() -> *mut DaemonService

/// 连接到服务器
#[no_mangle]
pub extern "C" fn vlaude_connect(daemon: *mut DaemonService, url: *const c_char) -> bool

/// 断开连接
#[no_mangle]
pub extern "C" fn vlaude_disconnect(daemon: *mut DaemonService)

/// 上报 ETerm 上线
#[no_mangle]
pub extern "C" fn vlaude_eterm_online(daemon: *mut DaemonService)

/// 上报 ETerm 离线
#[no_mangle]
pub extern "C" fn vlaude_eterm_offline(daemon: *mut DaemonService)

/// 上报 session 可用
#[no_mangle]
pub extern "C" fn vlaude_session_available(
    daemon: *mut DaemonService,
    session_id: *const c_char,
    project_path: *const c_char,
)

/// 设置回调：收到注入请求
#[no_mangle]
pub extern "C" fn vlaude_set_inject_callback(
    daemon: *mut DaemonService,
    callback: extern "C" fn(session_id: *const c_char, text: *const c_char),
)

/// 释放实例
#[no_mangle]
pub extern "C" fn vlaude_destroy(daemon: *mut DaemonService)
```

---

## 实现计划

### Phase 1: 基础设施 (预计 2-3 天)

**目标**：搭建项目结构，实现 Socket.IO 客户端

1. 创建 `vlaude-core` workspace
   ```
   vlaude-core/
   ├── Cargo.toml (workspace)
   ├── session-reader/     # 基于 ai-cli-session-collector
   ├── socket-client/      # Socket.IO 客户端
   ├── daemon-logic/       # 业务逻辑
   ├── vlaude-cli/         # CLI 入口
   └── vlaude-ffi/         # FFI 导出
   ```

2. 实现 `socket-client`
   - 连接/断开/重连
   - emit/on 事件
   - 与 vlaude-server 联调

3. 验收标准
   - [ ] 能连接到 vlaude-server
   - [ ] 能 emit `daemon:register` 并收到响应
   - [ ] 断线能自动重连

### Phase 2: 数据读取 (预计 2-3 天)

**目标**：完善 session-reader，支持所有数据操作

1. 扩展 `ai-cli-session-collector`
   - `list_projects()` - 项目列表
   - `read_messages()` - 分页读取消息
   - `find_latest_session()` - 查找最新会话

2. 实现文件监听
   - 基于 `notify` crate
   - 支持项目列表/会话列表/会话详情三种模式

3. 验收标准
   - [ ] 能列出所有项目和会话
   - [ ] 能分页读取消息
   - [ ] 文件变化能触发回调

### Phase 3: 业务逻辑 (预计 3-4 天)

**目标**：实现完整的 daemon 业务逻辑

1. 实现 `daemon-logic`
   - 上行事件：register, online, session_available 等
   - 下行事件处理：request_messages, start_watching 等
   - 路径缓存管理
   - Metrics 计算

2. 实现 `vlaude-cli`
   - 命令行参数解析
   - 配置文件支持
   - 日志输出

3. 验收标准
   - [ ] CLI 能替代 Node.js daemon 运行
   - [ ] iOS 客户端能正常查看会话
   - [ ] 消息推送正常工作

### Phase 4: FFI 与 VlaudeKit (预计 2-3 天)

**目标**：导出 FFI，重构 VlaudeKit

1. 实现 `vlaude-ffi`
   - C ABI 导出
   - 回调机制
   - 内存管理

2. 集成到 sugarloaf-ffi
   - 添加依赖
   - 导出给 Swift

3. 重构 VlaudeKit
   - 删除 Swift Socket 逻辑
   - 调用 Rust FFI
   - 保留 UI 相关代码

4. 验收标准
   - [ ] VlaudeKit 能通过 FFI 连接服务器
   - [ ] 功能与 CLI daemon 一致
   - [ ] ETerm 注入/状态上报正常

### Phase 5: 测试与文档 (预计 1-2 天)

1. 单元测试
2. 集成测试
3. 性能测试
4. 文档更新

---

## 技术选型

| 组件 | 选型 | 说明 |
|------|------|------|
| 异步运行时 | tokio | 业界标准 |
| Socket.IO | rust-socketio | 活跃维护 |
| JSON | serde_json | 业界标准 |
| 文件监听 | notify | 跨平台 |
| 日志 | tracing | 结构化日志 |
| CLI | clap | 参数解析 |
| FFI | cbindgen | 自动生成头文件 |

---

## 风险与对策

| 风险 | 对策 |
|------|------|
| rust-socketio 兼容性 | 先验证与 NestJS 的兼容性 |
| FFI 内存管理 | 使用 Arc/Box，明确所有权 |
| 回调跨线程 | 使用 channel 通信 |
| 文件监听性能 | debounce 处理，避免频繁触发 |

---

## 跨对话指导

### 继续开发时

1. 先阅读本文档了解整体架构
2. 检查当前 Phase 进度
3. 查看 `vlaude-core/` 目录结构
4. 运行测试确认现有功能正常

### 代码位置

```
/Users/higuaifan/Desktop/vimo/ai-cli-session-collector  # 已有 session 解析
/Users/higuaifan/Desktop/hi/小工具/english/             # ETerm 主项目
/Users/higuaifan/Desktop/hi/小工具/claude/              # vlaude 相关
```

### 关键文件参考

- `vlaude-daemon/src/module/server-client/server-client.service.ts` - Socket 事件定义
- `vlaude-daemon/src/module/data-collector/data-collector.service.ts` - 数据采集逻辑
- `vlaude-server/src/module/daemon-gateway/daemon.gateway.ts` - Server 端协议

### 命名约定

- Rust crate: `snake_case`
- FFI 函数: `vlaude_` 前缀
- 事件名: `daemon:xxx` (上行), `server:xxx` (下行)

---

## 更新日志

| 日期 | 版本 | 说明 |
|------|------|------|
| 2025-12-28 | v1.0 | 初始计划 |
| 2025-12-28 | v1.1 | Phase 1 完成：workspace 结构、socket-client、session-reader、daemon-logic、CLI、FFI |

## Phase 1 完成情况

### 已完成
- [x] 创建 `vlaude-core` workspace 结构
- [x] 实现 `session-reader` 模块（基于 ai-cli-session-collector）
  - list_projects()
  - list_sessions()
  - read_messages()
  - find_latest_session()
  - FileWatcher
- [x] 实现 `socket-client` 模块
  - Socket.IO 客户端封装
  - 事件类型定义
  - 便捷方法（register, report_online 等）
- [x] 实现 `daemon-logic` 模块
  - DaemonService 核心服务
  - 事件处理器
  - ETerm 状态管理
- [x] 实现 `vlaude-cli`
  - 命令行入口
  - 参数解析
- [x] 实现 `vlaude-ffi`
  - C ABI 导出
  - 回调机制

### 产出物
```
vlaude-core/target/release/
├── vlaude           # CLI 二进制 (6MB)
├── libvlaude_ffi.a  # 静态库 (34MB)
└── libvlaude_ffi.dylib  # 动态库 (5MB)
```

### 待测试
- [x] 连接到 vlaude-server (2025-12-29 完成)
- [x] emit `daemon:register` 并收到响应
- [ ] 断线自动重连

## Phase 1.5: mTLS 支持 (2025-12-29)

### 已完成
- [x] TlsConfig 配置结构
- [x] CA 证书加载
- [x] P12 客户端证书加载 (mTLS)
- [x] CLI 参数支持 (--ca-cert, --client-cert, --p12-password, --insecure)
- [x] 成功连接 vlaude-server

### 已知问题及解决方案

#### rust_socketio 回调不触发
- **问题**：`on("connect")` 和 `emit_with_ack` 的回调不会被触发
- **原因**：rust_socketio 库的异步回调机制与预期不符
- **解决**：
  1. `connect()` 成功后直接设置 connected 状态，不依赖回调
  2. 暂用普通 `emit` 替代 `emit_with_ack`，后续改用监听响应事件

### 测试命令
```bash
CERTS_DIR="/Users/higuaifan/Desktop/hi/小工具/claude/packages/vlaude-server/certs"
./target/debug/vlaude \
  --ca-cert "$CERTS_DIR/ca.crt" \
  --client-cert "$CERTS_DIR/ios-client.p12" \
  --p12-password "vlaude123" \
  -l debug
```

---

## Phase 2: Daemon 功能验证 (2025-12-29 完成)

### 已完成
- [x] 功能对比 TypeScript daemon，补全缺失事件
- [x] Codex 代码审核，修复安全问题
  - 路径穿越风险：添加 `validate_path_component` 校验
  - 锁范围过大：改用 snapshot + 锁外 I/O
  - 删除事件后未从 map 移除：统一移除已删除会话
- [x] 10 个单元测试全部通过
- [x] session-reader-ffi 独立 crate 完成

### session-reader-ffi 产出物
```
vlaude-core/target/release/
├── libsession_reader_ffi.a      # 静态库 (19MB)
├── libsession_reader_ffi.dylib  # 动态库 (710KB)
└── session-reader-ffi/include/
    └── session_reader_ffi.h     # C 头文件
```

### 待验证
- [ ] Mobile App 端到端测试（目前显示加载中，需要进一步调试）

---

## Daemon vs VlaudeKit 架构差异

### 核心区别

| 功能 | Daemon (CLI) | VlaudeKit (ETerm 插件) |
|------|-------------|----------------------|
| session-reader | ✅ Rust 原生 | ✅ 通过 session-reader-ffi |
| Socket 通信 | ✅ Rust socket-client | ✅ Swift SocketService (ETermKit) |
| 文件监听 | ✅ watcher (轮询) | ❌ 不需要 (用 ClaudePlugin 事件驱动) |
| 运行方式 | 独立进程 | ETerm 插件进程 |

### 架构图
```
┌─────────────────────────────────────────────────────────────┐
│                    vlaude-core (Rust)                       │
├─────────────────────────────────────────────────────────────┤
│  session-reader ──┬──→ session-reader-ffi ──→ VlaudeKit     │
│        ↓          │                                         │
│  daemon-logic ────┴──→ vlaude-ffi ──→ vlaude-cli            │
│  (+ socket-client)                                          │
│  (+ watcher)                                                │
└─────────────────────────────────────────────────────────────┘
```

### VlaudeKit 不需要 watcher 的原因
- Daemon 用 file watcher 轮询检测新消息
- VlaudeKit 有 **ClaudePlugin 事件**，精确知道何时有新消息
- 事件驱动比轮询更高效、更精确

---

## Phase 3: VlaudeKit 集成 session-reader-ffi

### 目标
让 VlaudeKit 能读取 session 文件，响应 server 的数据请求。

### 集成方案
session-reader-ffi 归属 **VlaudeKit 插件**，不是 ETerm 主进程：

```
Plugins/VlaudeKit/
├── Package.swift              # 链接 session-reader-ffi
├── Sources/VlaudeKit/
│   ├── VlaudeClient.swift     # 已有：Socket 通信
│   └── SessionReader.swift    # 新增：Swift wrapper 调用 FFI
├── Libs/                       # 新增：存放 Rust 库
│   ├── libsession_reader_ffi.dylib
│   └── session_reader_ffi.h
└── Resources/
    └── manifest.json
```

### FFI 接口 (session_reader_ffi.h)
```c
// 创建/销毁
SRReader *sr_create(void);
void sr_destroy(SRReader *reader);

// 数据读取 (返回 JSON 字符串)
char *sr_list_projects(SRReader *reader, uint32_t limit);
char *sr_list_sessions(SRReader *reader, const char *project_path);
char *sr_read_messages(SRReader *reader, const char *session_path,
                       uint32_t limit, uint32_t offset, bool order_asc);
char *sr_find_latest_session(SRReader *reader, const char *project_path,
                             uint64_t within_seconds);

// 路径编解码
char *sr_encode_path(const char *path);
char *sr_decode_path(const char *encoded);

// 内存管理
void sr_free_string(char *s);
```

### 待完成任务
1. [ ] 创建 `Plugins/VlaudeKit/Libs/` 目录
2. [ ] 复制 session-reader-ffi 库文件和头文件
3. [ ] 修改 Package.swift 链接库
4. [ ] 创建 SessionReader.swift wrapper
5. [ ] 在 VlaudeClient 中集成数据读取

### 构建脚本
```bash
# 编译 session-reader-ffi
cd /Users/higuaifan/Desktop/hi/小工具/claude/vlaude-core
cargo build --release -p session-reader-ffi

# 复制到 VlaudeKit
cp target/release/libsession_reader_ffi.dylib \
   /Users/higuaifan/Desktop/hi/小工具/english/Plugins/VlaudeKit/Libs/
cp session-reader-ffi/include/session_reader_ffi.h \
   /Users/higuaifan/Desktop/hi/小工具/english/Plugins/VlaudeKit/Libs/
```

---

## 代码位置

```
/Users/higuaifan/Desktop/hi/小工具/claude/vlaude-core/
├── session-reader/       # 核心层 - 会话读取
├── session-reader-ffi/   # 轻量 FFI - 供 VlaudeKit 使用
├── socket-client/        # Socket 模块 - mTLS + Socket.IO
├── daemon-logic/         # 整合层 - 业务逻辑 + watcher
├── vlaude-cli/           # CLI daemon
└── vlaude-ffi/           # 完整 FFI - 供 CLI 使用

/Users/higuaifan/Desktop/hi/小工具/english/Plugins/VlaudeKit/
├── Sources/VlaudeKit/
│   ├── VlaudeClient.swift    # Socket 通信 (用 ETermKit SocketService)
│   └── SessionReader.swift   # 待实现：调用 session-reader-ffi
└── Libs/                      # 待创建：存放 Rust 库
```
