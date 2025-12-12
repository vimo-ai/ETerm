# State 快照优化

## 问题

当前 `state()` 每帧调用，耗时与历史行数线性相关：

| 场景 | 行数 | state() 耗时 | 占帧时间 |
|-----|------|-------------|---------|
| 小终端无历史 | 24 | 1.2ms | 11.7% |
| 大终端无历史 | 200 | 19ms | 96.2% |
| 大终端+历史 | 2001 | **60ms** | **99.6%** |

**每行约 30μs**，历史越多越慢。

原因：遍历全部历史 + 屏幕行，而 L2 缓存命中率 99%+，大部分快照是浪费。

## 优化方案

### 方案 1：延迟快照 (Lazy Snapshot)

```
现在：
state() → hash → L2 检测 → 99% 命中（白做了 state）

优化后：
轻量检测（damage flag）→ 没变化？→ 直接返回缓存
                              ↓ 有变化
                           state() → 渲染
```

预期收益：99% 帧跳过 state()

### 方案 2：只快照可见区域

```rust
// 现在
let total_lines = grid.total_lines();  // 1024 行

// 优化后
let visible_lines = grid.screen_lines();  // 24 行
```

位置：`GridData::from_crosswords()` (grid.rs:385)

预期收益：数据量减少 ~40 倍

### 方案 3：利用 LineDamage 增量更新

**发现：Crosswords 已有完整的 LineDamage 机制，但我们没用！**

```rust
// Crosswords 已有
pub fn damage(&mut self) -> TermDamage<'_> {
    TermDamage::Full           // 全量脏（清屏等）
    TermDamage::Partial(iter)  // 只有某些行脏
}

// 每次写入自动标记
self.damage.damage_line(line);
```

现在 `from_crosswords` 完全无视 damage，每次全量遍历 + 重算 hash。

```rust
// 优化后
let damage = crosswords.damage();
match damage {
    TermDamage::Full => {
        // 全量转换
    }
    TermDamage::Partial(damaged_lines) => {
        // 只转换脏行，其他复用上一帧的 RowData
        for line in damaged_lines {
            cached_rows[line] = convert_row(line);
        }
    }
}
```

预期收益：普通场景只更新 1-3 行，而非 24+ 行

## 预期效果

### 有历史场景 (2001行)

| 场景 | 现在 | 方案1 | 方案2 | 方案1+2 |
|-----|------|-------|-------|--------|
| 无变化帧 | 60ms | ~0ms | 1.5ms | ~0ms |
| 有变化帧 | 60ms | 60ms | 1.5ms | 1.5ms |
| FPS 上限 | 16 | 16~∞ | 666 | 666~∞ |

- **方案 1**: 无变化时跳过 state()
- **方案 2**: 只快照可见行 (50行 vs 2001行)
- **方案 1+2**: 组合效果最佳

### 加上方案 3 (LineDamage)

假设单行更新场景：

| 场景 | 现在 | 全部优化后 |
|-----|------|----------|
| 单行变化 | 60ms (遍历2001行) | ~30μs (只处理1行) |
| 性能提升 | - | **2000x** |

## 实现难点

- 延迟快照需要可靠的 damage 检测机制
- 需要处理滚动场景（display_offset 变化时需要访问历史）

## 优先级

基于 benchmark 数据，推荐实现顺序：

1. **方案 2（可见区域）** - 最简单，立竿见影
   - 改动：`from_crosswords()` 只遍历 `screen_lines` 而非 `total_lines`
   - 效果：2001行 → 50行，40x 提升
   - 风险：需处理滚动时的历史访问

2. **方案 1（延迟快照）** - 中等复杂度
   - 改动：state() 前检查 damage flag
   - 效果：99% 帧跳过 state()
   - 依赖：需要可靠的 damage 检测

3. **方案 3（LineDamage）** - 最复杂但效果最好
   - 改动：增量更新脏行，缓存非脏行
   - 效果：单行更新 2000x 提升
   - 依赖：需要维护行缓存

## 锁的必要性问题

### 当前锁获取流程（render_terminal）

```
1. terminal.try_lock()        ← Terminal Mutex
2.   is_damaged()
3.     crosswords.read()      ← Crosswords RwLock
4.     检查 damage
5.     释放
6. 释放 Terminal Mutex

7. terminal.try_lock()        ← 再获取 Terminal Mutex
8.   state()
9.     crosswords.read()      ← 再获取 Crosswords RwLock (60ms!)
10.    构建快照
11.    释放
12. 释放 Terminal Mutex

总计: 4 次锁获取（2×Mutex + 2×RwLock）
```

### 不必要的锁

| 数据 | 当前 | 需要锁？ | 替代方案 |
|-----|------|---------|---------|
| damage flag | Crosswords RwLock | ❌ | AtomicDirtyFlag（已实现但未使用！）|
| cursor | Terminal Mutex | ❌ | AtomicCursorCache（已用）|
| selection | Terminal Mutex | ❌ | AtomicSelectionCache（已用）|
| Grid 快照 | Crosswords RwLock | ✅ | 必须，但可缩短时间 |

### 问题

**AtomicDirtyFlag 已实现，但 TerminalEntry 没有使用！**

```rust
// 当前 TerminalEntry 有:
cursor_cache: Arc<AtomicCursorCache>,     ✅
selection_cache: Arc<AtomicSelectionCache>, ✅
scroll_cache: Arc<AtomicScrollCache>,     ✅
title_cache: Arc<AtomicTitleCache>,       ✅

// 但缺少:
dirty_flag: Arc<AtomicDirtyFlag>,         ❌ 没有！
```

### 优化方案：使用 AtomicDirtyFlag

```rust
// PTY 线程写入后:
entry.dirty_flag.mark_dirty();  // 无锁

// 渲染线程检查:
if !entry.dirty_flag.is_dirty() {  // 无锁
    return; // 跳过，不需要获取任何锁
}

// 只有 dirty 时才获取锁:
let state = terminal.lock().state();
entry.dirty_flag.clear();
```

预期效果：99% 帧完全无锁

## 状态

- [ ] 方案 0：使用 AtomicDirtyFlag 避免锁 ← **最简单，立即可做**
- [ ] 方案 1：延迟快照
- [ ] 方案 2：可见区域快照 ← **推荐先做**
- [ ] 方案 3：利用 LineDamage 增量更新
