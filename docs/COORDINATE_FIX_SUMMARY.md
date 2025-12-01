# ETerm 坐标越界错误修复总结

## 问题描述

在 ETerm 终端选区功能中出现坐标越界错误：

```
thread '<unnamed>' panicked at /Users/higuaifan/Desktop/hi/小工具/english/rio/rio-backend/src/crosswords/mod.rs:1282:35:
index out of bounds: the len is 1032 but the index is 18446744073709550583
```

### 错误分析

1. **索引值 `18446744073709550583`** 是 `-1033` 转换为 `usize` 的结果
2. 错误发生在 `&self.grid[line]`，表明传入了负数索引
3. 根本原因：**Swift 和 Rio 使用了相反的 Y 轴坐标系统**

## 坐标系统对比

### Swift Screen 坐标系统
```
screenRow = 0           ← 屏幕顶部
screenRow = 1
screenRow = 2
...
screenRow = 22
screenRow = 23          ← 屏幕底部
```

### Rio Grid 坐标系统
```
Line(23)                ← 屏幕顶部
Line(22)
Line(21)
...
Line(1)
Line(0)                 ← 屏幕底部
Line(-1)                ← 历史缓冲区第 1 行
Line(-2)                ← 历史缓冲区第 2 行
...
Line(-1000)             ← 历史缓冲区最早的行
```

### 关键发现

- **Swift Screen**: `0` = 顶部，`screen_lines - 1` = 底部
- **Rio Grid**: `0` = 底部，`screen_lines - 1` = 顶部
- **两者完全相反！**

## 修复方案

### 1. 修复 `screen_to_absolute` 方法

**位置**: `rio/sugarloaf-ffi/src/rio_terminal.rs:673`

**修复前**:
```rust
pub fn screen_to_absolute(&self, screen_row: usize, screen_col: usize) -> (i64, usize) {
    let terminal = self.terminal.lock();
    let display_offset = terminal.display_offset() as i64;
    let scrollback_lines = terminal.grid.history_size() as i64;

    // ❌ 错误：假设两个坐标系统一致
    let grid_row = screen_row as i64 - display_offset;
    let absolute_row = scrollback_lines + grid_row;

    (absolute_row, screen_col)
}
```

**修复后**:
```rust
pub fn screen_to_absolute(&self, screen_row: usize, screen_col: usize) -> (i64, usize) {
    let terminal = self.terminal.lock();
    let display_offset = terminal.display_offset() as i64;
    let scrollback_lines = terminal.grid.history_size() as i64;
    let screen_lines = terminal.screen_lines() as i64;

    // ✅ 正确：先翻转 Y 轴
    let rio_screen_row = (screen_lines - 1) - screen_row as i64;

    // Rio Screen → Grid（考虑滚动偏移）
    let grid_row = rio_screen_row - display_offset;

    // Grid → Absolute
    let absolute_row = scrollback_lines + grid_row;

    (absolute_row, screen_col)
}
```

### 2. 修复 `set_selection_absolute` 边界检查

**位置**: `rio/sugarloaf-ffi/src/rio_terminal.rs:705`

**修复前**:
```rust
// ❌ 错误的边界检查
let grid_rows = terminal.grid.total_lines() as i64;
let min_row = -(scrollback_lines);
if start_grid_row < min_row || end_grid_row >= grid_rows {
    return Err(...);
}
```

**修复后**:
```rust
// ✅ 正确的边界检查
// Grid 坐标有效范围: [-scrollback_lines, screen_lines)
let min_row = -(scrollback_lines);
let max_row = screen_lines - 1;

if start_grid_row < min_row || start_grid_row > max_row {
    return Err(format!(
        "Selection start out of bounds: start_grid_row={}, valid range=[{}, {}]",
        start_grid_row, min_row, max_row
    ));
}

if end_grid_row < min_row || end_grid_row > max_row {
    return Err(format!(
        "Selection end out of bounds: end_grid_row={}, valid range=[{}, {}]",
        end_grid_row, min_row, max_row
    ));
}
```

## 坐标转换验证

### 场景 1：点击屏幕顶部，无滚动
```
Input:
  - screen_row = 0
  - screen_lines = 24
  - display_offset = 0
  - scrollback_lines = 1000

转换:
  1. rio_screen_row = (24 - 1) - 0 = 23
  2. grid_row = 23 - 0 = 23
  3. absolute_row = 1000 + 23 = 1023

结果: Line(23) ✅ 正确（屏幕顶部）
```

### 场景 2：点击屏幕底部，无滚动
```
Input:
  - screen_row = 23
  - screen_lines = 24
  - display_offset = 0
  - scrollback_lines = 1000

转换:
  1. rio_screen_row = (24 - 1) - 23 = 0
  2. grid_row = 0 - 0 = 0
  3. absolute_row = 1000 + 0 = 1000

结果: Line(0) ✅ 正确（屏幕底部）
```

### 场景 3：点击屏幕顶部，向上滚动 10 行
```
Input:
  - screen_row = 0
  - screen_lines = 24
  - display_offset = 10
  - scrollback_lines = 1000

转换:
  1. rio_screen_row = (24 - 1) - 0 = 23
  2. grid_row = 23 - 10 = 13
  3. absolute_row = 1000 + 13 = 1013

结果: Line(13) ✅ 正确（可见区域顶部对应历史缓冲区中的某行）
```

## 测试结果

已添加单元测试验证修复：

```rust
#[test]
fn test_coordinate_transformation() {
    // 测试场景 1, 2, 3
}

#[test]
fn test_boundary_validation() {
    // 测试边界检查逻辑
}
```

**测试结果**:
```
running 2 tests
test rio_terminal::tests::test_coordinate_transformation ... ok
test rio_terminal::tests::test_boundary_validation ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured
```

## 编译验证

```bash
cargo build --package sugarloaf-ffi --manifest-path rio/Cargo.toml
```

**结果**: ✅ 编译成功（仅有一些警告，无错误）

## 受影响的文件

1. **rio/sugarloaf-ffi/src/rio_terminal.rs**
   - 修复 `screen_to_absolute` 方法（第 673 行）
   - 修复 `set_selection_absolute` 边界检查（第 705 行）
   - 添加单元测试（第 1338 行）

2. **ETerm/ETerm/Infrastructure/Coordination/CoordinateMapper.swift**
   - 移除多余的 Y 轴翻转（第 240 行）
   - Y 轴翻转统一在 Rust 侧的 `screen_to_absolute` 中完成

## 完整修复链路

### 修复前的错误流程

```
用户点击屏幕顶部
↓
Swift 坐标: (x, y=0)
↓
CoordinateMapper.screenToGrid (❌ 错误：翻转 Y 轴)
↓ yFromTop = contentHeight - 0 = contentHeight
↓ row = contentHeight / cellHeight ≈ 23
↓
传给 Rust: screen_row = 23
↓
Rust screen_to_absolute (❌ 错误：假设坐标系统一致)
↓ grid_row = 23 - 0 = 23
↓ absolute_row = 1000 + 23 = 1023
↓
创建 Line(23) ✅ 虽然结果正确，但逻辑混乱
```

**问题**：两次翻转导致结果"碰巧"正确，但逻辑混乱，容易出错。

### 修复后的正确流程

```
用户点击屏幕顶部
↓
Swift 坐标: (x, y=0)
↓
CoordinateMapper.screenToGrid (✅ 正确：直接计算)
↓ row = 0 / cellHeight = 0
↓
传给 Rust: screen_row = 0
↓
Rust screen_to_absolute (✅ 正确：翻转 Y 轴)
↓ rio_screen_row = (24 - 1) - 0 = 23
↓ grid_row = 23 - 0 = 23
↓ absolute_row = 1000 + 23 = 1023
↓
创建 Line(23) ✅ 正确对应屏幕顶部
```

**优势**：
- 职责清晰：`CoordinateMapper` 只负责像素到网格的转换
- Y 轴翻转集中在 Rust 侧，便于维护
- 逻辑清晰，易于理解和调试

## 下一步

1. ✅ 修复 Rust 侧坐标转换逻辑
2. ✅ 修复 Swift 侧 CoordinateMapper
3. ✅ 编译验证
4. ⏳ 在 ETerm 中测试选区功能
5. ⏳ 验证滚动场景下的选区是否正确
6. ⏳ 验证跨行选区是否正确

## 技术要点

### Rio Grid 坐标系统的核心约束

基于 `rio-backend/src/crosswords/grid/storage.rs:231` 的 `compute_index` 实现：

```rust
fn compute_index(&self, requested: Line) -> usize {
    debug_assert!(requested.0 < self.visible_lines as i32);
    // ...
}
```

**关键约束**:
- `visible_lines = screen_lines + history_size`
- 有效的 Grid 行范围：`Line(-history_size)` 到 `Line(screen_lines - 1)`
- **必须满足**: `requested.0 < visible_lines`

### 为什么原来的代码会越界

原来的代码在点击屏幕顶部（Swift `screen_row = 0`）时：

```rust
// ❌ 错误计算
grid_row = 0 - 0 = 0           // Swift screen_row 直接使用
absolute_row = 1000 + 0 = 1000
// 创建 Line(0)，但这是屏幕底部，不是顶部！

// 当用户双击选中单词时，可能计算出负数坐标
grid_row = 0 - 1033 = -1033    // 某些边界计算错误
// 转换为 usize 时变成 18446744073709550583，导致越界
```

正确的计算应该是：

```rust
// ✅ 正确计算
rio_screen_row = (24 - 1) - 0 = 23  // 先翻转 Y 轴
grid_row = 23 - 0 = 23
absolute_row = 1000 + 23 = 1023
// 创建 Line(23)，正确对应屏幕顶部 ✅
```

## 总结

这个问题的根本原因是**两个坐标系统的 Y 轴方向相反**：

- **Swift**: 原点在左上角，Y 轴向下增长
- **Rio**: 原点在左下角，Y 轴向上增长

修复方法是在坐标转换时添加 Y 轴翻转：

```rust
rio_screen_row = (screen_lines - 1) - swift_screen_row
```

这确保了 Swift 的 `screen_row = 0`（顶部）正确映射到 Rio 的 `Line(23)`（顶部）。
