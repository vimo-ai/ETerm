# ETerm 搜索历史缓冲区功能实现

## 概述

本次实现解决了 ETerm 搜索功能只能搜索屏幕可见区域（约 40 行）的问题，现在可以搜索整个历史缓冲区（scrollback buffer）的数据。

## 问题分析

### 根本原因

原有的 `get_row_cells` 方法只返回 `visible_rows()`，即当前屏幕可见的行，不包括历史缓冲区中的数据。

### 解决方案

新增 `get_row_cells_absolute` 方法，直接通过绝对行号访问 Grid 数据，支持访问历史缓冲区。

## 实现细节

### 1. Rust FFI 接口（核心）

**文件**: `rio/sugarloaf-ffi/src/rio_terminal.rs`

#### 新增方法

```rust
impl RioTerminal {
    /// 获取指定绝对行号的单元格数据（支持历史缓冲区）
    pub fn get_row_cells_absolute(&self, absolute_row: i64) -> Vec<FFICell> {
        // 转换绝对行号到 Grid 行号
        // absolute_row = scrollback_lines + grid_row
        // grid_row = absolute_row - scrollback_lines

        let grid_row = absolute_row - scrollback_lines;

        // 边界检查: Grid 有效范围 [-scrollback_lines, screen_lines - 1]
        if grid_row < -(scrollback_lines) || grid_row > (screen_lines - 1) {
            return Vec::new();
        }

        // 直接访问 grid[Line(grid_row)]
        let line = Line(grid_row as i32);
        let row = &terminal.grid[line];
        // ... 处理单元格数据（颜色、选区等）
    }
}
```

#### FFI 导出函数

```rust
#[no_mangle]
pub extern "C" fn rio_pool_get_row_cells_absolute(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    absolute_row: i64,
    out_cells: *mut FFICell,
    max_cells: usize,
) -> usize {
    // 调用 terminal.get_row_cells_absolute(absolute_row)
    // 将结果写入 out_cells 缓冲区
}
```

### 2. C 头文件声明

**文件**: `ETerm/ETerm/SugarloafBridge.h`

```c
/// 获取指定绝对行号的单元格数据（支持历史缓冲区）
size_t rio_pool_get_row_cells_absolute(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    int64_t absolute_row,
    FFICell* out_cells,
    size_t max_cells
);
```

### 3. Swift 层封装

**文件**: `ETerm/ETerm/Infrastructure/Terminal/GlobalTerminalManager.swift`

```swift
func getRowCellsAbsolute(terminalId: Int, absoluteRow: Int64, maxCells: Int) -> [FFICell] {
    guard let pool = poolHandle else { return [] }

    let cellsPtr = UnsafeMutablePointer<FFICell>.allocate(capacity: maxCells)
    defer { cellsPtr.deallocate() }

    cellsPtr.initialize(repeating: FFICell(), count: maxCells)
    defer { cellsPtr.deinitialize(count: maxCells) }

    let count = rio_pool_get_row_cells_absolute(pool, terminalId, absoluteRow, cellsPtr, maxCells)

    return Array(UnsafeBufferPointer(start: cellsPtr, count: Int(count)))
}
```

### 4. 搜索逻辑调整

**文件**: `ETerm/ETerm/Domain/Services/TerminalSearch.swift`

#### 关键改动

1. **搜索范围扩展**: 从 `0` 到 `scrollback_lines + screen_lines - 1`
2. **使用绝对行号 API**: 调用 `getRowCellsAbsolute` 替代 `getRowCells`
3. **限制搜索行数**: 默认 `maxRows = 1000` 避免性能问题

```swift
func search(
    pattern: String,
    in terminalId: Int,
    caseSensitive: Bool = false,
    maxRows: Int = 1000
) -> [SearchMatch] {
    let scrollbackLines = Int64(snapshot.scrollback_lines)
    let screenLines = Int64(snapshot.screen_lines)

    // 从最旧的历史开始遍历（absoluteRow = 0）
    for absoluteRow in 0..<rowsToSearch {
        let cells = terminalManager.getRowCellsAbsolute(
            terminalId: terminalId,
            absoluteRow: Int64(absoluteRow),
            maxCells: Int(snapshot.columns)
        )
        // ... 搜索匹配
    }
}
```

## 坐标系统说明

### 绝对行号（Absolute Row）

```
0                           : 历史缓冲区最顶部（最旧）
...
scrollback_lines - 1        : 历史缓冲区最底部（最新）
scrollback_lines            : 屏幕第一行（顶部）
...
scrollback_lines + screen_lines - 1 : 屏幕最后一行（底部）
```

### Grid 行号（Grid Row）

Rio 内部使用的坐标系统：

```
-scrollback_lines           : 历史缓冲区顶部
...
-1                          : 历史缓冲区底部
0                           : 屏幕底部
...
screen_lines - 1            : 屏幕顶部
```

### 转换公式

```
绝对行号 → Grid 行号:
grid_row = absolute_row - scrollback_lines

Grid 行号 → 绝对行号:
absolute_row = scrollback_lines + grid_row
```

## 性能优化

1. **限制搜索范围**: 默认最多搜索 1000 行，避免性能问题
2. **异步搜索**: 使用 `searchAsync` 在后台线程执行，不阻塞 UI
3. **边界检查**: 在 Rust 层进行边界检查，避免访问无效内存

## 测试方法

### 1. 生成大量历史数据

```bash
seq 1 1000
```

### 2. 测试搜索历史

1. 滚动到底部（看不到前面的数字）
2. 按 `Cmd+F` 打开搜索
3. 搜索 `"50"`（只在历史缓冲区中）
4. 验证能否找到匹配项

### 3. 预期结果

- 找到所有包含 "50" 的行（50, 150, 250, ...）
- 匹配项使用绝对行号，不随滚动变化
- 可以正确跳转到匹配位置

## 影响范围

### 修改的文件

1. `rio/sugarloaf-ffi/src/rio_terminal.rs`
   - 新增 `RioTerminal::get_row_cells_absolute`
   - 新增 FFI 函数 `rio_pool_get_row_cells_absolute`

2. `ETerm/ETerm/SugarloafBridge.h`
   - 新增 C 函数声明

3. `ETerm/ETerm/Infrastructure/Terminal/GlobalTerminalManager.swift`
   - 新增 `getRowCellsAbsolute` 方法

4. `ETerm/ETerm/Domain/Services/TerminalSearch.swift`
   - 修改 `search` 方法使用绝对行号 API
   - 调整搜索范围和参数

### 向后兼容性

- ✅ 保留原有的 `get_row_cells` 方法
- ✅ 新增方法不影响现有功能
- ✅ 只修改搜索逻辑，其他渲染逻辑不受影响

## 后续优化建议

1. **增量搜索**: 只搜索新增的历史行，避免重复搜索
2. **搜索索引**: 建立倒排索引加速搜索
3. **正则表达式**: 支持正则表达式搜索
4. **搜索结果缓存**: 缓存最近的搜索结果

## 相关文档

- [坐标系统修复总结](./COORDINATE_FIX_SUMMARY.md)
- [选区和搜索重构](./SELECTION_AND_SEARCH_REFACTOR.md)
