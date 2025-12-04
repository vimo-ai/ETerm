# Phantom Type 坐标系统重构总结

## 概述

成功使用 Phantom Type 模式重构了坐标系统，在编译期区分绝对坐标和屏幕坐标。

## 修改的文件

### 1. 新增文件
- `src/domain/point.rs` - Phantom Type 坐标系统的核心实现

### 2. 修改的文件
- `src/domain/mod.rs` - 添加 point 模块并重新导出类型
- `src/domain/cursor.rs` - 使用 `AbsolutePoint` 替代 `Pos`
- `src/domain/selection.rs` - 使用 `AbsolutePoint` 替代 `SelectionPoint`
- `src/domain/search.rs` - 使用 `AbsolutePoint` 重构 `MatchRange`
- `src/domain/state.rs` - 更新测试以使用新的坐标类型
- `src/render/frame.rs` - 重构 `Overlay` 枚举以使用 `AbsolutePoint`

## 核心设计

### Phantom Type 实现

```rust
use std::marker::PhantomData;

/// 绝对坐标标记（含历史缓冲区）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Absolute;

/// 屏幕坐标标记（当前可见区域）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Screen;

/// 网格坐标点（带坐标系标记）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GridPoint<T> {
    pub line: usize,
    pub col: usize,
    _marker: PhantomData<T>,
}

pub type AbsolutePoint = GridPoint<Absolute>;
pub type ScreenPoint = GridPoint<Screen>;
```

### 零开销抽象

- `PhantomData<T>` 在编译期存在，运行时不占用内存
- `AbsolutePoint` 和 `ScreenPoint` 的内存布局完全相同
- 实现了 `Copy` trait，可以高效复制

### 类型安全

```rust
let abs = AbsolutePoint::new(10, 20);
let screen = ScreenPoint::new(5, 10);

// 编译错误：不同坐标系无法比较
// assert_eq!(abs, screen);
```

## 重构详情

### 1. CursorView

**Before:**
```rust
pub struct CursorView {
    pub pos: Pos,  // rio_backend 类型
    pub shape: CursorShape,
}
```

**After:**
```rust
pub struct CursorView {
    pub position: AbsolutePoint,  // 使用 Phantom Type
    pub shape: CursorShape,
}
```

### 2. SelectionView

**Before:**
```rust
pub struct SelectionPoint {
    pub line: usize,
    pub col: usize,
}

pub struct SelectionView {
    pub start: SelectionPoint,
    pub end: SelectionPoint,
    pub ty: SelectionType,
}
```

**After:**
```rust
#[deprecated(note = "Use AbsolutePoint instead")]
pub type SelectionPoint = AbsolutePoint;  // 兼容性别名

pub struct SelectionView {
    pub start: AbsolutePoint,
    pub end: AbsolutePoint,
    pub ty: SelectionType,
}
```

### 3. MatchRange

**Before:**
```rust
pub struct MatchRange {
    pub start_line: usize,
    pub start_col: usize,
    pub end_line: usize,
    pub end_col: usize,
}
```

**After:**
```rust
pub struct MatchRange {
    pub start: AbsolutePoint,
    pub end: AbsolutePoint,
}
```

### 4. Overlay 枚举

**Before:**
```rust
pub enum Overlay {
    Cursor {
        absolute_row: usize,
        col: usize,
        shape: CursorShape,
    },
    Selection {
        start_absolute_line: usize,
        start_col: usize,
        end_absolute_line: usize,
        end_col: usize,
        ty: SelectionType,
    },
    SearchMatch {
        start_absolute_line: usize,
        start_col: usize,
        end_absolute_line: usize,
        end_col: usize,
        is_focused: bool,
    },
}
```

**After:**
```rust
pub enum Overlay {
    Cursor {
        position: AbsolutePoint,
        shape: CursorShape,
    },
    Selection {
        start: AbsolutePoint,
        end: AbsolutePoint,
        ty: SelectionType,
    },
    SearchMatch {
        start: AbsolutePoint,
        end: AbsolutePoint,
        is_focused: bool,
    },
}
```

## 测试结果

### 测试统计
- **测试总数**: 41 个
- **通过**: 41 个
- **失败**: 0 个
- **新增测试**: 3 个（point.rs）

### 新增测试
1. `test_absolute_point_construction` - 验证绝对坐标构造
2. `test_screen_point_construction` - 验证屏幕坐标构造
3. `test_absolute_point_equality` - 验证坐标相等性

### 更新的测试
- `domain/cursor.rs`: 3 个测试
- `domain/selection.rs`: 5 个测试
- `domain/search.rs`: 6 个测试
- `domain/state.rs`: 3 个测试
- `render/frame.rs`: 15 个测试

## 破坏性变更

### 1. CursorView API 变更

**Before:**
```rust
cursor.pos        // Pos 类型
cursor.line()     // 返回 Line
cursor.column()   // 返回 Column
```

**After:**
```rust
cursor.position   // AbsolutePoint 类型
cursor.line()     // 返回 usize
cursor.col()      // 返回 usize
```

### 2. SelectionView API 变更

**Before:**
```rust
SelectionPoint::new(10, 20)
```

**After:**
```rust
AbsolutePoint::new(10, 20)
```

### 3. MatchRange API 变更

**Before:**
```rust
MatchRange::new(0, 0, 0, 5)
```

**After:**
```rust
MatchRange::new(
    AbsolutePoint::new(0, 0),
    AbsolutePoint::new(0, 5)
)
```

### 4. Overlay API 变更

**Before:**
```rust
Overlay::Cursor {
    absolute_row: 10,
    col: 5,
    shape: CursorShape::Block,
}
```

**After:**
```rust
Overlay::Cursor {
    position: AbsolutePoint::new(10, 5),
    shape: CursorShape::Block,
}
```

## 兼容性处理

### 1. SelectionPoint 别名
```rust
#[deprecated(note = "Use AbsolutePoint instead")]
pub type SelectionPoint = AbsolutePoint;
```

保留了 `SelectionPoint` 作为 `AbsolutePoint` 的别名，标记为 deprecated，以便渐进式迁移。

## 优势

### 1. 编译期类型安全
- 绝对坐标和屏幕坐标无法混用
- 防止坐标系混淆导致的 bug

### 2. 零运行时开销
- `PhantomData<T>` 不占用内存
- `GridPoint<Absolute>` 和 `GridPoint<Screen>` 内存布局相同
- 实现了 `Copy` trait，高效复制

### 3. 代码可读性提升
- 类型名称清晰表达意图
- `AbsolutePoint` vs `ScreenPoint` 一目了然

### 4. API 简化
- 减少字段数量（4个字段 -> 2个字段）
- 更易于构造和使用

## 下一步

### Phase 2 集成点
当实现 `RenderContext` 时，可以添加坐标转换方法：

```rust
impl GridPoint<Absolute> {
    pub fn to_screen(self, display_offset: usize) -> Option<GridPoint<Screen>> {
        if self.line >= display_offset {
            Some(GridPoint::new(
                self.line - display_offset,
                self.col
            ))
        } else {
            None  // 不在可见区域
        }
    }
}

impl GridPoint<Screen> {
    pub fn to_absolute(self, display_offset: usize) -> GridPoint<Absolute> {
        GridPoint::new(
            self.line + display_offset,
            self.col
        )
    }
}
```

## 相关文档

- [PHASE1_STEP1_COMPLETION.md](./PHASE1_STEP1_COMPLETION.md) - Phase 1 Step 1 完成报告
- [PHASE1_STEP1_SUMMARY.md](./PHASE1_STEP1_SUMMARY.md) - Phase 1 Step 1 总结
- [ARCHITECTURE_REFACTOR.md](../ARCHITECTURE_REFACTOR.md) - 整体重构架构文档

## 完成时间

2025-12-04
