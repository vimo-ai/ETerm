# 渲染管线架构

## 数据流

```
PTY (bash)
    │ 流式 bytes
    ▼
┌─────────┐
│  ANSI   │  解析转义序列 (rio-backend)
└────┬────┘
     │ 字符 + 命令
     ▼
┌─────────┐
│  Grid   │  Crosswords 单元格存储
└────┬────┘
     │ AtomicDirtyFlag 触发
     ▼
┌─────────┐
│  State  │  可见区域快照 (O(visible))
└────┬────┘
     │ TerminalState
     ▼
┌─────────┐
│ Render  │  三级缓存渲染
└────┬────┘
     │ Image
     ▼
┌─────────┐
│ Surface │  GPU Surface 复用
└────┬────┘
     │
     ▼
  Screen
```

## 各阶段性能

| 阶段 | 位置 | 耗时 | 缓存 |
|-----|------|------|------|
| PTY→Grid | rio-backend/performer | ~85μs/1KB | - |
| Grid→State | domain/views/grid.rs | **~0.65ms** | AtomicDirtyFlag |
| State→Render | render/renderer.rs | ~4μs/行 | L1/L2/L3 三级缓存 |
| Render→Screen | app/terminal_pool.rs | ~0ms | Surface 复用 |

## 关键优化设计

### 1. AtomicDirtyFlag (无锁脏标记)

```rust
// PTY 线程写入后
entry.dirty_flag.mark_dirty();
self.needs_render.store(true, Ordering::Release);

// 渲染线程检查
if !entry.dirty_flag.is_dirty() {
    return;  // 跳过，无锁
}
```

- PTY 线程：写入后标记 `mark_dirty()`
- 渲染线程：检查 `is_dirty()`，不脏则跳过
- 渲染完成：`check_and_clear()` 清除标记

### 2. 可见区域快照 (O(visible))

```rust
// GridData::from_crosswords()
// 只遍历可见行，不遍历历史
let range = -display_offset..(screen_lines - display_offset);
for line in range {
    // 快照当前可见行
}
```

- 优化前：遍历全部历史 (2001行 = 60ms)
- 优化后：只遍历可见行 (24行 = 0.65ms)
- 提升：**92x**

### 3. TOCTOU 原子操作

```rust
// 单次锁范围内完成 state + reset_damage
let guard = terminal.try_lock()?;
let state = guard.state();
guard.reset_damage();  // 原子
drop(guard);
// 渲染 state（无锁）
```

### 4. 三级渲染缓存

```
render_line(line, state)
    │
    ▼
┌─────────────────────────────────────┐
│ L1: FullHit (text_hash + state_hash)│ → 返回缓存 Image (0 开销)
├─────────────────────────────────────┤
│ L2: LayoutHit (text_hash)           │ → 复用 GlyphLayout，重绘
├─────────────────────────────────────┤
│ L3: Miss                            │ → compute_glyph_layout + 渲染
└─────────────────────────────────────┘
```

- **text_hash**: 行内容 hash
- **state_hash**: cursor/selection/search 状态
- **L1 命中率**: 99%+

### 5. GPU Surface 复用

```rust
struct TerminalSurfaceCache {
    surface: skia_safe::Surface,
    width: u32,
    height: u32,
}

// 尺寸不变时复用，变化时重建
if cache.width == new_width && cache.height == new_height {
    // 复用
} else {
    // 重建
}
```

### 6. FontMetrics 缓存

```rust
// Renderer 内部缓存
pub fn get_font_metrics(&mut self) -> FontMetrics {
    if let Some(cached) = self.cached_metrics {
        if cached.config_key == self.config.cache_key() {
            return cached;  // 缓存命中
        }
    }
    // 重新计算并缓存
}
```

## 锁结构

```
┌─────────────────────────────────────────────────────────────┐
│              TerminalPool (RwLock<HashMap>)                 │
│  位置: app/terminal_pool.rs                                 │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           TerminalEntry                             │   │
│  │  - terminal: Arc<Mutex<Terminal>>                   │   │
│  │  - dirty_flag: Arc<AtomicDirtyFlag>  ← 无锁        │   │
│  │  - surface_cache: Option<TerminalSurfaceCache>      │   │
│  │  - render_cache: Option<TerminalRenderCache>        │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           Terminal (Mutex)                          │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │     Crosswords (RwLock)                     │   │   │
│  │  │  - 屏幕网格                                  │   │   │
│  │  │  - 历史缓冲区                                │   │   │
│  │  │  - PTY 线程直接持有 Arc 引用                 │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 锁获取顺序

```
渲染线程: terminals.read() → terminal.try_lock() → crosswords.read()
PTY 线程: crosswords.write() (直接持有 Arc)
```

- 无死锁：PTY 线程不获取 terminals 锁
- 无阻塞：渲染用 try_lock，失败则跳过

## 线程模型

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  主线程     │     │  PTY 线程   │     │ DisplayLink │
│  (Swift)    │     │  (Rust)     │     │  (渲染)     │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       │  FFI 调用         │                   │
       │──────────────────▶│                   │
       │                   │                   │
       │                   │  mark_dirty()     │
       │                   │──────────────────▶│
       │                   │                   │
       │                   │                   │ is_dirty()?
       │                   │                   │ state()
       │                   │                   │ render()
       │                   │                   │
       │◀──────────────────────────────────────│
       │  needs_render = false                 │
```

## 文件结构

```
src/
├── app/
│   └── terminal_pool.rs    # 多终端管理 + 统一渲染入口
├── domain/
│   ├── aggregates/
│   │   └── terminal.rs     # Terminal 聚合根
│   └── views/
│       └── grid.rs         # GridData 可见区域快照
├── render/
│   ├── renderer.rs         # 三级缓存渲染器
│   └── config.rs           # FontMetrics 缓存
└── infra/
    └── atomic_cache.rs     # AtomicDirtyFlag 等原子缓存
```
