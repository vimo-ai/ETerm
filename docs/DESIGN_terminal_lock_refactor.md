# Terminal 锁架构重构设计文档

> 临时文档，开发完成后删除

## 一、背景

### 问题现象

App 频繁卡死，特别是 Claude CLI 大量输出时。

### 根本原因

PTY 线程在 `compute_index` 处理终端数据时，长时间持有 `Terminal` 的写锁，导致：
- CVDisplayLink 渲染线程阻塞（等读锁）
- 主线程 UI 交互阻塞（等读锁）

### 当前锁结构

```
TerminalPool
└── terminals: HashMap<usize, TerminalEntry>
    └── TerminalEntry
        └── terminal: Mutex<Terminal>      ← 粗粒度锁
            └── crosswords: RwLock<Crosswords>  ← 内部读写锁
```

### 当前竞争点

| 操作 | 线程 | 锁类型 | 持有时间 |
|------|------|--------|----------|
| compute_index | PTY | 写锁 | **长** |
| is_damaged | CVDisplayLink | 读锁 | 短 |
| state() | CVDisplayLink | 读锁 | 中 |
| getCursorPosition | Main | 读锁 | 短 |
| screenToAbsolute | Main | 读锁 | 短 |
| set_selection | Main | 写锁 | 短 |

---

## 二、设计目标

1. PTY 线程处理数据时**不阻塞**渲染和 UI
2. 渲染线程读取状态时**不阻塞** PTY
3. 主线程 UI 交互**永不阻塞**
4. 保持 FFI 接口不变
5. 所有改动可通过测试用例验证

---

## 三、方案：SPSC 队列 + 状态分离

### 核心思路

**分离「解析」和「渲染状态」**

- PTY 线程：只负责解析，生成事件，推入无锁队列
- 渲染线程：消费事件，更新渲染状态，执行渲染
- 主线程：读取原子缓存或渲染状态快照

### 新数据流

```
┌─────────────┐                      ┌─────────────┐
│  PTY 线程   │                      │ CVDisplayLink│
│             │                      │             │
│  pty_read() │                      │ render_all()│
│      │      │                      │      │      │
│      ▼      │                      │      ▼      │
│  Parser     │    SPSC Queue        │ RenderState │
│  (解析)     │ ===================> │ (渲染状态)  │
│             │   TerminalEvent      │             │
└─────────────┘                      └─────────────┘
                                           ↑
                                           │ 读取缓存
                                     ┌─────────────┐
                                     │  主线程     │
                                     │ cursor_cache│
                                     │ atomic read │
                                     └─────────────┘
```

### 新锁结构

```
Terminal (重构后)
├── parser: Parser                    // PTY 线程独占，无锁
├── event_queue: SPSC<TerminalEvent>  // 无锁队列
├── render_state: RenderState         // 渲染线程独占，无锁
├── cursor_cache: AtomicU64           // 原子操作 pack(col, row)
├── selection: Mutex<Selection>       // 极少写入，短暂持有
└── dirty: AtomicBool                 // 原子操作
```

---

## 四、TerminalEvent 定义

```
TerminalEvent（枚举）
├── CellsUpdate { line, start_col, cells: Vec<Cell> }  // 批量单元格更新
├── LineFeed                                            // 换行
├── CarriageReturn                                      // 回车
├── ScrollUp { lines }                                  // 向上滚动
├── ScrollDown { lines }                                // 向下滚动
├── CursorMove { line, col }                           // 光标移动
├── CursorStyle { style }                              // 光标样式
├── ClearLine { mode }                                 // 清除行
├── ClearScreen { mode }                               // 清屏
├── Resize { cols, rows }                              // 调整大小
├── SetAttribute { attr }                              // 设置属性（颜色等）
├── Bell                                                // 响铃
├── TitleChange { title }                              // 标题变更
├── SelectionStart { point }                           // 选区开始
├── SelectionUpdate { point }                          // 选区更新
├── SelectionClear                                      // 清除选区
└── Damage { full: bool, lines: Option<Range> }        // 标记脏区域
```

---

## 五、模块职责

### Parser

- 输入：PTY 字节流
- 输出：TerminalEvent 序列
- 职责：解析 ANSI/VT 转义序列，不维护状态
- 线程：PTY 线程独占

### SPSC Queue

- 类型：无锁单生产者单消费者环形队列
- 生产者：PTY 线程
- 消费者：渲染线程
- 容量：可配置，建议 4096~16384 events
- 溢出策略：丢弃旧事件 or 背压（待定）

### RenderState

- 职责：存储可渲染的终端状态
- 包含：grid、cursor、colors、attributes、history
- 更新：消费 TerminalEvent 应用状态变更
- 线程：渲染线程独占，无需锁

### Cursor Cache

- 类型：AtomicU64
- 格式：pack(col: u16, row: u16, valid: bool, _padding)
- 更新：渲染线程处理 CursorMove 事件时更新
- 读取：主线程原子读取，无锁

---

## 六、涉及改动的文件

### Rust 端

| 文件 | 改动 |
|------|------|
| 新增 `domain/events/terminal_event.rs` | TerminalEvent 枚举定义 |
| 新增 `domain/events/mod.rs` | 模块导出 |
| 新增 `infra/spsc_queue.rs` | 无锁队列（或用 crossbeam） |
| 新增 `domain/aggregates/parser.rs` | Parser 实现 |
| 新增 `domain/aggregates/render_state.rs` | RenderState 实现 |
| 重构 `domain/aggregates/terminal.rs` | 拆分，组合新模块 |
| 修改 `app/terminal_pool.rs` | 适配新结构，修改 render_terminal |
| 修改 `ffi/cursor.rs` | 读 cursor_cache |
| 修改 `ffi/selection.rs` | 读 render_state |
| 修改 `ffi/word_boundary.rs` | 读 render_state |

### Swift 端

FFI 接口不变，**无需改动**。

---

## 七、实施步骤

### Phase 1：基础设施

1. 实现 SPSC Queue（或引入 crossbeam-channel）
2. 定义 TerminalEvent 枚举
3. 编写单元测试

### Phase 2：Parser

1. 从 crosswords 提取解析逻辑
2. 实现 Parser，输出 TerminalEvent
3. 编写测试：各种转义序列 → 正确事件

### Phase 3：RenderState

1. 实现 RenderState
2. 实现 apply_event 方法
3. 编写测试：事件 → 正确状态

### Phase 4：集成

1. 重构 Terminal，组合新模块
2. 修改 PTY 处理流程
3. 修改渲染流程
4. 编写集成测试

### Phase 5：FFI 适配

1. cursor.rs 改读原子缓存
2. selection.rs / word_boundary.rs 适配
3. 验证现有测试通过

### Phase 6：压力测试

1. 并发读写测试
2. 高吞吐量测试
3. 长时间运行测试

---

## 八、测试策略

### 单元测试

| 模块 | 测试点 |
|------|--------|
| SPSC Queue | push/pop、空/满、并发安全 |
| TerminalEvent | 构造、序列化 |
| Parser | 各种转义序列解析 |
| RenderState | apply_event 正确性 |

### 集成测试

| 场景 | 验证 |
|------|------|
| 普通文本 | grid 内容 |
| ANSI 颜色 | 颜色属性 |
| 光标移动 | cursor_cache |
| 滚动 | history + display_offset |
| 选区 | 选中文本 |
| resize | 状态一致 |

### 压力测试

| 场景 | 验证 |
|------|------|
| 并发写读 | 不死锁、不崩溃 |
| 高吞吐量 | 队列不溢出 |
| 长时间运行 | 内存稳定 |

---

## 九、风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| 事件队列溢出 | 设置合理容量 + 监控 + 背压 |
| 解析逻辑 bug | 复用现有 crosswords 解析代码 |
| 状态不一致 | 充分测试 + 对比旧实现输出 |
| 性能下降 | 基准测试对比 |

---

## 十、回滚方案

保留现有代码，用 feature flag 切换：

```rust
#[cfg(feature = "new_terminal_arch")]
mod new_terminal;

#[cfg(not(feature = "new_terminal_arch"))]
mod terminal;  // 现有实现
```

---

## 十一、成功标准

1. Claude CLI 大量输出时不卡死
2. 所有现有测试通过
3. 新增测试覆盖率 > 80%
4. 渲染帧率稳定 60fps
5. 主线程永不阻塞

---

## 十二、临时修复（当前状态）

在重构完成前，已应用 try_lock 绕过：

- `ffi/cursor.rs` - try_get_terminal
- `ffi/selection.rs` - try_get_terminal / try_get_terminal_mut
- `ffi/word_boundary.rs` - try_get_terminal
- `app/terminal_pool.rs` render_terminal - try_lock for is_damaged and state

副作用：锁竞争时操作会静默失败或使用缓存，可能偶尔丢帧。

---

*文档创建时间：2025-12-09*
*完成后删除此文档*
