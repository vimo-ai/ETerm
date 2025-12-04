# Partial Damage Rendering Implementation

## Overview
This document describes the implementation of true Partial Damage rendering for the terminal, allowing the off-screen buffer to only redraw changed lines while preserving unchanged content.

## Architecture

### 1. FFI Layer (`sugarloaf-ffi/src/lib.rs`)

#### Added Fields to `SugarloafHandle`:
```rust
pub struct SugarloafHandle {
    // ... existing fields ...

    /// Damaged 行的列表，None = Full damage (macOS only)
    #[cfg(target_os = "macos")]
    damaged_lines: Option<Vec<usize>>,
}
```

#### New FFI Function: `sugarloaf_set_damage`
```rust
pub extern "C" fn sugarloaf_set_damage(
    handle: *mut SugarloafHandle,
    lines_ptr: *const usize,
    lines_count: usize,
)
```

**Purpose**: Set damage information for the current frame before rendering.

**Parameters**:
- `lines_ptr`: Pointer to array of damaged line indices
- `lines_count`: Number of damaged lines (0 = Full damage)

**Behavior**:
- `lines_count == 0` → Full damage (redraw all lines)
- `lines_count > 0` → Partial damage (redraw only specified lines)

#### Modified `sugarloaf_flush_and_render`:
```rust
#[cfg(target_os = "macos")]
{
    // 获取 damage 信息并传递给 render_with_damage
    let damaged = handle.damaged_lines.take(); // take 并重置为 None
    handle.instance.render_with_damage(damaged.as_deref());
}
```

Now correctly passes damage information to the rendering backend.

### 2. Rendering Backend (`sugarloaf/src/sugarloaf.rs`)

#### Modified `render_with_damage`:
The function now implements true partial damage rendering:

**Full Damage** (`damaged_lines == None`):
- Clears entire off-screen surface
- Renders all lines

**Partial Damage** (`damaged_lines == Some(lines)`):
- Only clears damaged line rectangles
- Only renders damaged lines
- Preserves unchanged lines in off-screen buffer

**Key Implementation Details**:
```rust
// 根据 damage 类型处理
let is_full_damage = damaged_lines.is_none();

if is_full_damage {
    // Full damage: 清空整个 off-screen surface
    off_canvas.clear(clear_color);
} else if let Some(lines) = damaged_lines {
    // Partial damage: 只清除 damaged 行的矩形区域
    for &line_idx in lines {
        let y = base_y + (line_idx as f32) * cell_height;
        let rect = skia_safe::Rect::from_xywh(0.0, y, width as f32, cell_height);
        off_canvas.draw_rect(rect, &clear_paint);
    }
}

// 创建 damaged_set 用于快速查找
let damaged_set: Option<std::collections::HashSet<usize>> = damaged_lines.map(|lines| {
    lines.iter().copied().collect()
});

// 渲染循环
for (line_idx, line) in builder_state.lines.iter().enumerate() {
    // 🎯 Partial damage: 只渲染 damaged 行
    if let Some(ref set) = damaged_set {
        if !set.contains(&line_idx) {
            continue; // 跳过未受损的行
        }
    }

    // ... render line ...
}
```

### 3. Terminal Integration (`sugarloaf-ffi/src/rio_terminal.rs`)

#### Re-enabled Damage Tracking:
```rust
// 🎯 重新启用 damage tracking
let (is_full, damaged_line_numbers) = {
    let mut terminal_lock = terminal.terminal.write();
    match terminal_lock.damage() {
        rio_backend::crosswords::TermDamage::Full => (true, Vec::new()),
        rio_backend::crosswords::TermDamage::Partial(iter) => {
            let lines: Vec<usize> = iter.map(|d| d.line).collect();
            (false, lines)
        }
    }
};
```

#### Damage Collection for Multi-Terminal:
```rust
// 🎯 收集所有终端的 damaged 行信息
let mut has_full_damage = false;
let mut all_damaged_lines: Vec<usize> = Vec::new();

// In terminal loop:
if is_full {
    has_full_damage = true;
} else if damaged_count > 0 {
    all_damaged_lines.extend(damaged_line_numbers.iter().copied());
}
```

#### Pass Damage to Sugarloaf:
```rust
// 🎯 设置 damage 信息（macOS only）
#[cfg(target_os = "macos")]
{
    if has_full_damage {
        // Full damage
        crate::sugarloaf_set_damage(self.sugarloaf, std::ptr::null(), 0);
    } else if !all_damaged_lines.is_empty() {
        // Partial damage
        all_damaged_lines.sort_unstable();
        all_damaged_lines.dedup();
        crate::sugarloaf_set_damage(
            self.sugarloaf,
            all_damaged_lines.as_ptr(),
            all_damaged_lines.len(),
        );
    } else {
        // No damage (treat as Full)
        crate::sugarloaf_set_damage(self.sugarloaf, std::ptr::null(), 0);
    }
}

// 统一渲染
crate::sugarloaf_flush_and_render(self.sugarloaf);
```

## Performance Impact

### Expected Performance:

**Full Damage** (resize, scroll):
- Time: ~7ms (unchanged from before)
- All lines rendered

**Partial Damage** (typing, cursor movement):
- Time: ~1-2ms (70-85% reduction)
- Only damaged lines rendered
- Unchanged lines preserved in off-screen buffer

### Key Optimizations:

1. **Minimal Clear**: Only clears damaged line rectangles, not entire surface
2. **Selective Rendering**: Skips unchanged lines entirely
3. **Layout Cache**: Still benefits from existing layout cache (content_hash)
4. **Font Cache**: Reuses font objects across frames

## Testing

### Build Status:
✅ Successfully compiles with only 2 warnings (unused variables)

### Test Scenarios:

1. **Typing Test**:
   - Expected: Partial damage for 1-2 lines
   - Expected render time: 1-2ms

2. **Cursor Movement**:
   - Expected: Partial damage for 2 lines (old + new cursor position)
   - Expected render time: 1-2ms

3. **Scroll**:
   - Expected: Full damage
   - Expected render time: ~7ms

4. **Resize**:
   - Expected: Full damage
   - Expected render time: ~7ms

## Implementation Notes

### Why Not Use Full Clear for Partial Damage?
- Off-screen buffer acts as a persistent cache
- Only clearing damaged regions preserves unchanged content
- This is the key difference that makes partial damage effective

### Multi-Terminal Handling:
- Currently simplifies to single-terminal case
- If any terminal has Full damage → entire frame is Full damage
- Otherwise, collects damaged lines from all terminals
- Future optimization: track per-terminal damage regions

### Borrow Checker Challenges:
- `terminal_lock.damage()` returns iterator borrowing terminal
- Solution: immediately collect damage to `Vec` and release lock
- This avoids lifetime issues while maintaining correctness

## Future Improvements

1. **Per-Terminal Damage Regions**: Track damage per terminal with Y-offset
2. **Damage Coalescing**: Merge adjacent damaged lines into regions
3. **Background Thread Rendering**: Pre-render unchanged content
4. **GPU-Accelerated Blit**: Use Metal/Vulkan for faster blitting

## Files Modified

1. `/Users/higuaifan/Desktop/hi/小工具/english/rio/sugarloaf-ffi/src/lib.rs`
   - Added `damaged_lines` field
   - Added `sugarloaf_set_damage` FFI function
   - Modified `sugarloaf_flush_and_render`

2. `/Users/higuaifan/Desktop/hi/小工具/english/rio/sugarloaf/src/sugarloaf.rs`
   - Implemented true partial damage logic in `render_with_damage`
   - Added selective clearing and rendering
   - Added performance logging for damage type

3. `/Users/higuaifan/Desktop/hi/小工具/english/rio/sugarloaf-ffi/src/rio_terminal.rs`
   - Re-enabled damage tracking
   - Added damage collection for multi-terminal
   - Added `sugarloaf_set_damage` call before rendering

## Conclusion

The Partial Damage rendering system is now fully implemented and ready for testing. The architecture cleanly separates damage tracking (terminal layer), damage aggregation (FFI layer), and selective rendering (Sugarloaf layer), allowing the off-screen buffer to truly act as a persistent cache.
