# 终端选择坐标系统调试日志

## 问题描述

滚动后选择文本出现坐标越界错误：`index out of bounds: the len is 1032 but the index is 18446744073709550583`

索引 `18446744073709550583` = `-1033` 转为 `usize`，说明坐标转换出现了严重错误。

## 根本原因分析

### macOS 坐标系统

macOS NSView 的坐标系统：
- **原点在左下角**
- **Y 轴向上增长**（与常见的图形系统不同）

### 之前的错误假设

`CoordinateMapper.swift` 的注释错误地写着：
```swift
// Swift Screen 坐标：Y 向下增长，原点在左上角  ❌ 错误！
let row = UInt16(max(0, relativeY / cellHeight))  // 直接计算，没有翻转
```

这导致 Swift 传给 Rust 的 `screen_row` 是**倒置的**：
- 点击顶部时，`relativeY` 很大（接近 panelHeight）
- `row = relativeY / cellHeight` 得到很大的值（比如 23）
- Rust 再次翻转：`rio_screen_row = (24 - 1) - 23 = 0`

这在**不滚动**时恰好正确（负负得正），但滚动后就会出错。

## 修复方案

### 1. 修复 `CoordinateMapper.screenToGrid`

```swift
// 修复前（错误）
let col = UInt16(max(0, relativeX / cellWidth))
let row = UInt16(max(0, relativeY / cellHeight))  // ❌ 没有翻转

// 修复后（正确）
let contentHeight = panelHeight - 2 * padding
let yFromTop = contentHeight - relativeY  // ✅ Y 轴翻转
let col = UInt16(max(0, relativeX / cellWidth))
let row = UInt16(max(0, yFromTop / cellHeight))
```

### 2. 添加调试日志

#### Swift 端 (`CoordinateMapper.swift`)

```swift
print("[CoordinateMapper.screenToGrid]")
print("  screenPoint: (\(screenPoint.x), \(screenPoint.y))")
print("  panelOrigin: (\(panelOrigin.x), \(panelOrigin.y)), panelHeight: \(panelHeight)")
print("  relativeX: \(relativeX), relativeY: \(relativeY)")
print("  contentHeight: \(contentHeight), yFromTop: \(yFromTop)")
print("  cellWidth: \(cellWidth), cellHeight: \(cellHeight)")
print("  col: \(col), row: \(row)")
```

#### Rust 端 (`rio_terminal.rs`)

```rust
// screen_to_absolute
eprintln!("[screen_to_absolute] screen_row={}, screen_col={}", screen_row, screen_col);
eprintln!("  display_offset={}, scrollback_lines={}, screen_lines={}",
    display_offset, scrollback_lines, screen_lines);
eprintln!("  rio_screen_row={}, grid_row={}, absolute_row={}",
    rio_screen_row, grid_row, absolute_row);

// set_selection_absolute
eprintln!("[set_selection_absolute] start_abs={}, start_col={}, end_abs={}, end_col={}",
    start_absolute_row, start_col, end_absolute_row, end_col);
eprintln!("  scrollback_lines={}, screen_lines={}",
    scrollback_lines, screen_lines);
eprintln!("  start_grid_row={}, end_grid_row={}",
    start_grid_row, end_grid_row);
eprintln!("  valid range: [{}, {}]", min_row, max_row);
eprintln!("  Creating selection: start=Line({}),Col({}), end=Line({}),Col({})",
    start_grid_row, start_col, end_grid_row, end_col);
```

## 测试步骤

1. **编译 Rust 库**：
   ```bash
   cd rio
   cargo build --package sugarloaf-ffi --release
   cp target/release/libsugarloaf_ffi.a ../ETerm/libsugarloaf_ffi.a
   ```

2. **在 Xcode 中重新编译并运行 ETerm**

3. **执行测试操作**：
   - 打开终端
   - 输入一些文本产生滚动（例如运行 `seq 1 100`）
   - 向上滚动查看历史内容
   - 尝试选择文本（单击拖拽或双击）

4. **查看控制台日志**：
   - Xcode 控制台会显示 Swift 端的 `print` 输出
   - macOS 控制台（Console.app）会显示 Rust 端的 `eprintln!` 输出

## 预期日志输出

### 正常情况（修复后）

```
[CoordinateMapper.screenToGrid]
  screenPoint: (100.0, 500.0)
  panelOrigin: (0.0, 0.0), panelHeight: 800.0
  relativeX: 100.0, relativeY: 500.0
  contentHeight: 800.0, yFromTop: 300.0
  cellWidth: 16.8, cellHeight: 33.6
  col: 5, row: 8

[screen_to_absolute] screen_row=8, screen_col=5
  display_offset=10, scrollback_lines=1000, screen_lines=24
  rio_screen_row=15, grid_row=5, absolute_row=1005

[set_selection_absolute] start_abs=1005, start_col=5, end_abs=1005, end_col=10
  scrollback_lines=1000, screen_lines=24
  start_grid_row=5, end_grid_row=5
  valid range: [-1000, 23]
  Creating selection: start=Line(5),Col(5), end=Line(5),Col(10)
```

### 异常情况（需要报告）

如果仍然出现越界错误，日志会显示：
- `absolute_row` 是否合理（应该在 0 到 scrollback_lines + screen_lines 之间）
- `grid_row` 是否合理（应该在 -scrollback_lines 到 screen_lines - 1 之间）

## 坐标转换链路图

```
用户点击屏幕
    ↓
macOS 原始坐标 (NSEvent.locationInWindow)
    ↓ RioMetalView.convert()
Swift View 坐标 (原点=左下角，Y向上)
    ↓ CoordinateMapper.screenToGrid()
Terminal Screen 坐标 (row=0 表示顶部) ✅ 修复点
    ↓ rio_pool_screen_to_absolute()
Absolute Row (真实行号，考虑滚动和历史缓冲区)
    ↓ rio_pool_set_selection_absolute()
Grid 坐标 (Rio 内部坐标系统)
    ↓
Selection 对象
```

## 关键修复点

**问题**：`CoordinateMapper.screenToGrid` 没有考虑 macOS 的坐标系统特性

**修复**：
```swift
// macOS: relativeY = 0 表示底部，relativeY = panelHeight 表示顶部
// Terminal: row = 0 表示顶部
// 所以需要翻转：yFromTop = contentHeight - relativeY
```

## 下一步

1. 运行测试，收集日志
2. 验证坐标转换是否正确
3. 如果仍有问题，根据日志分析下一步修复方向
