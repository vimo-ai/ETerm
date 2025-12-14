# terminals RwLock 使用分析

> 文件: `rio/sugarloaf-ffi/src/app/terminal_pool.rs`
> 更新时间: 2024-12

## 概述

`terminals: RwLock<HashMap<usize, TerminalEntry>>` 是 TerminalPool 的核心数据结构，保护终端映射表的并发访问。

### 涉及的线程

| 线程 | 说明 |
|------|------|
| **主线程** | UI 操作、窗口事件、用户交互 |
| **CVDisplayLink** | 60fps 渲染循环 |
| **PTY 线程** | 每个终端一个，处理 PTY 输出事件 |

---

## 写锁使用 (write / try_write)

| 行号 | 函数 | 锁类型 | 调用线程 | 锁内操作 | 备注 |
|------|------|--------|----------|----------|------|
| 417 | `create_terminal` | `write()` | 主线程 | insert entry | 阻塞，但只在创建时 |
| 472 | `create_terminal_with_cwd` | `write()` | 主线程 | insert entry | 阻塞，但只在创建时 |
| 539 | `destroy_terminal` | `write()` | 主线程 | remove entry | 阻塞，但只在销毁时 |
| 647 | `resize_terminal` | `try_write_for(200μs)` | 主线程 | 更新 entry + `render_state.lock()` | 超时后放入 pending 队列 |
| 1038 | `render_terminal` | `try_write()` | CVDisplayLink | 更新 surface_cache | 非阻塞 |
| 1055 | `render_terminal` | `try_write()` | CVDisplayLink | 渲染 + `renderer.lock()` | 非阻塞 |
| 1251 | `apply_pending_updates` | `try_write()` | CVDisplayLink | 更新 entry | 非阻塞，失败放回队列 |

---

## 读锁使用 (read)

### 简单读取（无嵌套锁）

| 行号 | 函数 | 调用线程 | 锁内操作 |
|------|------|----------|----------|
| 555 | `get_cwd` | 主线程 | `foreground_process_path()` 系统调用 |
| 586 | `get_foreground_process_name` | 主线程 | `foreground_process_name()` 系统调用 |
| 603 | `has_running_process` | 主线程 | `foreground_process_name()` 系统调用 |
| 704 | `input` | 主线程 | `send_input()` channel 发送 |
| 853 | `render_terminal` | CVDisplayLink | 检查 entry.cols/rows |
| 878 | `render_terminal` | CVDisplayLink | 检查 cache_valid |
| 905 | `render_terminal` | CVDisplayLink | clone Arc 引用（快速） |
| 1015 | `render_terminal` | CVDisplayLink | 检查 surface_cache |
| 1105 | `render_terminal` | CVDisplayLink | `dirty_flag.check_and_clear()` |
| 1152 | `end_frame` | CVDisplayLink | 读取 render_cache |
| 1422 | `event_callback` | PTY 线程 | `dirty_flag.mark_dirty()` |
| 1458 | `terminal_count` | 任意 | `.len()` |
| 1465 | `get_terminal_arc` | 任意 | clone Arc |
| 1533 | `get_cursor_cache` | 任意 | clone Arc |
| 1541 | `get_selection_cache` | 任意 | 读原子缓存 |
| 1549 | `get_scroll_cache` | 任意 | 读原子缓存 |
| 1556 | `get_title_cache` | 任意 | 读原子缓存 |

### ⚠️ 危险：读锁内获取其他锁

| 行号 | 函数 | 调用线程 | 危险操作 | 风险等级 |
|------|------|----------|----------|----------|
| **572** | `get_cached_cwd` | 主线程 | `terminals.read()` → `entry.terminal.lock()` | **高** |
| **622** | `is_bracketed_paste_enabled` | 主线程 | `terminals.read()` → `entry.terminal.lock()` | **高** |
| **1476** | `with_terminal` | 任意 | `terminals.read()` → `entry.terminal.lock()` | **高** |
| 721 | `scroll` | 主线程 | `terminals.read()` → `entry.terminal.try_lock()` | 中（非阻塞） |
| 747 | `set_selection` | 主线程 | `terminals.read()` → `entry.terminal.try_lock()` | 中（非阻塞） |
| 770 | `clear_selection` | 主线程 | `terminals.read()` → `entry.terminal.try_lock()` | 中（非阻塞） |
| 790 | `finalize_selection` | 主线程 | `terminals.read()` → `entry.terminal.try_lock()` | 中（非阻塞） |
| 1491 | `try_with_terminal` | 任意 | `terminals.read()` → `entry.terminal.try_lock()` | 中（非阻塞） |

---

## 死锁场景分析

### 场景 1: CVDisplayLink `write()` + 主线程 `read()`

```
时间线:
1. PTY 线程: terminals.read() [持有读锁]
2. CVDisplayLink: terminals.write() [排队等待]
3. parking_lot 写者优先: 阻塞新 reader
4. 主线程: terminals.read() [被阻塞]
5. 如果 PTY 线程在锁内等待主线程持有的资源 → 死锁
```

**解决方案**: CVDisplayLink 中全部使用 `try_write()` 非阻塞

### 场景 2: 嵌套锁顺序不一致

```
线程 A:                          线程 B:
terminals.read()                 terminal.lock()
  → terminal.lock() [等待]         → terminals.write() [等待]

死锁！
```

**解决方案**:
- 统一锁顺序：terminals → terminal
- 或使用 `try_lock()` 避免阻塞

---

## 锁使用原则

### 必须遵守

1. **CVDisplayLink 线程禁止使用阻塞锁**
   - 使用 `try_write()` / `try_read()` 代替 `write()` / `read()`
   - 获取失败时跳过当前帧或放入 pending 队列

2. **避免在读锁内获取其他锁（阻塞方式）**
   - `terminals.read()` 内只能用 `try_lock()`
   - 如必须阻塞，先释放 `terminals` 锁

3. **保持锁顺序一致**
   ```
   terminals → terminal → render_state → renderer
   ```

### 建议

1. 读锁范围尽量小，快速 clone Arc 后释放
2. 写锁操作放入 pending 队列异步处理
3. 使用原子缓存（AtomicCursorCache 等）减少锁竞争

---

## 改进计划

### 已完成

- [x] `render_terminal` 两阶段锁优化（快速获取 Arc 后释放读锁）
- [x] `render_terminal` 中 `write()` 改为 `try_write()`
- [x] `resize_terminal` 使用 `try_write_for()` 带超时
- [x] `render_state` 改为 `Arc<Mutex<...>>` 支持锁外访问

### 待优化

- [ ] `get_cached_cwd` 等函数改为两阶段（先 clone Arc，再在锁外获取 terminal 锁）
- [ ] 考虑将 `TerminalEntry` 整体包装为 `Arc<TerminalEntry>`，进一步减少 `terminals` 锁持有时间
- [ ] 评估是否需要将 resize 操作通过 channel 发送到 CVDisplayLink 线程统一处理
