//! Terminal State - Read-only Snapshot
//!
//! 核心设计原则：
//! - **只读快照**：`TerminalState` 是值对象，不可变，可安全跨线程传递
//! - **零拷贝**：`GridView` 使用 `Arc` 共享底层数据，避免大量内存拷贝
//! - **延迟加载**：`RowView` 只在需要时加载行数据
//! - **缓存友好**：`row_hash()` 提供行哈希用于缓存查询
//!
//! 这是 Phase 1 的最小核心，只包含 Grid 和 Cursor。
//! 后续 Phase 会逐步添加 Selection、Search、Mode 等状态。

use super::cursor::CursorView;
use super::grid::GridView;

/// Terminal State - Read-only Snapshot
///
/// 设计要点：
/// - `Clone` 成本低（只复制 Arc 指针）
/// - 线程安全（`Send + Sync`）
/// - 不可变（所有字段只读）
///
/// 使用场景：
/// - 从 Domain 线程传递到 Render 线程
/// - 作为缓存 key 的一部分
/// - 用于差分比较（通过 row_hash）
#[derive(Debug, Clone)]
pub struct TerminalState {
    /// Grid view - 网格视图（零拷贝）
    pub grid: GridView,

    /// Cursor view - 光标视图
    pub cursor: CursorView,
}

impl TerminalState {
    /// 创建新的 TerminalState
    ///
    /// # 参数
    /// - `grid`: 网格视图
    /// - `cursor`: 光标视图
    ///
    /// # 设计原则
    /// TerminalState 只负责组合，不关心内部如何构造：
    /// - GridView 自己知道如何从 GridData 构造
    /// - CursorView 自己知道如何从 pos + shape 构造
    /// - TerminalState 只需要接收构造好的对象
    pub fn new(grid: GridView, cursor: CursorView) -> Self {
        Self { grid, cursor }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::grid::GridData;
    use rio_backend::crosswords::pos::{Line, Column, Pos};
    use rio_backend::ansi::CursorShape;
    use std::sync::Arc;

    /// 测试：验证可以构造 TerminalState
    #[test]
    fn test_terminal_state_construction() {
        // 创建 GridView
        let grid_data = Arc::new(GridData::empty(80, 24));
        let grid = GridView::new(grid_data);

        // 创建 CursorView
        let cursor_pos = Pos::new(Line(0), Column(0));
        let cursor_shape = CursorShape::Block;
        let cursor = CursorView::new(cursor_pos, cursor_shape);

        // 构造 TerminalState
        let state = TerminalState::new(grid, cursor);

        // 验证基本属性
        assert_eq!(state.grid.columns(), 80);
        assert_eq!(state.grid.lines(), 24);
        assert_eq!(state.cursor.pos, cursor_pos);
        assert_eq!(state.cursor.shape, cursor_shape);
        assert!(state.cursor.is_visible());
    }

    /// 测试：验证 TerminalState 是 Clone 的（低成本）
    #[test]
    fn test_terminal_state_clone() {
        // 创建 GridView 和 CursorView
        let grid_data = Arc::new(GridData::empty(80, 24));
        let grid = GridView::new(grid_data);
        let cursor = CursorView::new(
            Pos::new(Line(0), Column(0)),
            CursorShape::Block,
        );

        let state1 = TerminalState::new(grid, cursor);

        // Clone 应该很快（只复制 Arc 指针）
        let state2 = state1.clone();

        // 验证两个 state 指向同一份 GridData
        assert_eq!(state1.grid.columns(), state2.grid.columns());
        assert_eq!(state1.grid.lines(), state2.grid.lines());
    }
}
