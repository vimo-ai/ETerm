# ETerm 选区和搜索功能重构设计文档

## 📋 文档概述

**目标**：解决终端滚动时选区和搜索高亮位置错误的问题，并建立统一的坐标系统。

**核心方案**：引入"真实行号"（绝对坐标系统），由 Rust 统一管理终端坐标转换。

---

## 🐛 问题背景

### 已修复的基础问题

1. **选区背景色问题** ✅
   - 问题：选区没有淡蓝色背景，显示为亮度提升
   - 原因：Swift 侧错误地渲染了选区背景
   - 解决：选区背景色由 Rust 在 `get_row_cells` 中渲染

2. **滚动增量错误** ✅
   - 问题：滚动1行实际移动2行，滚动2行实际移动3行
   - 原因：Swift 和 Rust 两侧都调整了选区坐标（双重调整）
   - 解决：删除 Swift 侧滚动时的重新同步代码

### 核心问题

3. **选区不跟随文本滚动** ❌
   - 问题：选中文本后滚动，选区位置固定不动
   - 原因：存储的是 Screen 坐标，滚动时错误地重新同步导致坐标错乱

4. **搜索高亮位置偏移** ❌
   - 问题：搜索后滚动，高亮位置不跟随文本移动
   - 原因：坐标系统混乱，使用了错误的"绝对行号"公式

---

## 🎯 设计目标

1. **坐标系统统一**：建立清晰的坐标转换链路
2. **职责分离**：Swift 处理 UI，Rust 处理终端逻辑
3. **状态自包含**：Swift 侧状态独立，可随时恢复
4. **代码复用**：避免 Swift 和 Rust 重复实现坐标转换

---

## 📐 坐标系统设计

### 三种坐标系统

| 坐标系 | 定义 | 原点 | 特点 | 用途 |
|--------|------|------|------|------|
| **Screen 坐标** | 相对于当前可见区域的行号 | 可见区域第一行 | 随滚动变化 | UI 事件处理 |
| **Grid 坐标** | Rio 的网格坐标系统 | display_offset=0 时的屏幕顶部 | 相对坐标 | Rust 内部渲染 |
| **真实行号（Absolute）** | 相对于历史缓冲区最早一行 | 历史缓冲区第一行 | 稳定不变 | Swift 业务逻辑 |

### 坐标转换公式

```
Screen row → Grid row:
  gridRow = screenRow - displayOffset

Grid row → Absolute row:
  absoluteRow = scrollbackLines + gridRow

Screen row → Absolute row (组合):
  absoluteRow = scrollbackLines - displayOffset + screenRow
```

### 坐标转换示例

```
场景：
- scrollback_lines = 1000（历史缓冲区1000行）
- display_offset = 10（向上滚动了10行）
- screenRow = 5（可见区域第5行）

转换：
gridRow = 5 - 10 = -5（Grid 坐标）
absoluteRow = 1000 + (-5) = 995（真实行号）
```

---

## 🏗️ 架构设计

### 职责划分

```
┌─────────────────────────────────────────────┐
│ Swift - Presentation Layer                  │
│ ─────────────────────────────────────       │
│ • UI 事件处理（鼠标、键盘）                  │
│ • 存储业务状态（真实行号）                   │
│ • 调用 Rust FFI                             │
└─────────────────────────────────────────────┘
                    ↓
         像素坐标、真实行号
                    ↓
┌─────────────────────────────────────────────┐
│ CoordinateMapper - Infrastructure Layer     │
│ ─────────────────────────────────────       │
│ • Y轴翻转（Swift ↔ Rust）                   │
│ • 缩放（逻辑坐标 ↔ 物理坐标）                │
│ • 像素 → Screen row/col                     │
│ • Screen row/col → 像素                     │
└─────────────────────────────────────────────┘
                    ↓
            Screen row/col
                    ↓
┌─────────────────────────────────────────────┐
│ Rust FFI - Coordinate Conversion            │
│ ─────────────────────────────────────       │
│ • Screen → Grid 转换                        │
│ • Grid → Absolute 转换                      │
│ • Screen → Absolute（组合）                 │
│ • Absolute → Grid（设置选区时）             │
└─────────────────────────────────────────────┘
                    ↓
         Grid 坐标、真实行号
                    ↓
┌─────────────────────────────────────────────┐
│ Rust - Terminal Logic                      │
│ ─────────────────────────────────────       │
│ • 终端状态管理                              │
│ • 选区渲染（Grid 坐标）                      │
│ • 搜索实现                                  │
└─────────────────────────────────────────────┘
```

### 不应该在 CoordinateMapper 中实现的功能

❌ **终端特定的坐标转换**（需要终端状态）：
- Screen → Grid（需要 `displayOffset`）
- Grid → Absolute（需要 `scrollbackLines`）

**原因**：
1. 违反单一职责原则
2. 导致依赖倒置（Infrastructure 依赖 Domain）
3. 参数传递复杂
4. 代码重复（Swift 和 Rust 都要实现）

---

## 🔧 FFI 接口设计

### 1. 扩展 TerminalSnapshot

```c
// SugarloafBridge.h

typedef struct {
    size_t display_offset;
    size_t scrollback_lines;  // ← 新增：历史缓冲区行数
    size_t columns;
    size_t screen_lines;
    // ... 其他字段
} TerminalSnapshot;
```

### 2. 新增坐标转换 FFI

```c
/// 绝对坐标（真实行号）
typedef struct {
    int64_t absolute_row;  // 真实行号
    size_t col;            // 列号
} AbsolutePosition;

/// 屏幕坐标 → 真实行号
///
/// 参数：
///   screen_row: 相对于当前可见区域的行号（0-based）
///   screen_col: 列号
/// 返回：
///   真实行号坐标
AbsolutePosition rio_pool_screen_to_absolute(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    size_t screen_row,
    size_t screen_col
);

/// 使用真实行号设置选区
///
/// 参数：
///   start_absolute_row: 起始真实行号
///   start_col: 起始列号
///   end_absolute_row: 结束真实行号
///   end_col: 结束列号
///
/// 注意：Rust 内部会转换为 Grid 坐标
int rio_pool_set_selection_absolute(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    int64_t start_absolute_row,
    size_t start_col,
    int64_t end_absolute_row,
    size_t end_col
);
```

### 3. Rust 实现

```rust
// rio/sugarloaf-ffi/src/rio_terminal.rs

impl RioTerminal {
    /// 屏幕坐标 → 真实行号
    pub fn screen_to_absolute(
        &self,
        screen_row: usize,
        screen_col: usize
    ) -> AbsolutePosition {
        let terminal = self.terminal.lock();

        // 获取终端状态
        let display_offset = terminal.display_offset() as i64;
        let scrollback_lines = terminal.grid().history_size() as i64;

        // Screen → Grid
        let grid_row = screen_row as i64 - display_offset;

        // Grid → Absolute
        let absolute_row = scrollback_lines + grid_row;

        AbsolutePosition {
            absolute_row,
            col: screen_col,
        }
    }

    /// 使用真实行号设置选区
    pub fn set_selection_absolute(
        &self,
        start_absolute_row: i64,
        start_col: usize,
        end_absolute_row: i64,
        end_col: usize
    ) {
        let mut terminal = self.terminal.lock();
        let scrollback_lines = terminal.grid().history_size() as i64;

        // Absolute → Grid
        let start_grid_row = start_absolute_row - scrollback_lines;
        let end_grid_row = end_absolute_row - scrollback_lines;

        // 创建选区（Grid 坐标）
        let start = Pos::new(Line(start_grid_row as i32), Column(start_col));
        let end = Pos::new(Line(end_grid_row as i32), Column(end_col));

        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);

        terminal.selection = Some(selection);
    }
}

// FFI 导出
#[no_mangle]
pub extern "C" fn rio_pool_screen_to_absolute(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    screen_row: usize,
    screen_col: usize,
) -> AbsolutePosition {
    catch_panic!(AbsolutePosition { absolute_row: 0, col: 0 }, {
        if pool.is_null() {
            return AbsolutePosition { absolute_row: 0, col: 0 };
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            terminal.screen_to_absolute(screen_row, screen_col)
        } else {
            AbsolutePosition { absolute_row: 0, col: 0 }
        }
    })
}

#[no_mangle]
pub extern "C" fn rio_pool_set_selection_absolute(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    start_absolute_row: i64,
    start_col: usize,
    end_absolute_row: i64,
    end_col: usize,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            terminal.set_selection_absolute(
                start_absolute_row,
                start_col,
                end_absolute_row,
                end_col
            );
            1
        } else {
            0
        }
    })
}
```

---

## 📝 Swift 实现

### 1. 修改 TextSelection 结构

```swift
// ETerm/Domain/ValueObjects/TextSelection.swift

struct TextSelection {
    /// 起始真实行号
    let startAbsoluteRow: Int64
    let startCol: UInt16

    /// 结束真实行号
    let endAbsoluteRow: Int64
    let endCol: UInt16

    /// 是否激活（用于高亮/灰显）
    let isActive: Bool

    // ... 其他方法
}
```

### 2. 扩展 GlobalTerminalManager

```swift
// ETerm/Infrastructure/Terminal/GlobalTerminalManager.swift

extension GlobalTerminalManager {
    /// 屏幕坐标 → 真实行号
    func screenToAbsolute(
        terminalId: Int,
        screenRow: Int,
        screenCol: Int
    ) -> AbsolutePosition? {
        guard let pool = pool else { return nil }

        let result = rio_pool_screen_to_absolute(
            pool,
            terminalId,
            screenRow,
            screenCol
        )

        return AbsolutePosition(
            absoluteRow: result.absolute_row,
            col: result.col
        )
    }

    /// 使用真实行号设置选区
    func setSelectionAbsolute(
        terminalId: Int,
        startAbsoluteRow: Int64,
        startCol: Int,
        endAbsoluteRow: Int64,
        endCol: Int
    ) -> Bool {
        guard let pool = pool else { return false }

        return rio_pool_set_selection_absolute(
            pool,
            terminalId,
            startAbsoluteRow,
            startCol,
            endAbsoluteRow,
            endCol
        ) != 0
    }
}

/// 真实行号坐标
struct AbsolutePosition {
    let absoluteRow: Int64
    let col: Int
}
```

### 3. 修改鼠标事件处理

```swift
// ETerm/Presentation/Views/RioTerminalView.swift

override func mouseDown(with event: NSEvent) {
    // 1. 获取鼠标位置
    let location = convert(event.locationInWindow, from: nil)

    // 2. 转换为 Screen row/col（通过 CoordinateMapper）
    let screenPos = screenToGrid(location: location, panelId: panelId)

    // 3. 转换为真实行号（通过 Rust FFI）
    guard let absolutePos = coordinator.terminalManager.screenToAbsolute(
        terminalId: Int(terminalId),
        screenRow: Int(screenPos.row),
        screenCol: Int(screenPos.col)
    ) else { return }

    // 4. 存储起始真实坐标
    activeTab.startSelection(
        absoluteRow: absolutePos.absoluteRow,
        col: UInt16(absolutePos.col)
    )
}

override func mouseDragged(with event: NSEvent) {
    // 1-2. 获取当前位置
    let location = convert(event.locationInWindow, from: nil)
    let screenPos = screenToGrid(location: location, panelId: panelId)

    // 3. 转换为真实行号
    guard let absolutePos = coordinator.terminalManager.screenToAbsolute(
        terminalId: Int(terminalId),
        screenRow: Int(screenPos.row),
        screenCol: Int(screenPos.col)
    ) else { return }

    // 4. 更新结束坐标
    activeTab.updateSelection(
        absoluteRow: absolutePos.absoluteRow,
        col: UInt16(absolutePos.col)
    )

    // 5. 同步到 Rust
    if let selection = activeTab.textSelection {
        _ = coordinator.terminalManager.setSelectionAbsolute(
            terminalId: Int(terminalId),
            startAbsoluteRow: selection.startAbsoluteRow,
            startCol: Int(selection.startCol),
            endAbsoluteRow: selection.endAbsoluteRow,
            endCol: Int(selection.endCol)
        )
    }

    // 6. 触发渲染
    requestRender()
}

override func scrollWheel(with event: NSEvent) {
    // ... 滚动逻辑 ...

    // ✅ 不需要重新同步选区！
    // 真实行号不随 display_offset 变化
    // Rust 内部会自动用新的 display_offset 渲染正确位置

    requestRender()
}
```

---

## 🔍 搜索功能实现

### 1. 修改 SearchMatch 结构

```swift
// ETerm/Domain/Services/TerminalSearch.swift

/// 搜索匹配项
struct SearchMatch: Equatable {
    /// 真实行号（绝对坐标）
    let absoluteRow: Int64
    let startCol: Int
    let endCol: Int
    let text: String
}
```

### 2. 修改搜索实现

```swift
func search(
    pattern: String,
    in terminalId: Int,
    caseSensitive: Bool = false,
    maxRows: Int? = nil
) -> [SearchMatch] {
    guard !pattern.isEmpty else { return [] }

    guard let snapshot = terminalManager.getSnapshot(terminalId: terminalId) else {
        return []
    }

    // ✅ 搜索整个历史缓冲区
    let totalHistoryRows = Int(snapshot.scrollback_lines) + Int(snapshot.screen_lines)
    let rowsToSearch = maxRows ?? min(totalHistoryRows, 10000)

    // 记录搜索时的状态
    let scrollbackLines = Int64(snapshot.scrollback_lines)
    let displayOffset = Int64(snapshot.display_offset)

    var matches: [SearchMatch] = []
    let searchPattern = caseSensitive ? pattern : pattern.lowercased()

    // 遍历每一行
    for rowIndex in 0..<rowsToSearch {
        let cells = terminalManager.getRowCells(
            terminalId: terminalId,
            rowIndex: rowIndex,
            maxCells: Int(snapshot.columns)
        )

        guard !cells.isEmpty else { continue }

        // 转换为字符串
        let lineText = cells.map { cell in
            guard let scalar = UnicodeScalar(cell.character) else { return " " }
            return String(Character(scalar))
        }.joined()

        let textToSearch = caseSensitive ? lineText : lineText.lowercased()

        // 查找所有匹配位置
        var searchStartIndex = textToSearch.startIndex
        while let range = textToSearch.range(
            of: searchPattern,
            range: searchStartIndex..<textToSearch.endIndex
        ) {
            let startCol = textToSearch.distance(from: textToSearch.startIndex, to: range.lowerBound)
            let endCol = textToSearch.distance(from: textToSearch.startIndex, to: range.upperBound) - 1
            let matchText = String(lineText[range])

            // ✅ 计算真实行号
            let absoluteRow = scrollbackLines - displayOffset + Int64(rowIndex)

            matches.append(SearchMatch(
                absoluteRow: absoluteRow,
                startCol: startCol,
                endCol: endCol,
                text: matchText
            ))

            searchStartIndex = range.upperBound
        }
    }

    return matches
}
```

### 3. 修改搜索高亮渲染

```swift
// ETerm/Presentation/Views/RioTerminalView.swift

// 在 renderLine 中
if let coordinator = coordinator,
   !coordinator.searchMatches.isEmpty {

    // ✅ 计算当前行的真实行号
    guard let snapshot = coordinator.terminalManager.getSnapshot(terminalId: Int(terminalId)) else {
        continue
    }

    let currentAbsoluteRow = Int64(snapshot.scrollback_lines)
                           - Int64(snapshot.display_offset)
                           + Int64(rowIndex)

    // ✅ 检查是否匹配
    let isInSearchMatch = coordinator.searchMatches.contains { match in
        match.absoluteRow == currentAbsoluteRow &&
        colIndex >= match.startCol &&
        colIndex <= match.endCol
    }

    if isInSearchMatch {
        // 黄色高亮背景
        hasBg = true
        bgR = 1.0
        bgG = 1.0
        bgB = 0.0
        // 黑色前景（确保可读性）
        fgR = 0.0
        fgG = 0.0
        fgB = 0.0
    }
}
```

---

## ✅ 实现检查清单

### Phase 1: FFI 基础设施

- [ ] 1.1 在 `TerminalSnapshot` 中添加 `scrollback_lines` 字段
- [ ] 1.2 实现 `rio_pool_screen_to_absolute` FFI
- [ ] 1.3 实现 `rio_pool_set_selection_absolute` FFI
- [ ] 1.4 在 Rust 中实现 `screen_to_absolute` 方法
- [ ] 1.5 在 Rust 中实现 `set_selection_absolute` 方法

### Phase 2: Swift 数据结构

- [ ] 2.1 修改 `TextSelection` 使用真实行号
- [ ] 2.2 修改 `SearchMatch` 使用真实行号
- [ ] 2.3 在 `GlobalTerminalManager` 中添加 FFI 包装方法
- [ ] 2.4 在 `TerminalTab` 中更新选区管理方法

### Phase 3: 鼠标事件处理

- [ ] 3.1 修改 `mouseDown` 使用 `screenToAbsolute`
- [ ] 3.2 修改 `mouseDragged` 使用 `screenToAbsolute`
- [ ] 3.3 修改 `mouseUp` 处理
- [ ] 3.4 确认 `scrollWheel` 不重新同步选区

### Phase 4: 搜索功能

- [ ] 4.1 修改搜索范围为整个历史缓冲区
- [ ] 4.2 修改搜索结果使用真实行号
- [ ] 4.3 修改搜索高亮渲染逻辑
- [ ] 4.4 更新搜索 UI（显示匹配数量）

### Phase 5: 测试验证

- [ ] 5.1 测试选区背景色（淡蓝色）
- [ ] 5.2 测试滚动精度（1:1）
- [ ] 5.3 测试选区跟随文本滚动
- [ ] 5.4 测试拖拽选区时的边缘滚动
- [ ] 5.5 测试搜索高亮跟随文本滚动
- [ ] 5.6 测试搜索整个历史缓冲区

---

## 🎯 验收标准

### 选区功能

1. ✅ 选中文本显示**淡蓝色背景**（RGB: 76, 127, 204）
2. ✅ 选中文本显示**白色前景**
3. ✅ 向上滚动1行，选区精确移动1行
4. ✅ 向上滚动10行，选区精确移动10行
5. ✅ 选中文本后向上滚动，选区**跟随文本移动**
6. ✅ 选中文本后向下滚动，选区**跟随文本移动**
7. ✅ 鼠标拖拽到底部边缘，自动向下滚动，选区范围**增加**
8. ✅ 鼠标拖拽到顶部边缘，自动向上滚动，选区范围**增加**

### 搜索功能

1. ✅ 按 Cmd+F 打开搜索框
2. ✅ 输入关键词，显示**黄色背景 + 黑色前景**高亮
3. ✅ 显示匹配数量（如"5 个匹配"）
4. ✅ 滚动后，高亮**跟随文本移动**
5. ✅ 搜索范围覆盖**整个历史缓冲区**（不只是可见区域）
6. ✅ 继续输出新内容后，旧的搜索结果仍然有效（只要历史缓冲区未满）

---

## 📊 性能考量

### FFI 调用开销

**鼠标按下/拖拽**：
- 1 次 `screenToAbsolute` FFI 调用（~100-300 纳秒）
- 1 次 `setSelectionAbsolute` FFI 调用（~100-300 纳秒）
- **总计**：~200-600 纳秒/事件

**鼠标拖拽频率**：
- 60-120 Hz（受限于屏幕刷新率）
- 即使每次 600 纳秒，总开销 = 0.072 毫秒/秒 = 0.0072% CPU
- **结论**：完全可忽略

### 搜索性能

**搜索 10000 行**：
- 每行 ~100 个字符
- 总字符数：~1,000,000 字符
- Swift String.range 性能：~1-5 微秒/行
- **预估总耗时**：10-50 毫秒
- **用户体验**：可接受（<100ms）

**优化建议**（如需要）：
- 使用异步搜索（`searchAsync` 方法已存在）
- 显示搜索进度条（搜索大量行时）
- 限制最大搜索行数（当前已限制 10000 行）

---

## 🚨 注意事项

### 1. 历史缓冲区限制

**问题**：当历史缓冲区满了，旧内容被删除时，真实行号会失效。

**示例**：
```
初始状态：
- scrollback_lines = 1000
- 搜索匹配：absoluteRow = 100

输出 2000 行新内容后：
- scrollback_lines = 1000（保持不变，但内容循环覆盖）
- absoluteRow = 100 指向的内容已被删除
```

**解决方案**：
- 这是**预期行为**，旧内容删除后搜索结果失效是合理的
- 可选：在历史缓冲区循环时清除搜索结果

### 2. 性能监控

**建议**：
- 监控 FFI 调用频率（是否有异常高频调用）
- 监控搜索耗时（是否超过 100ms）
- 使用 Instruments 分析性能瓶颈

### 3. 兼容性

**确保**：
- 现有的复制/粘贴功能正常工作
- 双击选中单词功能正常工作
- Cmd+C 复制选中文本功能正常工作

---

## 📚 参考资料

### 相关文件

**Rust 侧**：
- `rio/sugarloaf-ffi/src/rio_terminal.rs` - 终端实现和 FFI
- `rio/rio-backend/src/selection.rs` - 选区实现
- `rio/rio-backend/src/crosswords/pos.rs` - Grid 坐标定义

**Swift 侧**：
- `ETerm/Infrastructure/Coordination/CoordinateMapper.swift` - 坐标映射器
- `ETerm/Domain/Services/TerminalSearch.swift` - 搜索引擎
- `ETerm/Presentation/Views/RioTerminalView.swift` - 终端视图
- `ETerm/Domain/Aggregates/TerminalTab.swift` - Tab 状态管理

### Rio 原始设计

**选区背景渲染**：
- Rio 在 `get_row_cells` 中计算选区背景色
- Swift 只负责渲染，不判断选区逻辑

**坐标系统**：
- Grid 坐标系：`Line(i32)` + `Column(usize)`
- `display_offset` 影响可见区域，不影响 Grid 坐标

---

## 🎉 总结

本设计通过引入"真实行号"（绝对坐标系统）和职责分离，解决了选区和搜索功能的所有核心问题：

1. ✅ **统一坐标系统**：Swift 存储真实行号，Rust 使用 Grid 坐标
2. ✅ **职责清晰**：CoordinateMapper 处理 UI 映射，Rust 处理终端逻辑
3. ✅ **滚动时正确**：真实行号不变，自动跟随文本
4. ✅ **代码复用**：坐标转换逻辑只在 Rust 实现一次
5. ✅ **性能优秀**：FFI 调用开销可忽略

**核心优势**：
- 选区跟随文本滚动 ✅
- 搜索高亮跟随文本滚动 ✅
- 代码清晰易维护 ✅
- 性能无损失 ✅
