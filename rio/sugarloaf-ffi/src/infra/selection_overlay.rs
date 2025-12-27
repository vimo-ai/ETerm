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

/// 选区快照（用于渲染）
#[derive(Debug, Clone, Copy)]
pub struct SelectionSnapshot {
    pub start_row: i32,
    pub start_col: u32,
    pub end_row: i32,
    pub end_col: u32,
    pub ty: SelectionType,
}

/// 独立的选区叠加层状态
pub struct SelectionOverlay {
    start: AtomicU64,  // (row << 32) | col
    end: AtomicU64,    // (row << 32) | col | (valid << 63)
    ty: AtomicU8,
    dirty: AtomicBool,
}

impl SelectionOverlay {
    pub fn new() -> Self {
        Self {
            start: AtomicU64::new(0),
            end: AtomicU64::new(0),  // 最高位为 0 表示无效
            ty: AtomicU8::new(SelectionType::Simple as u8),
            dirty: AtomicBool::new(false),
        }
    }

    /// 更新选区（原子操作）
    pub fn update(&self, start_row: i32, start_col: u32, end_row: i32, end_col: u32, ty: SelectionType) {
        // 编码 start: (row << 32) | col
        let start_encoded = ((start_row as u64) << 32) | (start_col as u64);
        self.start.store(start_encoded, Ordering::Release);

        // 编码 end: (row << 32) | col | (valid << 63)
        // 最高位设为 1 表示有效
        let end_encoded = ((end_row as u64) << 32) | (end_col as u64) | (1u64 << 63);
        self.end.store(end_encoded, Ordering::Release);

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

        // 解码 start
        let start_row = (start_encoded >> 32) as i32;
        let start_col = (start_encoded & 0xFFFFFFFF) as u32;

        // 解码 end（清除有效位）
        let end_without_valid = end_encoded & !(1u64 << 63);
        let end_row = (end_without_valid >> 32) as i32;
        let end_col = (end_without_valid & 0xFFFFFFFF) as u32;

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
            end_row,
            end_col,
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
}
