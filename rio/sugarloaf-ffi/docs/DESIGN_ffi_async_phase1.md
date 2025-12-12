# FFI 异步化 Phase 1 设计文档

## 目标

将 FFI 层改造为**完全非阻塞**的异步事件驱动架构，使 Swift 主线程永不被 Rust 锁阻塞。

## 当前架构问题

```
Swift 主线程                    Rust 层
     │                            │
     ▼                            │
  FFI 调用 ──────────────────────▶ terminal.lock()  ← 可能阻塞
     │                            │
     │  【等待锁释放...】           │
     │                            │
     ◀──────────────────────────── 返回结果
     │
     ▼
  UI 更新（可能已卡顿）
```

## 目标架构

```
Swift 主线程                    Rust 层
     │                            │
     ▼                            │
  写入事件 ──────────────────────▶ SPSC 队列（写入即返回）
     │                            │
     ▼                            ▼
  读取状态 ◀────────────────────── 原子缓存（无锁读取）
     │                            │
     ▼                            │
  UI 更新（永不阻塞）               │
```

---

## Phase 1 工作项

### P0: 修复残留阻塞点

#### 问题位置
`src/app/terminal_pool.rs:1179`

```rust
pub fn set_terminal_mode(&self, terminal_id: usize, mode: TerminalMode) {
    if let Some(entry) = self.terminals.get(&terminal_id) {
        entry.is_background.store(is_background, Ordering::Release);

        let mut terminal = entry.terminal.lock();  // ← 阻塞！
        terminal.set_mode(mode);
        // ...
    }
}
```

#### 解决方案
既然 `is_background` 原子标记已经更新，Terminal 内部的 mode 字段可以延迟更新：

```rust
pub fn set_terminal_mode(&self, terminal_id: usize, mode: TerminalMode) {
    if let Some(entry) = self.terminals.get(&terminal_id) {
        let is_background = mode == TerminalMode::Background;
        entry.is_background.store(is_background, Ordering::Release);

        // 尝试更新 Terminal，如果锁被占用则跳过
        // Terminal 内部状态会在下次渲染时通过原子标记同步
        if let Some(mut terminal) = entry.terminal.try_lock() {
            terminal.set_mode(mode);
        }

        if mode == TerminalMode::Active {
            self.needs_render.store(true, Ordering::Release);
        }
    }
}
```

---

### P1: 完善原子状态缓存

#### 1.1 新增 AtomicSelectionCache

**文件**: `src/infra/atomic_cache.rs`

```rust
/// 选区缓存
///
/// 布局（128 位）：
/// - bits 0-31: start_row (u32)
/// - bits 32-63: start_col (u32)
/// - bits 64-95: end_row (u32)
/// - bits 96-127: end_col (u32)
///
/// 使用两个 AtomicU64 实现
pub struct AtomicSelectionCache {
    start: AtomicU64,  // (start_row << 32) | start_col
    end: AtomicU64,    // (end_row << 32) | end_col | (valid << 63)
}

impl AtomicSelectionCache {
    pub fn new() -> Self;
    pub fn update(&self, start_row: u32, start_col: u32, end_row: u32, end_col: u32);
    pub fn read(&self) -> Option<(u32, u32, u32, u32)>;
    pub fn clear(&self);
}
```

#### 1.2 新增 AtomicTitleCache

**文件**: `src/infra/atomic_cache.rs`

```rust
/// 标题缓存（使用 Arc<str> + AtomicPtr）
pub struct AtomicTitleCache {
    ptr: AtomicPtr<str>,
}

impl AtomicTitleCache {
    pub fn new() -> Self;
    pub fn update(&self, title: &str);
    pub fn read(&self) -> Option<String>;
}
```

#### 1.3 新增 AtomicScrollCache

**文件**: `src/infra/atomic_cache.rs`

```rust
/// 滚动位置缓存
///
/// 布局（64 位）：
/// - bits 0-31: display_offset (u32)
/// - bits 32-47: history_size (u16，截断）
/// - bits 48-63: total_lines (u16，截断）
pub struct AtomicScrollCache {
    packed: AtomicU64,
}

impl AtomicScrollCache {
    pub fn new() -> Self;
    pub fn update(&self, display_offset: u32, history_size: usize, total_lines: usize);
    pub fn read(&self) -> Option<(u32, u16, u16)>;
}
```

#### 1.4 更新 TerminalEntry

**文件**: `src/app/terminal_pool.rs`

```rust
struct TerminalEntry {
    terminal: Arc<Mutex<Terminal>>,
    pty_tx: channel::Sender<rio_backend::event::Msg>,
    machine_handle: JoinHandle<...>,
    cols: u16,
    rows: u16,
    pty_fd: i32,
    shell_pid: u32,
    render_cache: Option<TerminalRenderCache>,

    // 原子缓存
    cursor_cache: Arc<AtomicCursorCache>,      // ✅ 已有
    is_background: Arc<AtomicBool>,            // ✅ 已有
    selection_cache: Arc<AtomicSelectionCache>, // 🆕 新增
    title_cache: Arc<AtomicTitleCache>,         // 🆕 新增
    scroll_cache: Arc<AtomicScrollCache>,       // 🆕 新增
}
```

#### 1.5 更新缓存的时机

在 `render_terminal()` 中，获取 terminal state 后更新所有缓存：

```rust
// 更新原子缓存（在持有锁期间）
{
    // 光标缓存（已有）
    cursor_cache.update(col, row, display_offset);

    // 选区缓存（新增）
    if let Some(sel) = &state.selection {
        selection_cache.update(
            sel.start.row as u32, sel.start.col as u32,
            sel.end.row as u32, sel.end.col as u32,
        );
    } else {
        selection_cache.clear();
    }

    // 滚动缓存（新增）
    scroll_cache.update(
        state.grid.display_offset() as u32,
        state.grid.history_size(),
        state.grid.total_lines(),
    );

    // 标题缓存在收到 TitleChanged 事件时更新
}
```

#### 1.6 新增 FFI 函数（无锁版本）

**文件**: `src/ffi/selection.rs`

```rust
/// 获取选区范围（无锁）
#[no_mangle]
pub extern "C" fn terminal_pool_get_selection_range(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> SelectionRange {
    // 从 selection_cache 读取，不需要锁
}
```

**文件**: `src/ffi/terminal_pool.rs`

```rust
/// 获取滚动信息（无锁）
#[no_mangle]
pub extern "C" fn terminal_pool_get_scroll_info(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> ScrollInfo {
    // 从 scroll_cache 读取，不需要锁
}
```

---

### P2: 事件队列（Swift → Rust）

#### 2.1 定义事件类型

**文件**: `src/infra/input_event.rs`（新文件）

```rust
/// Swift → Rust 的输入事件
#[derive(Debug, Clone)]
pub enum InputEvent {
    /// 键盘输入
    KeyInput {
        terminal_id: usize,
        data: Vec<u8>,
    },

    /// 滚动
    Scroll {
        terminal_id: usize,
        delta: i32,
    },

    /// 选区开始
    SelectionStart {
        terminal_id: usize,
        row: i64,
        col: usize,
    },

    /// 选区更新
    SelectionUpdate {
        terminal_id: usize,
        row: i64,
        col: usize,
    },

    /// 选区结束
    SelectionEnd {
        terminal_id: usize,
    },

    /// 调整大小
    Resize {
        terminal_id: usize,
        cols: u16,
        rows: u16,
        width: f32,
        height: f32,
    },
}
```

#### 2.2 添加输入事件队列

**文件**: `src/app/terminal_pool.rs`

```rust
pub struct TerminalPool {
    // ... 现有字段 ...

    /// Swift → Rust 输入事件队列
    input_queue: Arc<SpscQueue<InputEvent>>,
}
```

#### 2.3 新增异步 FFI 函数

**文件**: `src/ffi/input.rs`（新文件）

```rust
/// 发送键盘输入（异步，写入队列后立即返回）
#[no_mangle]
pub extern "C" fn terminal_pool_input_async(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    data: *const u8,
    len: usize,
) -> bool {
    // 写入 input_queue，立即返回
}

/// 发送滚动事件（异步）
#[no_mangle]
pub extern "C" fn terminal_pool_scroll_async(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    delta: i32,
) -> bool {
    // 写入 input_queue，立即返回
}
```

#### 2.4 事件消费线程

在 `TerminalPool::new()` 中启动消费线程：

```rust
// 启动输入事件消费线程
let input_queue_consumer = input_queue.clone();
let terminals_ref = /* 需要设计如何共享 terminals */;

std::thread::spawn(move || {
    loop {
        if let Some(event) = input_queue_consumer.pop() {
            match event {
                InputEvent::KeyInput { terminal_id, data } => {
                    // 发送到 PTY
                },
                InputEvent::Scroll { terminal_id, delta } => {
                    // try_lock + scroll
                },
                // ...
            }
        } else {
            std::thread::sleep(Duration::from_micros(100));
        }
    }
});
```

**注意**: 这里有架构挑战，因为消费线程需要访问 `terminals` HashMap。可能的解决方案：
1. 使用 `Arc<DashMap>` 替换 `HashMap`
2. 通过 channel 与主线程通信
3. P2 可以先保持同步 FFI，只做 P0 和 P1

---

## 实施顺序

```
Step 1: P0 - 修复 set_terminal_mode（30 分钟）
        └── 改为 try_lock
        └── 测试验证

Step 2: P1.1-1.3 - 新增原子缓存类型（2 小时）
        └── AtomicSelectionCache
        └── AtomicTitleCache
        └── AtomicScrollCache
        └── 单元测试

Step 3: P1.4-1.5 - 集成到 TerminalEntry（1 小时）
        └── 更新 TerminalEntry 结构
        └── 在 render_terminal 中更新缓存

Step 4: P1.6 - 新增无锁 FFI 函数（1 小时）
        └── terminal_pool_get_selection_range
        └── terminal_pool_get_scroll_info

Step 5: P2 - 事件队列（可选，3-4 小时）
        └── 需要解决 terminals 共享问题
        └── 可以后续迭代
```

---

## 测试验证

### 单元测试

1. 原子缓存并发测试（参考现有 `test_atomic_cursor_cache_concurrent`）
2. SPSC 队列已有完整测试

### 集成测试

```rust
#[test]
fn test_ffi_never_blocks() {
    // 1. 创建 TerminalPool
    // 2. 在后台线程持续锁定 Terminal
    // 3. 在主线程调用所有 FFI 函数
    // 4. 验证主线程不阻塞（设置超时）
}
```

### 手动验证

1. 运行 ETerm，持续执行 `cat /dev/urandom | xxd`
2. 同时进行 UI 操作（滚动、选区、切换 Tab）
3. 观察是否有卡顿

---

## 文件清单

### 修改的文件

| 文件 | 改动 |
|-----|------|
| `src/infra/mod.rs` | 导出新类型 |
| `src/infra/atomic_cache.rs` | 新增 3 个缓存类型 |
| `src/app/terminal_pool.rs` | TerminalEntry 新字段 + 缓存更新 + set_terminal_mode 修复 |
| `src/ffi/selection.rs` | 新增无锁 FFI |
| `src/ffi/terminal_pool.rs` | 新增无锁 FFI |
| `src/ffi/mod.rs` | 导出新函数 |

### 新增的文件

| 文件 | 说明 |
|-----|------|
| `src/infra/input_event.rs` | 输入事件类型定义（P2） |
| `src/ffi/input.rs` | 异步输入 FFI（P2） |

---

## 风险与注意事项

1. **原子缓存一致性**: 多个缓存之间可能短暂不一致（如光标移动但选区未更新）。这是可接受的，因为下一帧会同步。

2. **内存序**: 所有原子操作使用 `Release/Acquire` 语义，确保跨线程可见性。

3. **P2 的 terminals 共享**: 需要仔细设计，可能引入 `DashMap` 依赖或使用 channel。

4. **Swift 侧适配**: 新增的无锁 FFI 需要 Swift 侧使用。旧的 try_lock FFI 保持兼容，Swift 可以逐步迁移。

---

## 预期收益

| 指标 | 当前 | Phase 1 后 |
|-----|------|-----------|
| Swift 主线程最大阻塞时间 | 0-50ms | 0ms |
| FFI 调用平均延迟 | 1-10μs（无竞争）/ 1-50ms（竞争）| <1μs |
| UI 流畅度 | 偶发卡顿 | 永不卡顿 |

---

## 已知问题（Codex 审查 2024-12）

### 🔴 严重：AtomicTitleCache Use-After-Free 风险

**文件**: `src/infra/atomic_cache.rs`

```rust
pub fn read(&self) -> Option<String> {
    let ptr = self.ptr.load(Ordering::Acquire);  // 拿到指针
    // ← 此时 writer 可能 swap + drop 旧值
    unsafe { Some((*ptr).clone()) }  // 💀 读取已释放内存
}
```

**问题**: Reader load 指针后、clone 前，Writer 可能 swap + drop，导致 UAF。

**修复方案**: 使用 `arc_swap::ArcSwap<String>` 或手动引用计数 + epoch/hazard pointer。

**当前状态**: TitleCache 目前未被 Swift 侧调用，暂时安全。去 RIO 化时需修复或删除。

---

### 🟡 中等：AtomicSelectionCache 位操作 bug

**文件**: `src/infra/atomic_cache.rs`

```rust
fn unpack_coord(packed: u64) -> (i32, u32) {
    let row = (packed & 0xFFFFFFFF) as i32;
    let col = ((packed >> 32) & 0x7FFFFFFF) as u32;  // ❌ mask 掉了 col 的 bit 31
    (row, col)
}
```

**问题**: `0x7FFFFFFF` 意图是移除 valid bit（bit 63），但移位后 valid bit 在 bit 31 位置，mask 错误地丢失了 col 的最高位。

**实际影响**: col 不太可能超过 2^31（约 21 亿列），暂时安全。

**修复方案**: 将 valid bit 存储位置改为独立字段，或调整 mask 逻辑。

---

### 🟡 中等：数值溢出/截断

**文件**: `src/infra/atomic_cache.rs`

| 字段 | 存储类型 | 实际类型 | 最大值 | 问题 |
|-----|---------|---------|-------|------|
| `history_size` | u16 | usize | 65535 | 大历史记录会截断 |
| `total_lines` | u15 | usize | 32767 | 超过后数据错误 |
| `display_offset` | u16 | usize | 65535 | 滚动位置可能溢出 |

**实际影响**: 默认 history 10000 行，正常使用不会触发。极端场景（如 `cat huge_file.log`）可能导致 UI 显示错误的滚动进度。

**修复方案**: 使用 AtomicU128 或分拆为多个原子变量。

---

### 🟡 中等：try_lock 失败语义不清

**文件**: `src/app/terminal_pool.rs`

```rust
pub fn search(&self, terminal_id: usize, query: &str) -> i32 {
    // ...
    if let Some(mut terminal) = entry.terminal.try_lock() {
        // ...
        count as i32
    } else {
        -1  // ← 和"终端不存在"返回值相同
    }
}
```

**问题**: `-1` 既表示"终端不存在"也表示"锁被占用"，调用方无法区分临时失败和永久失败。

**修复方案**: 返回枚举或不同错误码（如 `-1` = 不存在，`-2` = 忙）。

---

### 🟢 已确认正确

- **内存顺序**: Release/Acquire 配对在单生产者/单消费者场景下正确
- **AtomicCursorCache**: 实现正确，无问题
- **AtomicScrollCache**: 除截断问题外实现正确

---

### 🔵 原有架构问题（非 Phase 1 引入）

**渲染 TOCTOU 竞争条件**

```
render_terminal() 流程：
1. try_lock() 获取 state 快照
2. 释放锁
3. 渲染（此时 PTY 可能写入新数据）
4. reset_damage()  ← 清除了新数据的 damage 标记
5. 下一帧 is_damaged=false，跳过渲染 → 内容丢失
```

**症状**: 偶发渲染不完整

**修复方案**: 使用 version stamp 或 double buffering（建议在去 RIO 化时从设计上解决）

---

## 后续计划

考虑到即将进行的"去 RIO 化"（用 alacritty_terminal 替换 rio-backend），以上问题建议：

1. **AtomicTitleCache UAF**: 如果不用就删除，如果要用则在新架构中用 ArcSwap 重写
2. **位操作 bug**: 在新架构中用更清晰的结构设计
3. **数值截断**: 评估新架构的实际需求再决定
4. **TOCTOU**: 新架构从设计上避免（如 triple buffering）
