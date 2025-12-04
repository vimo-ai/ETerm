# PTY-Render 架构重构指南

> 本文档记录从 PTY 到 Swift 渲染的完整链路分析、目标架构设计及重构路径。

---

## 目录

1. [历史架构分析](#1-历史架构分析)
2. [冗余代码清单](#2-冗余代码清单)
3. [目标架构设计](#3-目标架构设计)
4. [重构路径](#4-重构路径)
5. [附录：核心数据流](#5-附录核心数据流)

---

## 1. 历史架构分析

### 1.1 当前数据流

```
PTY (teletypewriter)
    ↓ fork+exec shell, 子进程输出
I/O Thread (Machine)
    ↓ pty_read() → parser.advance()
ANSI Parser (BatchedParser/Processor)
    ↓ Handler trait
Terminal State (Crosswords)
    ↓ Grid 更新 + Damage Tracking
FFI Event (Wakeup/Render)
    ↓ C callback
Swift Event Layer (GlobalTerminalManager)
    ↓ 路由到 Coordinator
Coordinator (TerminalWindowCoordinator)
    ↓ scheduleRender() → requestRender()
CVDisplayLink
    ↓ 同步刷新率
Render (rio_pool_render_all)
    ↓ snapshot + layout
Sugarloaf (Skia)
    ↓ Metal drawable
屏幕
```

### 1.2 核心模块职责

| 模块 | 位置 | 当前职责 |
|------|------|----------|
| `teletypewriter` | `rio/teletypewriter/` | PTY 创建、I/O、子进程管理 |
| `Machine` | `rio_machine.rs` | I/O 事件循环、PTY 读写 |
| `Crosswords` | `rio-backend/crosswords/` | 终端状态机、Grid、Damage |
| `RioTerminal` | `rio_terminal.rs` | 终端包装器、快照、布局 |
| `RioTerminalPool` | `rio_terminal.rs` | 终端集合管理、渲染入口 |
| `Sugarloaf` | `rio/sugarloaf/` | Skia 渲染、字体、缓存 |
| `GlobalTerminalManager` | Swift | 全局终端管理、事件路由 |
| `RioTerminalPoolWrapper` | Swift | 终端池封装（大部分已废弃） |
| `TerminalWindowCoordinator` | Swift | 窗口协调、布局管理 |

### 1.3 当前架构的问题

#### 1.3.1 贫血模型 + 职责散乱

```
Machine (I/O)
    ↓ 数据传递
Crosswords (状态容器)
    ↓ 数据传递
RioTerminal (包装)
    ↓ 数据传递
RioTerminalPool (集合)
    ↓ 数据传递
Sugarloaf (渲染)
    ↓ 数据传递
GlobalTerminalManager (又一个管理)
    ↓ 数据传递
TerminalWindowCoordinator (又一个协调)
```

每一层只是传递数据，逻辑散落各处。

#### 1.3.2 三层缓存，策略分散

| 缓存 | 位置 | Key | Value |
|------|------|-----|-------|
| `fragments_cache` | `RioTerminalPool` | content_hash | 解析后的字符数据 |
| `layout_cache` | `Sugarloaf` | content_hash | 字体查找+位置 |
| `raster_cache` | `Sugarloaf` | content_hash | 行渲染后的 Image |

三层缓存使用相同的 key，但分布在不同位置，维护困难。

#### 1.3.3 状态混入渲染

选区、搜索高亮、光标颜色在 `render_terminal_content` 阶段混入：

```rust
// 光标
if is_block_cursor { fg_r = 0.0; fg_g = 0.0; fg_b = 0.0; }

// 搜索高亮
if in_match { bg_r = 0xFF; bg_g = 0xFF; bg_b = 0x00; }
```

导致缓存失效逻辑复杂：内容没变，但选区/搜索变了，缓存也要失效。

#### 1.3.4 双重管理层

Swift 侧存在两个功能重叠的管理器：

- `RioTerminalPoolWrapper` - 早期封装
- `GlobalTerminalManager` - 后来加入

两者都有：`onNeedsRender`、`onTitleChange`、`onTerminalClose`、`onBell` 等回调。

---

## 2. 冗余代码清单

### 2.1 Rust 侧

#### 2.1.1 待删除文件/模块

| 文件 | 原因 |
|------|------|
| `rio_terminal.rs` 中的大部分代码 | 重构后由新的 Domain 替代 |
| `rio_machine.rs` | 可简化，合并到 Terminal Domain |
| `rio_event.rs` 中的复杂事件系统 | 新架构使用更简单的事件模型 |

#### 2.1.2 待删除的缓存层

| 缓存 | 位置 | 原因 |
|------|------|------|
| `fragments_cache` | `RioTerminalPool` | 合并到 RenderContext 单一缓存 |
| `layout_cache` | `Sugarloaf` | 合并到 RenderContext 单一缓存 |

保留 `raster_cache`（或重命名为 `line_cache`）作为唯一缓存。

#### 2.1.3 待删除的条件编译分支

```rust
// 项目只支持 macOS，以下分支永远不会编译
#[cfg(not(target_os = "macos"))]
```

涉及文件：
- `rio_terminal.rs` 中的 `render_terminal_content` 非 macOS 版本
- `sugarloaf.rs` 中的非 macOS 分支

#### 2.1.4 待删除的调试代码

```rust
const DEBUG_PERFORMANCE: bool = false;

macro_rules! perf_log { ... }
```

大量 `perf_log!` 调用散布各处，虽被禁用但增加代码噪音。

### 2.2 Swift 侧

#### 2.2.1 待删除的类/文件

| 类/文件 | 原因 |
|--------|------|
| `RioTerminalPoolWrapper` | 与 `GlobalTerminalManager` 重复，保留后者 |
| `RioMetalView` 中的渲染方法 | 渲染已移至 Rust，这些是遗留代码 |

#### 2.2.2 RioMetalView 中待删除的方法

```swift
// 以下方法已不再使用，渲染完全在 Rust 侧
private func renderLine(content:, cells:, rowIndex:, snapshot:, isCursorVisible:)
private func isCursorPositionReportLine(_ cells: [FFICell])
private func isInSelection(row:, col:, startRow:, startCol:, endRow:, endCol:)
```

#### 2.2.3 待删除的缓存

```swift
// RioMetalView 中的 snapshot 缓存，已不再使用
private var cachedSnapshots: [Int: TerminalSnapshot] = [:]
private func getCachedSnapshot(terminalId: Int) -> TerminalSnapshot?
private func updateSnapshotCache(for terminalIds: [Int])
```

#### 2.2.4 待简化的协议

```swift
protocol TerminalPoolProtocol {
    // 以下方法已废弃
    func render(terminalId: Int, x: Float, y: Float, ...) -> Bool  // 不再使用
    func flush()                                                    // 空实现
    func readAllOutputs() -> Bool                                   // 事件驱动后不需要
}
```

---

## 3. 目标架构设计

### 3.1 领域划分

```
┌─────────────────────────────────────────────────────────────────┐
│                     Application Layer                            │
│                    (协调者，无业务逻辑)                            │
│                         TerminalApp                              │
└─────────────────────────────────────────────────────────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   Terminal   │    │    Render    │    │  Compositor  │
│    Domain    │    │    Domain    │    │    Domain    │
│              │    │              │    │              │
│  终端逻辑     │    │  渲染逻辑     │    │  合成逻辑     │
│  状态管理     │    │  缓存策略     │    │  布局计算     │
└──────────────┘    └──────────────┘    └──────────────┘
        │                    ▲                    ▲
        │                    │                    │
        └──── State ─────────┘                    │
                             └──── Frame ─────────┘
```

### 3.2 Terminal Domain（终端领域）

**职责**：管理终端状态，处理 PTY I/O

**原则**：不知道渲染的存在，只产出状态

**核心概念**：

| 概念 | 类型 | 说明 |
|------|------|------|
| `Terminal` | 聚合根 | 充血模型，包含所有终端行为 |
| `TerminalState` | 值对象 | 只读快照，跨线程安全 |
| `GridView` | 值对象 | 网格视图，包含行哈希 |
| `RowView` | 值对象 | 行视图，延迟加载 cells |
| `TerminalEvent` | 事件 | Bell, Title, Exit 等 |

**Terminal 聚合根行为**：

| 方法 | 类型 | 说明 |
|------|------|------|
| `tick()` | 命令 | 驱动 PTY，返回事件 |
| `write(data)` | 命令 | 用户输入 |
| `resize(size)` | 命令 | 调整大小 |
| `scroll(delta)` | 命令 | 滚动 |
| `start_selection(pos, kind)` | 命令 | 开始选区 |
| `update_selection(pos)` | 命令 | 更新选区 |
| `clear_selection()` | 命令 | 清除选区 |
| `search(query)` | 命令 | 搜索 |
| `next_match()` / `prev_match()` | 命令 | 导航匹配 |
| `state()` | 查询 | 返回只读状态快照 |
| `row_hash(line)` | 查询 | 快速哈希查询 |
| `selection_text()` | 查询 | 选中文本 |

### 3.3 Render Domain（渲染领域）

**职责**：将 TerminalState 转换为可显示的 Frame

**原则**：不知道终端逻辑，只处理"状态 → 像素"

**核心概念**：

| 概念 | 类型 | 说明 |
|------|------|------|
| `Renderer` | 服务 | 渲染引擎，管理缓存和 Damage Tracking |
| `Frame` | 值对象 | 渲染输出（SkImage） |
| `LineCache` | 内部 | 两层缓存：文本布局 + 最终渲染 |
| `Damage` | 值对象 | 变化信息（哪些行需要重绘） |

**Renderer 行为**：

| 方法 | 说明 |
|------|------|
| `render(state) -> Frame` | 核心渲染方法（自动计算 Damage） |
| `invalidate_cache()` | 清除缓存（字体变化时） |

---

**关键设计：两层 Hash 缓存**

#### 架构思路

**问题**：光标/选区变化导致大范围重绘，但大部分昂贵操作（字体选择、文本整形）与状态无关。

**解决**：分离"昂贵的文本处理"和"轻量的状态绘制"，使用两层缓存。

#### 缓存结构

```rust
LineCache: HashMap<TextHash, LineCacheEntry>

LineCacheEntry {
    layout: GlyphLayout,              // 外层缓存：文本布局
    renders: HashMap<StateHash, SkImage>  // 内层缓存：不同状态组合的最终渲染
}
```

#### 外层 Hash（文本内容）

**Key:** `hash(文本内容 + 样式)`
```rust
text_hash = hash("Hello World" + 前景色 + 背景色 + 粗体/斜体)
```

**Value:** `GlyphLayout`（字体选择 + 文本整形的结果，昂贵操作）

#### 内层 Hash（状态组合，剪枝优化）

**Key:** `hash(影响本行的状态参数)`
```rust
// 只 hash 影响本行渲染的状态（剪枝）
state_hash_for_line = hash(
    if 光标在本行 { cursor_col, cursor_shape },
    if 选区覆盖本行 { selection_range_on_line },
    if 搜索覆盖本行 { search_matches_on_line }
)
```

**关键点：剪枝**
- 光标在第 5 行 → 只有第 5 行的 state_hash 包含光标信息
- 其他行的 state_hash 不变 → 缓存命中
- 光标移动 → 只有旧位置和新位置所在行的 state_hash 变化

**Value:** `SkImage`（最终渲染结果）

---

#### 渲染流程（三级性能）

```rust
fn render_line(line: usize, state: &TerminalState) -> SkImage {
    let text_hash = compute_text_hash(line, state);
    let state_hash = compute_state_hash_for_line(line, state);  // 剪枝

    // Level 1: 检查内层缓存（最快）
    if let Some(image) = cache.get(text_hash, state_hash) {
        return image;  // 🎯 零开销（0%）
    }

    // Level 2: 检查外层缓存（快）
    if let Some(layout) = cache.get_layout(text_hash) {
        // 🎯 跳过字体选择 + 文本整形（70%），只重新绘制状态（30%）
        let image = render_with_layout(layout, line, state);
        cache.insert(text_hash, state_hash, layout, image);
        return image;
    }

    // Level 3: 完全未命中（慢）
    // ⚠️ 完整渲染：字体选择 + 整形 + 绘制（100%）
    let layout = compute_glyph_layout(line, state);  // 昂贵
    let image = render_with_layout(layout, line, state);
    cache.insert(text_hash, state_hash, layout, image);
    return image;
}
```

---

#### 性能收益

| 场景 | 外层命中 | 内层命中 | 耗时 |
|------|---------|---------|------|
| **光标移动** | ✅ | ❌ 2 行 | 2 行 × 30% = 60% |
| | ✅ | ✅ 其他行 | 0% |
| **选区拖动** | ✅ | ❌ N 行 | N 行 × 30% |
| | ✅ | ✅ 其他行 | 0% |
| **文本输入** | ❌ | ❌ 1 行 | 1 行 × 100% |
| **滚动** | ✅ | ✅ 全部 | 0%（全复用）|

**关键优势**：
- **外层命中**：跳过 70% 的昂贵操作（字体处理）
- **内层命中**：跳过 100% 的操作（零开销）
- **剪枝优化**：最大化内层命中率（光标移动只影响 2 行）

**性能提升**：
- 光标移动：传统方案 24 行 × 100% → 新方案 2 行 × 30% = **12 倍提升**
- 选区拖动：传统方案需要重绘所有涉及行 → 新方案跳过 70% 昂贵操作 = **3+ 倍提升**

### 3.4 Compositor Domain（合成领域）

**职责**：将多个终端的 Frame 合成到最终窗口

**原则**：不知道单个终端的细节，只处理布局和合成

**核心概念**：

| 概念 | 类型 | 说明 |
|------|------|------|
| `Compositor` | 服务 | 合成器 |
| `FinalImage` | 值对象 | 最终输出 |

**Compositor 行为**：

| 方法 | 说明 |
|------|------|
| `composite([(Rect, Frame)]) -> FinalImage` | 合成多个终端 |

### 3.5 Application Layer（应用层）

**职责**：协调各领域，处理事件分发

**原则**：无业务逻辑，只做编排

**核心概念**：

| 概念 | 类型 | 说明 |
|------|------|------|
| `TerminalApp` | 应用服务 | 顶层协调器 |
| `AppEvent` | 事件 | 应用级事件 |

**TerminalApp 行为**：

| 方法 | 说明 |
|------|------|
| `tick() -> [AppEvent]` | 驱动所有终端 |
| `render(layouts) -> FinalImage` | 渲染所有终端 |
| `create_terminal() -> TerminalId` | 创建终端 |
| `close_terminal(id)` | 关闭终端 |

### 3.6 目录结构

```
rio/sugarloaf-ffi/src/
├── lib.rs                    # FFI 入口
├── ffi.rs                    # FFI 函数定义
│
├── domain/                   # Terminal Domain
│   ├── mod.rs
│   ├── terminal.rs           # Terminal 聚合根
│   ├── state.rs              # TerminalState, GridView, RowView
│   └── event.rs              # TerminalEvent
│
├── render/                   # Render Domain
│   ├── mod.rs
│   ├── context.rs            # RenderContext
│   ├── frame.rs              # Frame, BaseLayer, Overlay
│   └── cache.rs              # LineCache
│
├── compositor/               # Compositor Domain
│   ├── mod.rs
│   └── compositor.rs         # Compositor
│
└── app/                      # Application Layer
    ├── mod.rs
    └── terminal_app.rs       # TerminalApp
```

### 3.7 复用与重写边界

```
┌───────────────────────────────────────────────────────────────┐
│                         重写                                   │
├───────────────────────────────────────────────────────────────┤
│  Application Layer    │  TerminalApp                          │
│  Terminal Domain      │  Terminal, TerminalState              │
│  Render Domain        │  RenderContext, Frame, Overlay        │
│  Compositor Domain    │  Compositor                           │
├───────────────────────────────────────────────────────────────┤
│                         复用                                   │
├───────────────────────────────────────────────────────────────┤
│  Infrastructure       │  teletypewriter (PTY I/O)             │
│                       │  Crosswords/Grid (核心状态机)          │
│                       │  copa (ANSI parser)                   │
│                       │  Skia primitives (绘制 API)           │
└───────────────────────────────────────────────────────────────┘
```

---

## 4. 重构路径（调整版）

### 调整说明

**顺序调整原因**：
1. **推迟清理工作** - Phase 1-2（死代码清理、Swift 管理层合并）推迟到最后，避免干扰核心重构
2. **先验证架构** - 先实现 Render Domain 验证 Overlay 分离的可行性
3. **数据契约先行** - TerminalState 定义优先于 Terminal 和 Render 的具体实现
4. **独立测试** - Render 和 Terminal 可以用 Mock 数据独立测试

---

### Phase 0: 准备工作 ✅

**目标**：建立基线，确保可回退

**完成情况**：
- [x] 创建 `refactor/ddd-architecture` 分支
- [x] WIP commit（commit: 93dfab4）

---

### Phase 1: 定义核心数据契约 ✅

**目标**：建立领域结构，定义 TerminalState 接口

**为什么先做**：
- TerminalState 是 Terminal Domain 和 Render Domain 的数据契约
- 定义好接口后，两个 Domain 可以并行开发
- 接口定义是纯数据结构，风险低

#### 完成情况

**Commit 1 (59abac4)** - 基础结构：
- [x] 创建新的目录结构（domain/, render/, compositor/, app/）
- [x] 在 Cargo.toml 添加 `new_architecture` feature flag
- [x] 定义 `CursorView` (domain/cursor.rs)
- [x] 定义 `GridView` + `RowView` + `GridData`（Arc 零拷贝，domain/grid.rs）
- [x] 定义 `TerminalState` (domain/state.rs)
- [x] 定义 `Frame` + `BaseLayer` + `Overlay::Cursor` (render/frame.rs)
- [x] 测试：domain 9 passed, render 6 passed

**Commit 2 (40365d0)** - Selection + Search 支持：
- [x] 定义 `SelectionView` (domain/selection.rs)
- [x] 定义 `SearchView` + `MatchRange` (domain/search.rs)
- [x] TerminalState 新增字段：selection, search (Option)
- [x] Overlay 新增变体：Selection, SearchMatch
- [x] 坐标系标注：所有字段改为 absolute_row/absolute_line
- [x] 测试：38 passed (domain: 21, render: 12)

**Commit 3 (15f3912)** - Phantom Type 坐标系统：
- [x] 创建 `domain/point.rs`（GridPoint<T> + Absolute/Screen 标记）
- [x] 重构所有坐标使用 AbsolutePoint（类型安全）
- [x] 删除 SelectionPoint，统一为 AbsolutePoint
- [x] MatchRange 改用 start/end: AbsolutePoint（从 4 个字段 → 2 个字段）
- [x] 测试：41 passed

**文件结构**：
```
src/
├── domain/
│   ├── mod.rs
│   ├── state.rs      - TerminalState
│   ├── cursor.rs     - CursorView
│   ├── grid.rs       - GridView (零拷贝)
│   ├── selection.rs  - SelectionView
│   ├── search.rs     - SearchView
│   └── point.rs      - GridPoint<T> + Phantom Type
├── render/
│   ├── mod.rs
│   └── frame.rs      - Frame (暂时保留，Phase 2 可能重构为 SkImage)
├── compositor/mod.rs (空)
└── app/mod.rs (空)
```

**关键设计成果**：
- ✅ TerminalState 是 Clone 的（Arc 零拷贝）
- ✅ GridView 零拷贝（Arc<GridData> 共享）
- ✅ Phantom Type 坐标系统（编译期类型安全）
- ✅ 所有数据结构已定义并测试通过

---

### Phase 2: 实现 Render Domain

**目标**：实现 State → Frame 的渲染逻辑，验证两层缓存架构

**为什么先做**：
- 两层缓存是架构的核心创新，需要先验证可行性
- Render 是纯函数（state → frame），容易测试
- 缓存策略是性能关键，需要尽早验证

#### Step 1: 定义 RenderContext 和坐标转换（最轻量）

**任务**：
- [ ] 创建 `render/context.rs`
- [ ] 定义 `RenderContext` 结构
  - [ ] display_offset, screen_rows, screen_cols
  - [ ] to_screen_point() 坐标转换
  - [ ] is_visible() 可见性判断
- [ ] 单元测试：坐标转换逻辑

**验收标准**：
- [ ] 坐标转换正确（绝对坐标 ↔ 屏幕坐标）
- [ ] 可见性判断正确

#### Step 2: 定义两层缓存结构（核心）

**任务**：
- [ ] 创建 `render/cache.rs`
- [ ] 定义 `LineCache` 两层结构
  ```rust
  HashMap<TextHash, LineCacheEntry>
  where LineCacheEntry = {
      layout: GlyphLayout,
      renders: HashMap<StateHash, SkImage>
  }
  ```
- [ ] 定义 `GlyphLayout`（字形布局，暂时用 Mock 数据）
- [ ] 实现 `get(text_hash, state_hash) -> CacheResult`
- [ ] 实现 `insert(text_hash, state_hash, layout, image)`
- [ ] 单元测试：缓存插入和查询

**验收标准**：
- [ ] 两层查询正确（外层命中 vs 内层命中 vs 完全未命中）
- [ ] 缓存插入正确

#### Step 3: 实现 Hash 计算（关键：剪枝优化）

**任务**：
- [ ] 实现 `compute_text_hash(line, state)`
  - [ ] 只 hash 文本内容 + 样式（前景色、背景色、粗体等）
  - [ ] 不包含光标/选区/搜索
- [ ] 实现 `compute_state_hash_for_line(line, state)`（剪枝）
  - [ ] 只 hash 影响本行的状态参数
  - [ ] 光标在本行？hash cursor_col + cursor_shape
  - [ ] 选区覆盖本行？hash selection_range_on_line
  - [ ] 搜索覆盖本行？hash search_matches_on_line
- [ ] 单元测试：验证剪枝效果

**验收标准**：
- [ ] text_hash 只依赖文本内容
- [ ] state_hash 只包含影响本行的状态（剪枝）
- [ ] 光标在其他行移动 → 本行的 state_hash 不变

#### Step 4: 实现渲染流程（Mock 版本）

**任务**：
- [ ] 在 `render/renderer.rs` 实现 `Renderer`
- [ ] 实现 `render_line(line, state) -> SkImage`
  - [ ] 计算 text_hash 和 state_hash
  - [ ] 三级缓存查询（内层 → 外层 → 完全未命中）
  - [ ] Mock 版本：用简单数据模拟（真实 Skia 渲染放 Phase 3）
- [ ] 实现 `compute_glyph_layout(line, state) -> GlyphLayout`（Mock）
- [ ] 实现 `render_with_layout(layout, line, state) -> SkImage`（Mock）
- [ ] 单元测试

**验收标准**：
- [ ] 可以用 Mock TerminalState 渲染出 Frame
- [ ] 三级缓存工作正常（Level 1/2/3 都可以测试到）
- [ ] Mock 数据足够验证逻辑

#### Step 5: 关键测试（验证架构）

**任务**：
- [ ] test_two_layer_cache_hit - 验证两层缓存
  - [ ] 首次渲染：完全未命中（100% 耗时）
  - [ ] 光标移动：外层命中（30% 耗时）
  - [ ] 光标回到原位置：内层命中（0% 耗时）
- [ ] test_state_hash_pruning - 验证剪枝优化
  - [ ] 光标在第 5 行
  - [ ] 渲染第 10 行：state_hash 不包含光标信息
  - [ ] 光标移动到第 6 行：第 10 行的 state_hash 不变
- [ ] test_cursor_move_minimal_invalidation - 光标移动最小失效
  - [ ] 24 行可见，光标从第 5 行 → 第 6 行
  - [ ] 只有 2 行需要重绘（第 5、6 行）
  - [ ] 其他 22 行：内层缓存命中
- [ ] test_selection_drag - 选区拖动
  - [ ] 选区覆盖 10 行
  - [ ] 外层缓存命中（跳过字体处理）
  - [ ] 只重新绘制状态（30% 耗时）

**验收标准**：
- [ ] 所有测试通过
- [ ] 缓存行为符合设计预期
- [ ] 性能优化可验证（通过 Mock 数据的计数器）

---

### Phase 3: 实现 Terminal Domain

**目标**：实现 Terminal 聚合根，产出 TerminalState

**任务**：
- [ ] 实现 `Terminal` 聚合根
  - [ ] 封装 Pty（teletypewriter）、Crosswords、Parser（copa）
  - [ ] tick() 方法（驱动 PTY，返回事件）
  - [ ] state() 方法（产出 TerminalState 快照）
  - [ ] write(data) 方法（用户输入）
  - [ ] resize(size) 方法
  - [ ] 光标/选区/搜索/滚动等所有终端行为
- [ ] 实现 Mock PTY（用于测试）
- [ ] 单元测试（用 Mock PTY 喂 ANSI 序列）

**验收标准**：
- [ ] 可以创建 Terminal 实例
- [ ] 可以喂入 ANSI 序列，state() 返回正确的 TerminalState
- [ ] 选区、搜索、滚动等行为正确
- [ ] 所有单元测试通过（不依赖真实 PTY）

**关键测试**：
- [ ] test_ansi_parsing - 喂 ANSI 序列，验证 grid 状态
- [ ] test_search - 搜索功能，验证 SearchView
- [ ] test_selection - 选区功能，验证 SelectionView
- [ ] test_state_snapshot - 验证 state() 产出正确快照

---

### Phase 4: 集成 Terminal + Render

**目标**：验证完整的 Terminal → State → Render → Frame 链路

**任务**：
- [ ] 编写端到端测试
- [ ] 验证各种场景：
  - [ ] 普通文本渲染
  - [ ] 光标移动 + 渲染
  - [ ] 选区 + 渲染
  - [ ] 搜索高亮 + 渲染
  - [ ] 滚动 + 渲染
  - [ ] 缓存有效性

**验收标准**：
- [ ] Terminal 产出的 state 可以被 Render 正确渲染
- [ ] Overlay 正确显示（光标、选区、搜索等）
- [ ] 缓存策略有效（性能可接受）

---

### Phase 5: 实现 Compositor Domain

**目标**：实现多终端合成

**任务**：
- [ ] 实现 `Compositor`
  - [ ] composite([(Rect, Frame)]) -> FinalImage
  - [ ] 合成多个 Terminal 的 Frame 到最终窗口

**验收标准**：
- [ ] 可以合成多个 Frame
- [ ] 布局正确

---

### Phase 6: 实现 Application Layer + FFI

**目标**：实现顶层协调器和 FFI 接口

**任务**：
- [ ] 实现 `TerminalApp`
  - [ ] 管理 Terminal 集合
  - [ ] tick() 驱动所有终端
  - [ ] render(layouts) 渲染所有终端
- [ ] 实现新的 FFI 接口

**验收标准**：
- [ ] FFI 可以从 Swift 调用
- [ ] 功能完整（创建、关闭、输入、渲染）

---

### Phase 7: Swift 侧适配

**目标**：Swift 侧切换到新架构

**任务**：
- [ ] 实现新的 FFI 封装
- [ ] 更新 GlobalTerminalManager
- [ ] 简化 TerminalWindowCoordinator
- [ ] 测试功能完整性

**验收标准**：
- [ ] 新架构功能正常
- [ ] 所有 UI 场景工作正常

---

### Phase 8: 清理旧代码（推迟到最后）

**目标**：删除被替代的代码

**为什么最后做**：
- 新架构已验证可行
- Swift 侧已适配完成
- 可以安全删除旧代码

**Rust 侧清理**：
- [ ] 删除 `rio_terminal.rs`（旧的 RioTerminal/RioTerminalPool）
- [ ] 删除 `rio_machine.rs`（合并到 Terminal）
- [ ] 删除或简化 `rio_event.rs`
- [ ] 删除 `#[cfg(not(target_os = "macos"))]` 分支
- [ ] 删除 `DEBUG_PERFORMANCE` 和 `perf_log!` 宏

**Sugarloaf 清理**：
- [ ] 删除 `fragments_cache`
- [ ] 删除 `layout_cache`
- [ ] 重命名 `raster_cache` 为 `line_cache`

**Swift 侧清理**：
- [ ] 删除 `RioTerminalPoolWrapper`
- [ ] 删除 `RioMetalView` 中废弃的渲染方法
- [ ] 删除 snapshot 缓存相关代码
- [ ] 简化 `TerminalPoolProtocol`

**验收标准**：
- [ ] 编译通过
- [ ] 所有测试通过
- [ ] 功能不变

---

### Phase 9: 性能验证与优化

**目标**：确保新架构性能达标

**任务**：
- [ ] 性能基准测试
- [ ] 对比 Phase 0 的基线
- [ ] 必要的优化

**验收标准**：
- [ ] 渲染性能 >= 旧架构
- [ ] 内存占用合理
- [ ] 缓存命中率 >= 80%

---

## 5. 附录：核心数据流

### 5.1 输入流（用户 → PTY）

```
用户按键
    ↓
Swift: keyDown
    ↓
FFI: terminal_app_write(id, data)
    ↓
TerminalApp.write(id, data)
    ↓
Terminal.write(data)
    ↓
Pty.write(data)
    ↓
Shell 进程
```

### 5.2 输出流（PTY → 屏幕）

```
Shell 进程输出
    ↓
Pty.read()
    ↓
Terminal.tick()
    ├─→ Parser.parse(bytes)
    ├─→ Grid.apply(actions)
    └─→ TerminalEvent[] (Bell, Title, etc.)
    ↓
TerminalApp.tick()
    ↓
AppEvent[] → Swift 处理
```

### 5.3 渲染流（状态 → 像素）

```
CVDisplayLink 触发
    ↓
Swift: requestRender()
    ↓
FFI: terminal_app_render(layouts)
    ↓
TerminalApp.render(layouts)
    │
    ├─→ for each terminal:
    │       Terminal.state() → TerminalState
    │       RenderContext.render(state) → Frame
    │
    └─→ Compositor.composite([(Rect, Frame)])
            ↓
        FinalImage → Metal drawable
            ↓
        屏幕
```

---

## 变更历史

| 日期 | 版本 | 说明 |
|------|------|------|
| 2024-XX-XX | 1.0 | 初始版本 |
