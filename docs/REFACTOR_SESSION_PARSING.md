# Session 解析重构 - 已完成

## 概述

**问题**：Claude Session 解析逻辑被重复实现了 6 次，且所有重复实现都有路径解码 bug（中文路径解析错误）。

**解决方案**：统一使用 `ai-cli-session-collector` 作为单一真相来源，所有组件通过它获取正确的会话解析能力。

---

## 最终架构

```
ai-cli-session-collector (核心库 - 单一真相来源)
├── ClaudeAdapter::parse_session_from_path()  ← 核心方法
├── IndexableSession / IndexableMessage       ← 统一数据结构
│
├──→ session-reader (Rust 封装)
│    └── ClaudeReader::parse_session_from_path()
│         └── 直接委托给 ClaudeAdapter
│
├──→ session-reader-ffi (FFI 层)
│    └── sr_parse_session_for_index()
│         └── 调用 session-reader
│
├──→ VlaudeKit (Swift 薄封装)
│    └── sessionReader.parseSessionForIndex()
│         └── 调用 session-reader-ffi
│
├──→ memex-rs (Rust - 直接依赖)
│    ├── collect_by_path()
│    │    └── 直接调用 ClaudeAdapter::parse_session_from_path()
│    └── memex_index_jsonl() FFI
│         └── 直接调用 ClaudeAdapter::parse_session_from_path()
│
└──→ MemexKit (Swift)
     ├── HTTP 模式 → memex-rs (正确)
     └── SharedDb 模式 → session-reader-ffi (正确)
```

---

## 核心修改

### 1. ai-cli-session-collector

**新增内容**：

```rust
// src/domain/types.rs - 新增数据结构
pub struct IndexableSession {
    pub session_id: String,
    pub project_path: String,  // 从 cwd 读取的真实路径
    pub project_name: String,
    pub messages: Vec<IndexableMessage>,
}

pub struct IndexableMessage {
    pub uuid: String,
    pub role: String,
    pub content: ParsedContent,  // 分离的内容结构
    pub timestamp: i64,
    pub sequence: i64,
}

pub struct ParsedContent {
    pub text: String,  // 纯对话文本（用于向量化）
    pub full: String,  // 完整格式化内容（含 tool_use/tool_result，用于 FTS）
}

// src/adapter/claude.rs - 核心解析方法
impl ClaudeAdapter {
    /// 从 JSONL 文件路径直接解析会话
    /// 正确处理中文路径：优先读取 cwd，fallback 到 decode_path
    pub fn parse_session_from_path(jsonl_path: &str) -> Result<Option<IndexableSession>> {
        // 1. 从 JSONL 读取 cwd（真实路径）
        let cwd = Self::read_cwd_from_jsonl(path);
        // 2. 确定 project_path（优先 cwd）
        let project_path = cwd.unwrap_or_else(|| Self::decode_path(encoded_dir_name));
        // 3. 解析消息...
    }
}
```

**提交**：`ca4284e feat: add parse_session_from_path for direct JSONL parsing`

---

### 2. session-reader

**修改**：简化为直接委托

```rust
// src/types.rs - 从 ai-cli-session-collector 重导出
pub use ai_cli_session_collector::{
    IndexableMessage, IndexableSession, MessageType, ParseResult, ParsedMessage, SessionMeta, Source,
};

// src/claude.rs - 委托给核心库
impl ClaudeReader {
    pub fn parse_session_from_path(&self, jsonl_path: &str) -> Result<Option<IndexableSession>> {
        ClaudeAdapter::parse_session_from_path(jsonl_path)  // 直接调用
    }
}
```

**删除**：~140 行重复实现（read_cwd_from_jsonl、parse_timestamp、本地 IndexableSession 类型）

---

### 3. memex-rs

**collector/mod.rs 修改**：

```rust
pub fn collect_by_path(&self, path: &str) -> Result<CollectResult> {
    // 直接调用核心库
    let session = ClaudeAdapter::parse_session_from_path(path)?;

    // 使用正确的 project_path（已从 cwd 读取）
    let project_id = self.db.get_or_create_project(
        &session.project_name,
        &session.project_path,  // 正确！
        "claude",
    )?;

    // 使用新的 insert_indexable_messages 方法
    self.db.insert_indexable_messages(&session.session_id, &session.messages)?;
}
```

**ffi.rs 修改**：

```rust
pub extern "C" fn memex_index_jsonl(
    handle: *mut MemexHandle,
    jsonl_path: *const c_char,
    _project_path: *const c_char,  // 不再使用
) -> c_int {
    // 直接调用核心库
    let session = ClaudeAdapter::parse_session_from_path(jsonl_path)?;
    // ...
}
```

**db/mod.rs 新增**：

```rust
/// 批量插入消息（直接接受 IndexableMessage）
pub fn insert_indexable_messages(
    &self,
    session_id: &str,
    messages: &[IndexableMessage],
) -> Result<(usize, Vec<i64>)>
```

**删除**：~110 行重复实现

---

### 4. Swift 插件

**VlaudeKit** - 通过 session-reader-ffi 使用核心库
**MemexKit** - 通过 session-reader-ffi（SharedDb 模式）或 HTTP（memex-rs 模式）使用核心库

---

## 路径解码 Bug 修复

### 问题

Claude Code 编码中文路径时，每个中文字符变成 `-`：
```
/Users/.../小工具/english → -Users-...----- english
```

简单的 `-` → `/` 替换会得到错误结果：
```
/Users/.../////english  ← 错误！
```

### 解决方案

优先从 JSONL 文件的 `cwd` 字段读取真实路径：

```rust
let cwd = Self::read_cwd_from_jsonl(path);  // 读取 JSONL 前 10 行
let project_path = cwd.unwrap_or_else(|| Self::decode_path(encoded_dir_name));
```

---

## 重构收益

| 指标 | 重构前 | 重构后 |
|------|-------|-------|
| 解析逻辑实现次数 | 6 次 | 1 次 |
| 冗余代码行数 | ~580 行 | 0 行 |
| 路径解码 bug | 5 处 | 0 处 |
| 维护点 | 6 个文件 | 1 个文件 |

---

## 相关提交

1. **ai-cli-session-collector**: `ca4284e` - 添加 `parse_session_from_path`
2. **vlaude-core**: session-reader 简化，重导出类型（待提交，暂存区有其他混合更改）
3. **memex-rs**: `6822456` - 简化 collector 和 ffi，添加 `insert_indexable_messages`

---

## 文件清单

### 核心库
- `ai-cli-session-collector/src/adapter/claude.rs` - 核心解析
- `ai-cli-session-collector/src/domain/types.rs` - IndexableSession/Message

### 封装层
- `vlaude-core/session-reader/src/claude.rs` - Rust 封装
- `vlaude-core/session-reader-ffi/src/lib.rs` - FFI 层

### 使用方
- `memex-rs/src/collector/mod.rs` - collect_by_path
- `memex-rs/src/ffi.rs` - memex_index_jsonl
- `memex-rs/src/db/mod.rs` - insert_indexable_messages
- `MemexKit/Sources/MemexKit/MemexService.swift` - indexSessionViaSharedDb
- `VlaudeKit/Sources/VlaudeKit/VlaudeClient.swift` - indexSession

---

## 内容分离设计 (2024-12 更新)

### 问题

原 `content: String` 字段简化了 Claude Code JSONL 的复杂内容结构，导致 91.1% 的数据丢失：
- `tool_use` 块（函数调用参数）
- `tool_result` 块（执行结果）
- `thinking` 块（思考过程）

### 解决方案

引入 `ParsedContent` 结构，分离用途：

```rust
pub struct ParsedContent {
    pub text: String,  // 纯对话文本（用于向量化）
    pub full: String,  // 完整格式化内容（用于 FTS）
}
```

### 内容块分类规则

| 块类型 | text | full | 说明 |
|--------|------|------|------|
| `text` | ✓ | ✓ | 对话内容，两者都需要 |
| `tool_use` | ✗ | ✓ | 函数调用，只用于 FTS 搜索 |
| `tool_result` | ✗ | ✓ | 执行结果，只用于 FTS 搜索 |
| `thinking` | ✗ | ✗ | 思考过程，排除出索引 |

### 数据库 Schema

```sql
CREATE TABLE messages (
    ...
    content_text TEXT NOT NULL,  -- 向量化用
    content_full TEXT NOT NULL,  -- FTS 搜索用
    ...
);
```

### 使用场景

- **向量化 (memex)**: 使用 `content.text`，只索引对话部分
- **FTS 搜索**: 使用 `content_full`，可搜索工具调用信息
- **FFI 层**: 输入用 `content`，内部映射到两个字段
