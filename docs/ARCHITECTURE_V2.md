# ETerm + Memex + Vlaude 架构设计 V2

## 1. 背景

我们有三个独立的开源项目，需要能独立运行，也能组合使用：

| 项目 | 定位 | 核心功能 |
|------|------|----------|
| **ETerm** | macOS 终端模拟器 | 终端渲染、插件系统、Claude 会话检测 |
| **Memex** | Claude 会话搜索引擎 | 全文搜索 (FTS5)、向量搜索 (LanceDB)、MCP 工具 |
| **Vlaude** | Claude 远程控制系统 | iOS 查看会话、远程消息注入 |

### 1.1 使用场景

| 场景 | ETerm | Memex | Vlaude | 用户需求 |
|------|-------|-------|--------|----------|
| A | ✅ | ❌ | ❌ | 只想要个好终端 |
| B | ❌ | ✅ | ❌ | 只想搜索 Claude 历史 |
| C | ❌ | ❌ | ✅ | 用其他终端，想 iOS 查看 |
| D | ✅ | ✅ | ❌ | 本地增强，不需要远程 |
| E | ✅ | ❌ | ✅ | 远程控制，不需要搜索 |
| F | ❌ | ✅ | ✅ | 用其他终端，要搜索+远程 |
| G | ✅ | ✅ | ✅ | 全家桶 |

### 1.2 核心问题

**数据重叠**：Memex 和 Vlaude 都需要 Claude session 数据

| 功能 | Memex | Vlaude daemon | Vlaude server |
|------|-------|---------------|---------------|
| 扫描 ~/.claude/ | ✅ | ✅ | ❌ |
| 解析 JSONL | ✅ | ✅ | ❌ |
| 存储 sessions | ✅ | ❌ | ✅ |

**问题**：
1. 独立运行时，各自采集存储是合理的
2. 全家桶场景，两份扫描 + 两份存储不合理
3. 需要设计让组件独立可用，又能共存时高效协作

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         数据源                                   │
│                  ~/.claude/projects/*.jsonl                      │
│                     (Claude CLI 产生)                            │
│                                                                  │
│              这是唯一的数据源头，永不丢失                          │
└─────────────────────────────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       ▼
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│ Memex daemon │        │Vlaude daemon │        │    ETerm     │
│              │        │              │        │   插件系统   │
│ 扫描 + 写 DB │        │ 扫描 + 写 DB │        │ MemexKit     │
│ + 向量化     │        │              │        │ VlaudeKit    │
└──────────────┘        └──────────────┘        └──────────────┘
        │                       │                       │
        └───────────────────────┼───────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      claude-session-db                           │
│                     (共享 libSQL 数据库)                         │
│                                                                  │
│  部署模式：                                                       │
│  • 本地: SQLite 文件                                             │
│  • 远程: libSQL 服务 (Docker)                                    │
│  • 云端: Turso                                                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
         ┌──────────┐    ┌──────────┐    ┌──────────┐
         │  Memex   │    │  Vlaude  │    │  其他    │
         │  搜索    │    │  Server  │    │  应用    │
         │ +LanceDB │    │ +iOS App │    │          │
         └──────────┘    └──────────┘    └──────────┘
```

### 2.2 核心设计原则

1. **统一数据库**：所有组件共享一个 libSQL 数据库，配置决定本地/远程
2. **Writer 协调**：通过 DB 注册表协调，只有一个组件负责写入
3. **共享库封装**：协调逻辑、读写逻辑封装在共享 Rust 库中
4. **零配置**：组件启动自动协调，用户无需手动配置
5. **数据安全**：JSONL 文件是数据源头，DB 只是索引，可随时重建

---

## 3. 共享库设计

### 3.1 库依赖关系

```
┌─────────────────────────────────────────────────────────────────┐
│              ai-cli-session-collector (已有)                     │
│                                                                  │
│  • 解析 ~/.claude/projects/*.jsonl                              │
│  • 输出结构化数据: Project, Session, Message                     │
│  • 纯解析库，无 IO、无网络                                        │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    claude-session-db (新建)                      │
│                                                                  │
│  • 依赖 ai-cli-session-collector                                │
│  • 依赖 libsql / rusqlite                                       │
│  • 提供: 连接、协调、读写、搜索                                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                ┌───────────────┼───────────────┬───────────────┐
                ▼               ▼               ▼               ▼
          Memex daemon    Vlaude daemon    MemexKit        VlaudeKit
             (Rust)          (Rust)      (Swift FFI)    (Swift FFI)
```

### 3.2 Rust Feature Flags

```toml
# claude-session-db/Cargo.toml
[features]
default = ["writer", "reader", "search", "coordination"]
writer = []           # 写入能力
reader = []           # 只读能力
search = ["fts"]      # 搜索能力
fts = []              # FTS5 支持
coordination = []     # Writer 协调逻辑

# 不同组件按需引用
# Memex: 全部 features
# Vlaude daemon: writer, reader, coordination
# Vlaude server: reader, search
```

### 3.3 claude-session-db API 设计

```rust
// ============================================================
// 连接
// ============================================================

/// 数据库连接配置
pub struct DbConfig {
    /// 连接 URL
    /// - 本地: "sqlite:///path/to/db.sqlite"
    /// - 远程: "libsql://host:port"
    /// - Turso: "libsql://xxx.turso.io?authToken=xxx"
    pub url: String,
}

/// 数据库连接
pub struct SessionDB { /* ... */ }

impl SessionDB {
    /// 连接数据库，自动创建表
    pub async fn connect(config: DbConfig) -> Result<Self>;
}

// ============================================================
// Writer 协调
// ============================================================

/// 组件类型
#[derive(Clone, Copy)]
pub enum WriterType {
    MemexDaemon,    // 优先级 1
    VlaudeDaemon,   // 优先级 1
    MemexKit,       // 优先级 2 (ETerm 插件优先)
    VlaudeKit,      // 优先级 2
}

/// 角色
#[derive(Clone, Copy, PartialEq)]
pub enum Role {
    Writer,  // 负责写入
    Reader,  // 只读
}

/// Writer 健康状态
pub enum WriterHealth {
    Alive,      // 心跳正常
    Timeout,    // 心跳超时
    Released,   // 主动释放
}

impl SessionDB {
    /// 注册为 Writer，返回实际角色
    pub async fn register_writer(&self, writer_type: WriterType) -> Result<Role>;

    /// 更新心跳 (Writer 定期调用)
    pub async fn heartbeat(&self) -> Result<()>;

    /// 释放 Writer (正常退出时调用)
    pub async fn release_writer(&self) -> Result<()>;

    /// 检查 Writer 健康状态 (Reader 调用)
    pub async fn check_writer_health(&self) -> Result<WriterHealth>;

    /// 尝试接管 Writer (Reader 在检测到超时后调用)
    pub async fn try_takeover(&self) -> Result<bool>;

    /// 监听角色变化
    pub fn watch_role_change(&self) -> tokio::sync::watch::Receiver<Role>;
}

// ============================================================
// 数据写入 (Writer 专用)
// ============================================================

impl SessionDB {
    /// 写入/更新 Project
    pub async fn upsert_project(&self, project: &Project) -> Result<()>;

    /// 写入/更新 Session
    pub async fn upsert_session(&self, session: &Session) -> Result<()>;

    /// 批量写入 Messages (自动去重)
    pub async fn insert_messages(&self, messages: &[Message]) -> Result<usize>;

    /// 获取 session 的扫描检查点 (用于增量扫描)
    pub async fn get_scan_checkpoint(&self, session_id: &str) -> Result<Option<i64>>;

    /// 更新 session 的最后消息时间
    pub async fn update_session_last_message(&self, session_id: &str, timestamp: i64) -> Result<()>;
}

// ============================================================
// 数据读取 (Writer 和 Reader 都可用)
// ============================================================

impl SessionDB {
    /// 获取所有 Projects
    pub async fn list_projects(&self) -> Result<Vec<Project>>;

    /// 获取 Project 的 Sessions
    pub async fn list_sessions(&self, project_id: i64) -> Result<Vec<Session>>;

    /// 获取 Session 的 Messages
    pub async fn list_messages(
        &self,
        session_id: &str,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<Message>>;

    /// 全文搜索
    pub async fn search_fts(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>>;
}
```

### 3.4 数据库 Schema

```sql
-- Projects 表
CREATE TABLE projects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Sessions 表
CREATE TABLE sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL UNIQUE,
    project_id INTEGER NOT NULL REFERENCES projects(id),
    message_count INTEGER NOT NULL DEFAULT 0,
    last_message_at INTEGER,  -- 用于增量扫描的检查点
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Messages 表
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    uuid TEXT NOT NULL UNIQUE,  -- Claude 消息的唯一 ID，用于去重
    role TEXT NOT NULL,         -- "human" | "assistant"
    content TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    sequence INTEGER NOT NULL,

    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

-- 全文搜索虚拟表 (带触发器自动维护)
CREATE VIRTUAL TABLE messages_fts USING fts5(
    content,
    content='messages',
    content_rowid='id'
);

-- FTS 触发器
CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
END;

CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.id, old.content);
END;

CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.id, old.content);
    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
END;

-- Writer 注册表 (协调用)
CREATE TABLE writer_registry (
    id INTEGER PRIMARY KEY CHECK (id = 1),  -- 只能有一行
    writer_type TEXT NOT NULL,
    writer_id TEXT NOT NULL,      -- UUID，每次启动生成新的
    priority INTEGER NOT NULL,
    heartbeat INTEGER NOT NULL,   -- 毫秒时间戳
    registered_at INTEGER NOT NULL
);

-- 索引
CREATE INDEX idx_sessions_project ON sessions(project_id);
CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);
CREATE INDEX idx_sessions_last_message ON sessions(last_message_at);
CREATE INDEX idx_messages_session ON messages(session_id);
CREATE INDEX idx_messages_timestamp ON messages(timestamp);
```

---

## 4. Writer 协调机制

### 4.1 协调流程

```
┌─────────────────────────────────────────────────────────────────┐
│                      组件启动流程                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │ SELECT * FROM    │
                    │ writer_registry  │
                    └──────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          表为空         有记录但            有记录且
              │         心跳超时(>30s)       心跳有效
              │               │               │
              ▼               ▼               ▼
         INSERT 注册     UPDATE 抢占     比较优先级
         成为 Writer     成为 Writer          │
                                    ┌────────┴────────┐
                                    ▼                 ▼
                              我优先级更高       我优先级 ≤
                                    │                 │
                                    ▼                 ▼
                              UPDATE 抢占       成为 Reader
                              成为 Writer
```

### 4.2 原子抢占 SQL

防止多个组件同时抢占导致的竞态问题：

```sql
-- 尝试注册 Writer（原子操作）
INSERT INTO writer_registry (id, writer_type, writer_id, priority, heartbeat, registered_at)
VALUES (1, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    writer_type = excluded.writer_type,
    writer_id = excluded.writer_id,
    priority = excluded.priority,
    heartbeat = excluded.heartbeat,
    registered_at = excluded.registered_at
WHERE
    -- 条件1: 心跳超时 (>30s)
    (strftime('%s', 'now') * 1000 - writer_registry.heartbeat) > 30000
    -- 条件2: 或者我优先级更高
    OR excluded.priority > writer_registry.priority;

-- 检查是否成功 (通过 changes() 判断)
-- changes() == 1 → 成功成为 Writer
-- changes() == 0 → 失败，成为 Reader
```

### 4.3 心跳参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 心跳周期 | 10s | Writer 更新 heartbeat 的间隔 |
| 超时阈值 | 30s | 多久没心跳认为可能挂了 |
| 确认次数 | 3 次 | 连续多少次超时才确认（防止网络抖动） |
| 最快接管时间 | ~0s | Writer 正常退出（DELETE 后立即接管）|
| 最慢接管时间 | ~50s | Writer 崩溃（等待 3 次超时检测）|

### 4.4 优先级规则

| 组件 | 优先级 | 说明 |
|------|--------|------|
| MemexKit | 2 | ETerm 插件，事件驱动，更实时 |
| VlaudeKit | 2 | ETerm 插件，事件驱动，更实时 |
| Memex daemon | 1 | 文件扫描，有延迟 |
| Vlaude daemon | 1 | 文件扫描，有延迟 |

**同优先级**：先到先得，不抢占

### 4.5 组件状态机

```
                    ┌──────────┐
                    │  启动    │
                    └────┬─────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ 尝试注册 Writer     │
              │ (原子 SQL)          │
              └──────────┬──────────┘
                         │
           ┌─────────────┴─────────────┐
           ▼                           ▼
    ┌──────────────┐           ┌──────────────┐
    │   Writer     │           │   Reader     │
    │              │           │              │
    │ • 扫描/监听  │           │ • 只读 DB    │
    │ • 写入 DB    │           │ • 监控心跳   │
    │ • 更新心跳   │           │ • 等待接管   │
    └──────┬───────┘           └──────┬───────┘
           │                          │
           │ 退出                      │ 检测到 Writer 挂了
           ▼                          │ (连续 3 次超时)
    ┌──────────────┐                  │
    │ 释放 Writer  │                  │
    │ (DELETE)     │                  │
    └──────────────┘                  │
                                      ▼
                               ┌──────────────┐
                               │ 尝试接管     │
                               │ (原子 UPDATE)│
                               └──────┬───────┘
                                      │
                                      ▼
                               ┌──────────────┐
                               │ 成为 Writer  │
                               └──────────────┘
```

### 4.6 Reader 监控循环

```rust
/// Reader 模式下的监控循环
async fn reader_monitor_loop(&self) {
    let mut consecutive_failures = 0;

    loop {
        tokio::time::sleep(Duration::from_secs(10)).await;

        match self.db.check_writer_health().await {
            Ok(WriterHealth::Alive) => {
                consecutive_failures = 0;
            }
            Ok(WriterHealth::Timeout) => {
                consecutive_failures += 1;

                if consecutive_failures >= 3 {
                    // 尝试接管
                    if self.db.try_takeover().await.unwrap_or(false) {
                        // 成功接管，切换为 Writer 模式
                        self.role_tx.send(Role::Writer).ok();
                        self.start_writer_mode().await;
                        return;
                    }
                    // 接管失败（被别人抢先了），继续当 Reader
                    consecutive_failures = 0;
                }
            }
            Ok(WriterHealth::Released) => {
                // Writer 主动释放了，直接抢占
                if self.db.try_takeover().await.unwrap_or(false) {
                    self.role_tx.send(Role::Writer).ok();
                    self.start_writer_mode().await;
                    return;
                }
            }
            Err(_) => {
                // DB 访问错误，重试
            }
        }
    }
}
```

### 4.7 场景演示：Writer 切换

```
T0: Memex daemon 启动
    → INSERT writer_registry，成为 Writer
    → 开始扫描文件，写入 DB
    → 启动心跳循环：每 10s 更新 heartbeat

T1: Vlaude daemon 启动
    → 查询 writer_registry，发现 Memex 是 Writer
    → 优先级相同（都是 1），不抢占
    → 成为 Reader，只读 DB
    → 启动监控循环：每 10s 检查 Writer 心跳

T2: Memex daemon 退出（正常或崩溃）
    → 正常退出：DELETE writer_registry
    → 崩溃：心跳停止更新

T3: Vlaude daemon 检测到异常
    → 第 1 次检查：heartbeat 超过 30s 未更新，标记可疑
    → 第 2 次检查：仍然超时，标记可疑
    → 第 3 次检查：连续 3 次超时，确认 Writer 挂了

T4: Vlaude daemon 接管
    → UPDATE writer_registry，成为新 Writer
    → 开始扫描文件，写入 DB
    → 启动心跳循环
```

---

## 5. 数据安全机制

### 5.1 核心保障

**JSONL 文件是数据源头，DB 只是索引，可随时重建**

```
数据流:

Claude CLI → 写入 JSONL 文件 → Writer 扫描 → 写入 DB
                  ↑
                  │
              持久化在磁盘上
              与 Writer 状态无关
              永不丢失
```

### 5.2 Writer 切换期间的数据安全

| 阶段 | DB 状态 | iOS 看到的 | JSONL 文件 |
|------|---------|-----------|------------|
| 正常运行 | 实时更新 | 实时 | 完整 |
| Writer 挂了 | 停止更新 | 旧数据 | 继续写入 |
| 心跳确认中 | 停止更新 | 旧数据 | 继续写入 |
| 新 Writer 接管 | 补齐数据 | 恢复实时 | 完整 |

**损失的是实时性（最多 30-50s 延迟），不是数据完整性**

### 5.3 增量扫描策略

使用 `last_message_at` 时间戳 + UUID 去重：

```rust
/// 扫描单个 session
async fn scan_session(&self, session_id: &str, jsonl_path: &Path) -> Result<()> {
    // 1. 获取扫描检查点
    let checkpoint = self.db.get_scan_checkpoint(session_id).await?;

    // 2. 解析 JSONL
    let all_messages = ai_cli_session_collector::parse_jsonl(jsonl_path)?;

    // 3. 过滤出需要处理的消息
    let messages_to_process: Vec<_> = match checkpoint {
        Some(last_ts) => {
            // 增量扫描：回退 60s 作为安全边界
            let cutoff = last_ts.saturating_sub(60_000);
            all_messages.into_iter()
                .filter(|m| m.timestamp > cutoff)
                .collect()
        }
        None => {
            // 首次见到这个 session，全量扫描
            all_messages
        }
    };

    if messages_to_process.is_empty() {
        return Ok(());
    }

    // 4. 写入 DB（自动去重）
    self.db.insert_messages(&messages_to_process).await?;

    // 5. 更新检查点
    if let Some(last) = messages_to_process.last() {
        self.db.update_session_last_message(session_id, last.timestamp).await?;
    }

    Ok(())
}
```

### 5.4 去重机制

```sql
-- 写入时自动去重
INSERT INTO messages (uuid, session_id, content, timestamp, ...)
VALUES (?, ?, ?, ?, ...)
ON CONFLICT(uuid) DO NOTHING;  -- 已存在就跳过
```

新 Writer 接管后重新扫描，即使扫到已经写入的消息，也会被 `ON CONFLICT DO NOTHING` 跳过。

### 5.5 三种启动场景

| 场景 | DB 状态 | JSONL 状态 | 处理策略 |
|------|---------|-----------|----------|
| **首次启动** | 空 | 有历史数据 | 全量扫描导入 |
| **正常重启** | 有数据，较新 | 可能有少量新增 | 增量扫描 |
| **长时间停止后重启** | 有数据，但旧 | 有大量新增 | 大量增量扫描 |

**统一处理逻辑**：

```
1. 扫描 ~/.claude/projects/ 目录

2. 对于每个 session:
   - 查询 DB 的 last_message_at
   - 有记录 → 增量扫描（从 last_message_at - 60s 开始）
   - 无记录 → 全量扫描
   - UUID 去重兜底
```

---

## 6. 组件职责

### 6.1 各组件在不同模式下的行为

| 组件 | Writer 模式 | Reader 模式 |
|------|-------------|-------------|
| **Memex daemon** | 扫描 JSONL → 写 DB → 向量化 | 只读 DB → 向量化 |
| **Vlaude daemon** | 扫描 JSONL → 写 DB | 只读 DB |
| **MemexKit** | 监听 ETerm 事件 → 写 DB | 只做向量化触发 |
| **VlaudeKit** | 监听 ETerm 事件 → 写 DB → 推送状态 | 只推送实时状态 |

### 6.2 向量化处理

向量化是 Memex 的独占能力，存储在本地 LanceDB：

```
┌─────────────────────────────────────────────────────────────────┐
│                        Memex                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│  │ 读取 DB      │ -> │ Embedding    │ -> │ LanceDB      │       │
│  │ (messages)   │    │ (本地模型)   │    │ (向量存储)   │       │
│  └──────────────┘    └──────────────┘    └──────────────┘       │
│                                                                  │
│  向量搜索只在 Mac 本地可用                                        │
│  iOS 通过 Vlaude 只能用 FTS 基础搜索                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 6.3 VlaudeKit 实时状态

VlaudeKit 除了可能作为 Writer 写入 DB，还负责推送实时状态：

```
┌─────────────────────────────────────────────────────────────────┐
│                      VlaudeKit                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  推送到 Vlaude Server 的实时状态：                               │
│  • inEterm: 哪些 session 在 ETerm 中打开                        │
│  • activeSession: 当前活跃的 session                            │
│  • 消息注入响应                                                  │
│                                                                  │
│  这些状态不存 DB，通过 WebSocket 实时推送                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 部署方案

### 7.1 场景部署矩阵

| 场景 | 安装组件 | DB 部署 | Writer |
|------|----------|---------|--------|
| A (只 ETerm) | ETerm | 无 | 无 |
| B (只 Memex) | Memex | 内嵌 SQLite | Memex daemon |
| C (只 Vlaude) | Vlaude 全套 | libSQL (NAS) | Vlaude daemon |
| D (ETerm+Memex) | ETerm + Memex | 内嵌 SQLite | MemexKit 优先 |
| E (ETerm+Vlaude) | ETerm + Vlaude | libSQL (NAS) | VlaudeKit 优先 |
| F (Memex+Vlaude) | Memex + Vlaude | 共享 libSQL | 抢锁决定 |
| G (全家桶) | 全部 | 共享 libSQL | ETerm 插件优先 |

### 7.2 Docker Compose (场景 C/E/F/G)

```yaml
# docker-compose.yml
version: '3.8'

services:
  # 共享数据库
  session-db:
    image: ghcr.io/tursodatabase/libsql-server:latest
    volumes:
      - ./data/libsql:/var/lib/sqld
    ports:
      - "8080:8080"
    restart: unless-stopped

  # Vlaude Server
  vlaude-server:
    image: your-registry/vlaude-server:latest
    environment:
      - DB_URL=libsql://session-db:8080
    ports:
      - "3000:3000"
    depends_on:
      - session-db
    restart: unless-stopped

  # Vlaude Daemon (可选，如果不用 ETerm)
  vlaude-daemon:
    image: your-registry/vlaude-daemon:latest
    environment:
      - DB_URL=libsql://session-db:8080
      - CLAUDE_DIR=/claude
    volumes:
      - ~/.claude:/claude:ro
    depends_on:
      - session-db
    restart: unless-stopped
```

### 7.3 本地开发 (场景 B/D)

```bash
# Memex 独立运行，使用本地 SQLite
export DB_URL="sqlite:///Users/xxx/.memex/session.db"
memex daemon start
```

---

## 8. 工作计划

### Phase 1: 共享库开发

| 任务 | 描述 | 产出 |
|------|------|------|
| 1.1 | 创建 claude-session-db crate | Rust 库 |
| 1.2 | 实现 DB schema 和迁移 | SQL + 代码 |
| 1.3 | 实现 Writer 协调逻辑（原子抢占、心跳、接管） | register/heartbeat/release/takeover |
| 1.4 | 实现数据读写 API（含增量扫描） | upsert/insert/list/search |
| 1.5 | 单元测试 + 集成测试 | 测试用例 |

### Phase 2: 组件适配

| 任务 | 描述 | 改动 |
|------|------|------|
| 2.1 | Memex daemon 使用共享库 | 替换现有 DB 代码 |
| 2.2 | Vlaude daemon 使用共享库 | 替换现有扫描代码 |
| 2.3 | MemexKit 使用共享库 (FFI) | Swift 绑定 |
| 2.4 | VlaudeKit 使用共享库 (FFI) | Swift 绑定 |

### Phase 3: 部署优化

| 任务 | 描述 | 产出 |
|------|------|------|
| 3.1 | Docker Compose 模板 | 多场景配置 |
| 3.2 | 一键部署脚本 | install.sh |
| 3.3 | 配置文档 | docs |

### Phase 4: 测试验证

| 任务 | 描述 |
|------|------|
| 4.1 | 场景 A-G 全流程测试 |
| 4.2 | Writer 切换测试（正常退出、崩溃、网络抖动） |
| 4.3 | 数据完整性测试（停机期间数据不丢失） |
| 4.4 | 性能测试 (10W+ 数据启动扫描) |

---

## 9. 风险和待定项

### 9.1 已知风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| libSQL 稳定性 | 数据丢失 | JSONL 是源头，可重建；定期备份 |
| Writer 切换延迟 | 30-50s 数据延迟 | ETerm 场景可缩短；数据不丢失 |
| FFI 复杂度 | 开发效率 | 先完成 Rust 组件，再做 Swift 绑定 |
| 网络抖动误判 | 频繁切换 | 连续 3 次超时才接管 |

### 9.2 已确定项

| 问题 | 决策 | 理由 |
|------|------|------|
| 心跳超时时间 | 30s | 平衡实时性和稳定性 |
| 确认次数 | 3 次 | 防止网络抖动误判 |
| iOS 向量搜索 | V1 不支持 | 向量计算必须本地 |
| 历史数据迁移 | 启动时自动扫描 | 增量 + 去重 |

---

## 10. 附录

### 10.1 相关文档

- [ETerm 插件系统设计](./PLUGIN_SYSTEM.md)
- [Memex 搜索引擎设计](./MEMEX_DESIGN.md)
- [Vlaude 远程控制设计](./VLAUDE_DESIGN.md)

### 10.2 术语表

| 术语 | 说明 |
|------|------|
| Writer | 负责扫描 JSONL 并写入数据库的组件 |
| Reader | 只读数据库的组件，不负责扫描写入 |
| 心跳 | Writer 定期更新的时间戳，用于存活检测 |
| 抢占 | 高优先级组件取代低优先级 Writer |
| 接管 | Reader 在检测到 Writer 挂掉后升级为 Writer |
| 检查点 | session 的 last_message_at，用于增量扫描 |
| 去重 | 基于 message UUID 的写入去重机制 |

---

## 11. 实现状态

### 11.1 Phase 1: 共享库开发 ✅ 完成

**仓库位置**: `/Users/higuaifan/Desktop/vimo/ETerm/claude-session-db`

**代码统计**:

| 模块 | 文件 | 行数 | 说明 |
|------|------|------|------|
| 入口 | lib.rs | 70 | 模块导出、文档 |
| 配置 | config.rs | 70 | DbConfig、ConnectionMode |
| 错误 | error.rs | 42 | Error enum、Result |
| 类型 | types.rs | 101 | Project/Session/Message/SearchResult |
| Schema | schema.rs | 100 | 核心表 + FTS5 + 协调表 |
| 数据库 | db.rs | 381 | SessionDB、CRUD 操作 |
| 协调 | coordination.rs | 384 | Coordinator、原子抢占、心跳 |
| 写入 | writer.rs | 100 | 增量扫描、消息转换 |
| 搜索 | search.rs | 101 | FTS5 全文搜索 |
| FFI | ffi.rs | 174 | C ABI (Swift 绑定用) |
| **总计** | **10 文件** | **~1,520** | |

**测试覆盖** (42 个测试全部通过):

| 类别 | 测试数 | 覆盖内容 |
|------|--------|----------|
| 连接测试 | 3 | 创建文件、重连、配置 |
| Project | 4 | CRUD、去重、多项目 |
| Session | 4 | CRUD、检查点、时间戳 |
| Message | 4 | 插入、去重、分页、角色 |
| 增量扫描 | 3 | 首次、增量、安全边界 |
| FTS5 搜索 | 3 | 基础、项目过滤、限制 |
| 统计 | 2 | 空库、有数据 |
| Writer 协调 | 7 | 抢占、心跳、释放、接管、多 DB |
| 边界情况 | 8 | 空值、Unicode、大数据、排序 |
| 转换函数 | 6 | 各类型消息、时间戳解析 |

**Feature Flags** (实际实现):

```toml
[features]
default = ["writer", "reader", "search", "coordination"]
writer = []           # 写入能力
reader = []           # 只读能力
search = ["fts"]      # 搜索能力
fts = []              # FTS5 支持
coordination = []     # Writer 协调逻辑
ffi = []              # C FFI 导出 (Swift 绑定用)
```

**与设计文档的差异**:

| 设计 | 实现 | 原因 |
|------|------|------|
| async API | sync API | rusqlite 是同步的，简化实现 |
| libsql 支持 | 仅 SQLite | V1 先支持本地，远程后续添加 |
| - | ffi feature | 为 Swift 绑定预留 |

### 11.2 Phase 2: 组件适配 (部分完成)

#### 2.1 Writer 协调机制 ✅ 完成

所有组件已实现 Writer 协调（注册、心跳、释放、接管）：

| 组件 | 位置 | 协调状态 |
|------|------|----------|
| memex-rs | SharedDbAdapter | ✅ 完成 |
| vlaude-core | SharedDbAdapter | ✅ 完成 |
| VlaudeKit | SharedDbBridge (Swift) | ✅ 完成 |
| MemexKit | SharedDbBridge (Swift) | ✅ 完成 |

**协调测试验证** (2024-12-30):

| 场景 | 状态 | 说明 |
|------|------|------|
| D4 | ✅ | MemexKit 退出 → daemon 接管 |
| G1 | ✅ | VlaudeKit 成为 Writer |
| G2 | ✅ | 心跳每 10s 更新 |
| G5 | ✅ | VlaudeKit 退出 → MemexKit 接管 |
| G6 | ✅ | MemexKit 退出 → daemon 接管 |
| G7 | ✅ | 线程安全无死锁 |

#### 2.2 数据写入集成 ✅ 完成

| 组件 | FFI 写入方法 | 调用写入 | 状态 |
|------|-------------|---------|------|
| claude-session-db | ✅ 有 | - | 基础库 OK |
| memex-rs | ✅ SharedDbAdapter | ✅ Collector.sync_to_shared_db | ✅ 完成 |
| vlaude-core | ✅ SharedDbAdapter | ✅ service.sync_message_to_shared_db | ✅ 完成 |
| VlaudeKit | ✅ SharedDbBridge | ⏳ 待集成 ClaudeKit | ✅ FFI 完成 |
| MemexKit | ✅ SharedDbBridge | ⏳ 待集成 ClaudeKit | ✅ FFI 完成 |

**写入验证** (2024-12-30):

测试结果 (`session.db`):
| 表 | 记录数 |
|----|--------|
| projects | 6 |
| sessions | 18 |
| messages | 392 |

**写入触发点**:

| 组件 | 触发方式 | 说明 |
|------|---------|------|
| memex-rs | Collector 全量/增量扫描 | 文件变化时自动写入 |
| vlaude-core | handle_watch_event | iOS 请求 watch 后有新消息时写入 |
| VlaudeKit/MemexKit | ClaudeKit 事件回调 | ETerm 中 Claude 会话实时写入 |

**心跳 Bug 修复** (2024-12-30):

`start_heartbeat()` 调用 `stop_heartbeat()` 后需重置 `heartbeat_cancel = false`

#### 2.3 Swift FFI 详情

**VlaudeKit** (`Plugins/VlaudeKit/`):

| 文件 | 说明 |
|------|------|
| `Libs/SharedDB/claude_session_db.h` | FFI C header |
| `Libs/SharedDB/libclaude_session_db.dylib` | FFI 动态库 |
| `Sources/VlaudeKit/SharedDbBridge.swift` | Swift 包装 |

**MemexKit** (`Plugins/MemexKit/`):

| 文件 | 说明 |
|------|------|
| `Libs/SharedDB/` | FFI 库 |
| `Sources/MemexKit/SharedDbBridge.swift` | Swift 包装 |

**当前 SharedDbBridge 功能** (协调 + 只读):

```swift
// Writer 协调
func register() throws -> WriterRole
func release() throws
func heartbeat() throws

// 数据读取
func listProjects() throws -> [SharedProject]
func listSessions(projectId:) throws -> [SharedSession]
func listMessages(sessionId:limit:offset:) throws -> [SharedMessage]
func search(query:limit:) throws -> [SharedSearchResult]

// 待添加: 数据写入
// func upsertProject(path:name:) throws -> Int64
// func upsertSession(sessionId:projectId:) throws
// func insertMessages(sessionId:messages:) throws -> Int
```

**安全特性**:

| 问题 | 修复 |
|------|------|
| NULL/无效 UTF-8 C 字符串 | `safeString()` 方法 |
| 负数 limit 溢出 | 参数校验 |
| FFI 线程安全 | 串行 DispatchQueue |
| deinit 未释放 Writer | 显式调用 release |
| Timer 跨线程 | DispatchSourceTimer |

### 11.3 Phase 3-4: 待规划

- Phase 3: 部署优化 (Docker Compose、脚本、文档)
- Phase 4: 完整场景测试 (数据写入验证、性能测试)
