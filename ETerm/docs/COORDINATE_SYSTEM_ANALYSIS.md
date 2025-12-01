# ETerm/Rio 坐标系统完整分析

## 问题根因

搜索功能失败的根本原因是 **`screen_to_absolute()` 中的二次 Y 轴翻转**。

## 坐标系统推导（基于工作代码）

### 1. Rio 的 Grid 坐标系统

#### 证据 1: vi_mode.rs (行 119-134)

```rust
// 屏幕顶部
let line = Line(-(term.display_offset() as i32));  // display_offset = 0 时 → Line(0)

// 屏幕底部
let line = Line(-display_offset + term.grid.screen_lines() as i32 - 1);  // → Line(23)
```

**结论**: `Line(0)` 对应屏幕**顶部**，`Line(screen_lines - 1)` 对应屏幕**底部**。

#### 证据 2: visible_rows() 实现 (crosswords/mod.rs:1052-1068)

```rust
pub fn visible_rows(&self) -> Vec<Row<Square>> {
    let start = self.scroll_region.start.0;  // Line(0).0 = 0
    let end = self.scroll_region.end.0;      // Line(24).0 = 24

    for row in start..end {
        visible_rows.push(self.grid[Line(row)].clone());
    }
}
```

- `visible_rows[0]` = `grid[Line(0)]` = 屏幕顶部
- `visible_rows[23]` = `grid[Line(23)]` = 屏幕底部

#### 证据 3: get_row_cells() 的工作代码 (rio_terminal.rs:406-424)

```rust
let row = &visible_rows[row_index];  // row_index 来自 Swift 的 gridPos.row
let grid_row = row_index as i32 - display_offset;
let grid_pos = Pos::new(Line(grid_row), Column(col_idx));
```

这个代码用于**双击选词**功能，**工作正常**。

**推导**:
- Swift 传入 `row_index = 0`
- `display_offset = 0` → `grid_row = 0`
- `Pos = Line(0)` = 屏幕顶部 ✓

**结论**: Swift 的 `screenToGrid()` 返回的 `row = 0` 对应屏幕**顶部**。

### 2. Swift 的 screenToGrid() 实现

#### CoordinateMapper.swift (行 252-263)

```swift
// macOS NSView 坐标系：原点在左下角，Y 向上增长
// - relativeY = 0 表示 Panel 底部
// - relativeY = panelHeight 表示 Panel 顶部

// 终端坐标系：row = 0 表示顶部
// 需要翻转：contentHeight - relativeY
let yFromTop = contentHeight - relativeY
let row = UInt16(max(0, yFromTop / cellHeight))
```

**这个实现是正确的**！
- 用户点击屏幕顶部 → `relativeY` 高 → `yFromTop` 小 → `row = 0` ✓
- 用户点击屏幕底部 → `relativeY` 低 → `yFromTop` 大 → `row = 23` ✓

### 3. 错误的 screen_to_absolute() 实现（已修复）

#### 错误代码（行 684）:

```rust
// ❌ 错误：二次翻转
let rio_screen_row = (screen_lines - 1) - screen_row as i64;
let grid_row = rio_screen_row - display_offset;
```

**问题分析**:
- Swift 已经翻转过了：`screen_row = 0` 对应顶部
- Rust 又翻转一次：`rio_screen_row = 23 - 0 = 23` → 变成底部！
- 结果：所有搜索位置都上下颠倒 ❌

#### 正确代码:

```rust
// ✅ 正确：Swift 已经翻转过，直接使用
let grid_row = screen_row as i64 - display_offset;
let absolute_row = scrollback_lines + grid_row;
```

## 完整的坐标转换链路

```
用户点击屏幕顶部
    ↓
NSView 坐标: (x, high_y)  // 因为原点在左下角
    ↓
CoordinateMapper.screenToGrid():
    yFromTop = contentHeight - relativeY  // 翻转 Y 轴
    row = yFromTop / cellHeight
    → row = 0  // 屏幕顶部
    ↓
Swift → Rust:
    screenToGrid() 返回 CursorPosition(col: x, row: 0)
    ↓
screen_to_absolute():
    grid_row = screen_row - display_offset
    grid_row = 0 - 0 = 0
    ↓
    absolute_row = scrollback_lines + grid_row
    absolute_row = 1000 + 0 = 1000  // 滚动缓冲区后的第一行（屏幕顶部）
    ↓
set_selection_absolute():
    start_grid_row = absolute_row - scrollback_lines
    start_grid_row = 1000 - 1000 = 0
    ↓
    Pos::new(Line(0), Column(x))  // ✓ 正确
```

## 关键发现总结

1. **Rio 的 Line 坐标**：`Line(0)` = 屏幕顶部，`Line(n-1)` = 屏幕底部
2. **Swift 的 screenToGrid**：已经正确翻转 Y 轴，`row = 0` 对应屏幕顶部
3. **Rust 的错误**：`screen_to_absolute` 中多余的翻转导致坐标颠倒
4. **修复方法**：移除 Rust 端的二次翻转

## 修复内容

### 1. rio/sugarloaf-ffi/src/rio_terminal.rs

- 修复 `screen_to_absolute()` 函数
- 移除二次 Y 轴翻转
- 移除所有调试日志

### 2. ETerm/Infrastructure/Coordination/CoordinateMapper.swift

- 移除调试日志
- 保持原有逻辑不变（已经是正确的）

## 验证方法

1. 在终端中输入多行文本
2. 使用 Cmd+F 搜索某个词
3. 点击搜索结果，验证高亮位置是否正确
4. 上下滚动后再搜索，验证滚动偏移处理是否正确

## 相关文件

- `/Users/higuaifan/Desktop/hi/小工具/english/rio/sugarloaf-ffi/src/rio_terminal.rs`
- `/Users/higuaifan/Desktop/hi/小工具/english/ETerm/ETerm/Infrastructure/Coordination/CoordinateMapper.swift`
- `/Users/higuaifan/Desktop/hi/小工具/english/rio/rio-backend/src/crosswords/mod.rs`
- `/Users/higuaifan/Desktop/hi/小工具/english/rio/rio-backend/src/crosswords/vi_mode.rs`
