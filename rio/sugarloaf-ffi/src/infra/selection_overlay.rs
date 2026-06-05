//! SelectionOverlay - 独立选区叠加层
//!
//! 设计原则：
//! - 原子操作，无锁读取
//! - 与 Crosswords 解耦，渲染时直接使用
//! - 只存储渲染所需的边界信息

use std::sync::atomic::{AtomicU64, AtomicU8, AtomicBool, Ordering};

/// 选区类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SelectionType {
    Simple = 0,
    Block = 1,
    Lines = 2,
}

/// Which side of a cell an anchor sits on.
///
/// This is the half-cell precision that lets the boundary cell be excluded:
/// an anchor on the `Left` of a cell does not include that cell when it is the
/// trailing end of the selection, and vice-versa. Ported from the upstream
/// Rio/Alacritty `Side` so the pure-coordinate range resolution can be done
/// lock-free in [`SelectionSnapshot::resolved_range`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Side {
    Left = 0,
    Right = 1,
}

impl Side {
    #[inline]
    fn from_u8(v: u8) -> Self {
        if v & 1 == 0 { Side::Left } else { Side::Right }
    }
}

/// 选区快照（用于渲染）
#[derive(Debug, Clone, Copy)]
pub struct SelectionSnapshot {
    pub start_row: i32,
    pub start_col: u32,
    pub start_side: Side,
    pub end_row: i32,
    pub end_col: u32,
    pub end_side: Side,
    pub ty: SelectionType,
}

/// Inclusive grid range after resolving anchor sides to whole cells.
///
/// `[start_col, end_col]` on each covered row are fully selected, matching what
/// the renderer fills and what `text_in_range` extracts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResolvedRange {
    pub start_row: i32,
    pub start_col: u32,
    pub end_row: i32,
    pub end_col: u32,
}

impl SelectionSnapshot {
    /// Resolve anchor sides into an inclusive whole-cell range.
    ///
    /// Pure coordinate math (no grid access) ported from Rio's `range_simple`,
    /// so it can run lock-free. Orders the two anchors, applies the side rules
    /// (`Left` trailing end drops its cell, `Right` leading end drops its cell,
    /// with wrap at row boundaries), and returns `None` for empty selections.
    ///
    /// `columns` is the grid width, needed for the row-wrap edge cases.
    pub fn resolved_range(&self, columns: u32) -> Option<ResolvedRange> {
        // Order the two anchors so start sits at/above end (top-left first),
        // carrying each anchor's side along with its point.
        let (mut s_row, mut s_col, s_side, mut e_row, mut e_col, e_side) =
            if (self.start_row, self.start_col) <= (self.end_row, self.end_col) {
                (
                    self.start_row, self.start_col, self.start_side,
                    self.end_row, self.end_col, self.end_side,
                )
            } else {
                (
                    self.end_row, self.end_col, self.end_side,
                    self.start_row, self.start_col, self.start_side,
                )
            };

        // Side rules only apply to a Simple selection. Block/Lines (never set by
        // the current mouse path) fall back to the normalized inclusive range.
        if self.ty != SelectionType::Simple {
            return Some(ResolvedRange {
                start_row: s_row,
                start_col: s_col,
                end_row: e_row,
                end_col: e_col,
            });
        }

        // Empty when the anchors are the identical point+side, or two adjacent
        // cells touch right -> left (a zero-width gap between cells).
        let identical = s_row == e_row && s_col == e_col && s_side == e_side;
        let adjacent_right_left = s_side == Side::Right
            && e_side == Side::Left
            && s_row == e_row
            && s_col + 1 == e_col;
        if identical || adjacent_right_left {
            return None;
        }

        // Drop the trailing cell when the selection ends on the left of a cell.
        // `points_differ` is re-evaluated against the (possibly mutated) end, to
        // match the upstream `range_simple` ordering exactly.
        if e_side == Side::Left && (s_row != e_row || s_col != e_col) {
            if e_col == 0 {
                e_col = columns - 1;
                e_row -= 1;
            } else {
                e_col -= 1;
            }
        }

        // Drop the leading cell when the selection starts on the right of a cell.
        if s_side == Side::Right && (s_row != e_row || s_col != e_col) {
            s_col += 1;
            if s_col == columns {
                s_col = 0;
                s_row += 1;
            }
        }

        Some(ResolvedRange {
            start_row: s_row,
            start_col: s_col,
            end_row: e_row,
            end_col: e_col,
        })
    }
}

/// 独立的选区叠加层状态
pub struct SelectionOverlay {
    start: AtomicU64,  // (row << 32) | col
    end: AtomicU64,    // (row << 32) | col | (valid << 63)
    ty: AtomicU8,
    sides: AtomicU8,   // start_side (bit 0) | end_side (bit 1)
    dirty: AtomicBool,
}

impl SelectionOverlay {
    pub fn new() -> Self {
        Self {
            start: AtomicU64::new(0),
            end: AtomicU64::new(0),  // 最高位为 0 表示无效
            ty: AtomicU8::new(SelectionType::Simple as u8),
            // 默认 start=Left, end=Right：整格闭区间，等价于旧的"端点都包含"行为
            sides: AtomicU8::new((Side::Left as u8) | ((Side::Right as u8) << 1)),
            dirty: AtomicBool::new(false),
        }
    }

    /// 更新选区（原子操作）
    ///
    /// 兼容旧调用方：side 默认 start=Left / end=Right（整格闭区间）。
    /// 需要半格精度时用 [`update_with_sides`](Self::update_with_sides)。
    pub fn update(&self, start_row: i32, start_col: u32, end_row: i32, end_col: u32, ty: SelectionType) {
        self.update_with_sides(
            start_row, start_col, Side::Left,
            end_row, end_col, Side::Right,
            ty,
        );
    }

    /// 更新选区，携带半格 side 信息（原子操作）
    pub fn update_with_sides(
        &self,
        start_row: i32,
        start_col: u32,
        start_side: Side,
        end_row: i32,
        end_col: u32,
        end_side: Side,
        ty: SelectionType,
    ) {
        // 编码 start: (row << 32) | col
        let start_encoded = ((start_row as u64) << 32) | (start_col as u64);
        self.start.store(start_encoded, Ordering::Release);

        // 编码 end: (row << 32) | col | (valid << 63)
        // 最高位设为 1 表示有效
        let end_encoded = ((end_row as u64) << 32) | (end_col as u64) | (1u64 << 63);
        self.end.store(end_encoded, Ordering::Release);

        // 编码 sides: start_side (bit 0) | end_side (bit 1)
        let sides_encoded = (start_side as u8) | ((end_side as u8) << 1);
        self.sides.store(sides_encoded, Ordering::Release);

        self.ty.store(ty as u8, Ordering::Release);
        self.dirty.store(true, Ordering::Release);
    }

    /// 清除选区
    pub fn clear(&self) {
        // 将 end 的最高位设为 0，表示无效
        self.end.store(0, Ordering::Release);
        self.dirty.store(true, Ordering::Release);
    }

    /// 读取选区快照（无锁）
    pub fn snapshot(&self) -> Option<SelectionSnapshot> {
        let end_encoded = self.end.load(Ordering::Acquire);

        // 检查有效位（最高位）
        if (end_encoded & (1u64 << 63)) == 0 {
            return None;
        }

        let start_encoded = self.start.load(Ordering::Acquire);
        let ty_u8 = self.ty.load(Ordering::Acquire);
        let sides_u8 = self.sides.load(Ordering::Acquire);

        // 解码 start
        let start_row = (start_encoded >> 32) as i32;
        let start_col = (start_encoded & 0xFFFFFFFF) as u32;

        // 解码 end（清除有效位）
        let end_without_valid = end_encoded & !(1u64 << 63);
        let end_row = (end_without_valid >> 32) as i32;
        let end_col = (end_without_valid & 0xFFFFFFFF) as u32;

        // 解码 sides
        let start_side = Side::from_u8(sides_u8);
        let end_side = Side::from_u8(sides_u8 >> 1);

        // 解码类型
        let ty = match ty_u8 {
            0 => SelectionType::Simple,
            1 => SelectionType::Block,
            2 => SelectionType::Lines,
            _ => SelectionType::Simple,  // 容错
        };

        Some(SelectionSnapshot {
            start_row,
            start_col,
            start_side,
            end_row,
            end_col,
            end_side,
            ty,
        })
    }

    /// 检查并清除脏标记
    pub fn check_and_clear_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    /// 标记为脏（渲染失败时重新标记，确保下帧继续渲染）
    pub fn mark_dirty(&self) {
        self.dirty.store(true, Ordering::Release);
    }

    /// 检查是否脏（不清除）
    pub fn is_dirty(&self) -> bool {
        self.dirty.load(Ordering::Acquire)
    }

    /// 检查是否有有效选区
    pub fn has_selection(&self) -> bool {
        let end_encoded = self.end.load(Ordering::Acquire);
        (end_encoded & (1u64 << 63)) != 0
    }
}

impl Default for SelectionOverlay {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_update_and_snapshot() {
        let overlay = SelectionOverlay::new();

        // 初始状态：无选区
        assert!(!overlay.has_selection());
        assert!(overlay.snapshot().is_none());

        // 更新选区
        overlay.update(10, 5, 20, 15, SelectionType::Simple);

        // 读取快照
        let snapshot = overlay.snapshot();
        assert!(snapshot.is_some());

        let snap = snapshot.unwrap();
        assert_eq!(snap.start_row, 10);
        assert_eq!(snap.start_col, 5);
        assert_eq!(snap.end_row, 20);
        assert_eq!(snap.end_col, 15);
        assert_eq!(snap.ty, SelectionType::Simple);
    }

    #[test]
    fn test_clear() {
        let overlay = SelectionOverlay::new();

        overlay.update(10, 5, 20, 15, SelectionType::Block);
        assert!(overlay.has_selection());

        overlay.clear();
        assert!(!overlay.has_selection());
        assert!(overlay.snapshot().is_none());
    }

    #[test]
    fn test_dirty_flag() {
        let overlay = SelectionOverlay::new();

        // 初始状态不脏
        assert!(!overlay.check_and_clear_dirty());

        // 更新后变脏
        overlay.update(10, 5, 20, 15, SelectionType::Lines);
        assert!(overlay.check_and_clear_dirty());

        // 再次检查应该不脏了
        assert!(!overlay.check_and_clear_dirty());

        // 清除也会变脏
        overlay.clear();
        assert!(overlay.check_and_clear_dirty());
    }

    #[test]
    fn test_selection_types() {
        let overlay = SelectionOverlay::new();

        overlay.update(0, 0, 10, 10, SelectionType::Block);
        assert_eq!(overlay.snapshot().unwrap().ty, SelectionType::Block);

        overlay.update(0, 0, 10, 10, SelectionType::Lines);
        assert_eq!(overlay.snapshot().unwrap().ty, SelectionType::Lines);

        overlay.update(0, 0, 10, 10, SelectionType::Simple);
        assert_eq!(overlay.snapshot().unwrap().ty, SelectionType::Simple);
    }

    #[test]
    fn test_mark_dirty() {
        let overlay = SelectionOverlay::new();

        // 初始状态不脏
        assert!(!overlay.is_dirty());

        // mark_dirty 设置脏标记
        overlay.mark_dirty();
        assert!(overlay.is_dirty());

        // check_and_clear_dirty 返回 true 并清除
        assert!(overlay.check_and_clear_dirty());
        assert!(!overlay.is_dirty());

        // 再次 mark_dirty
        overlay.mark_dirty();
        assert!(overlay.is_dirty());
    }

    #[test]
    fn test_render_skip_recovery() {
        // 模拟渲染跳过后重新标记的场景
        let overlay = SelectionOverlay::new();

        // 1. 更新选区，标记为脏
        overlay.update(10, 5, 20, 15, SelectionType::Simple);
        assert!(overlay.is_dirty());

        // 2. 渲染开始前检查并清除脏标记（模拟 render_terminal 开头的行为）
        let sel_dirty_cleared = overlay.check_and_clear_dirty();
        assert!(sel_dirty_cleared);
        assert!(!overlay.is_dirty());

        // 3. 模拟渲染被跳过（try_lock 失败等），重新标记脏
        if sel_dirty_cleared {
            overlay.mark_dirty();
        }

        // 4. 验证脏标记被恢复，下一帧会继续渲染
        assert!(overlay.is_dirty());
        assert!(overlay.check_and_clear_dirty());
    }

    // ===== Side encoding (Cycle A) =====

    #[test]
    fn update_defaults_to_left_right_sides() {
        let overlay = SelectionOverlay::new();
        overlay.update(1, 2, 3, 4, SelectionType::Simple);

        let snap = overlay.snapshot().unwrap();
        assert_eq!(snap.start_side, Side::Left);
        assert_eq!(snap.end_side, Side::Right);
    }

    #[test]
    fn update_with_sides_roundtrips() {
        let overlay = SelectionOverlay::new();
        overlay.update_with_sides(
            1, 2, Side::Right,
            3, 4, Side::Left,
            SelectionType::Simple,
        );

        let snap = overlay.snapshot().unwrap();
        assert_eq!(snap.start_side, Side::Right);
        assert_eq!(snap.end_side, Side::Left);
        // 坐标不受 side 编码影响
        assert_eq!((snap.start_row, snap.start_col), (1, 2));
        assert_eq!((snap.end_row, snap.end_col), (3, 4));
    }

    // ===== resolved_range (Cycle B) =====
    //
    // Cases ported from the upstream Rio/Alacritty selection tests so the
    // pure-coordinate port stays faithful. Grid pictograms: each [  ] is a
    // cell, B/E are begin/end anchors.

    fn snap(
        start_row: i32,
        start_col: u32,
        start_side: Side,
        end_row: i32,
        end_col: u32,
        end_side: Side,
    ) -> SelectionSnapshot {
        SelectionSnapshot {
            start_row,
            start_col,
            start_side,
            end_row,
            end_col,
            end_side,
            ty: SelectionType::Simple,
        }
    }

    /// [BE] — single cell, left-to-right.
    #[test]
    fn resolved_single_cell_left_to_right() {
        let s = snap(0, 0, Side::Left, 0, 0, Side::Right);
        assert_eq!(
            s.resolved_range(2),
            Some(ResolvedRange { start_row: 0, start_col: 0, end_row: 0, end_col: 0 })
        );
    }

    /// [EB] — single cell, right-to-left (anchors reversed, still one cell).
    #[test]
    fn resolved_single_cell_right_to_left() {
        let s = snap(0, 0, Side::Right, 0, 0, Side::Left);
        assert_eq!(
            s.resolved_range(2),
            Some(ResolvedRange { start_row: 0, start_col: 0, end_row: 0, end_col: 0 })
        );
    }

    /// [ B][E ] — anchors straddle the gap between two cells: nothing selected.
    #[test]
    fn resolved_between_adjacent_cells_left_to_right_is_empty() {
        let s = snap(0, 0, Side::Right, 0, 1, Side::Left);
        assert_eq!(s.resolved_range(2), None);
    }

    /// [ E][B ] — same gap, reversed drag: still empty.
    #[test]
    fn resolved_between_adjacent_cells_right_to_left_is_empty() {
        let s = snap(0, 1, Side::Left, 0, 0, Side::Right);
        assert_eq!(s.resolved_range(2), None);
    }

    /// Selection ending on the right of a cell on the next line: the leading
    /// cell is dropped (start col +1), final cell kept.
    ///
    /// [  ][ B][XX][XX][XX]
    /// [XX][XE][  ][  ][  ]
    #[test]
    fn resolved_across_lines_leading_cell_exclusive() {
        let s = snap(0, 1, Side::Right, 1, 1, Side::Right);
        assert_eq!(
            s.resolved_range(5),
            Some(ResolvedRange { start_row: 0, start_col: 2, end_row: 1, end_col: 1 })
        );
    }

    /// Trailing end on the `Left` of the first column wraps the exclusive
    /// boundary back to the last column of the previous row.
    #[test]
    fn resolved_end_left_at_col0_wraps_to_prev_row() {
        let s = snap(0, 1, Side::Left, 1, 0, Side::Left);
        assert_eq!(
            s.resolved_range(5),
            Some(ResolvedRange { start_row: 0, start_col: 1, end_row: 0, end_col: 4 })
        );
    }

    /// Production "fixed sides" path (start=Left, end=Right) must keep both
    /// boundary cells: a fully-inclusive range, matching legacy behavior.
    #[test]
    fn resolved_default_sides_are_fully_inclusive() {
        let s = snap(0, 1, Side::Left, 0, 3, Side::Right);
        assert_eq!(
            s.resolved_range(5),
            Some(ResolvedRange { start_row: 0, start_col: 1, end_row: 0, end_col: 3 })
        );
    }
}
