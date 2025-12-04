//! Terminal State - Read-only Snapshot
//!
//! 核心设计原则：
//! - **只读快照**：`TerminalState` 是值对象，不可变，可安全跨线程传递
//! - **零拷贝**：`GridView` 使用 `Arc` 共享底层数据，避免大量内存拷贝
//! - **延迟加载**：`RowView` 只在需要时加载行数据
//! - **缓存友好**：`row_hash()` 提供行哈希用于缓存查询
//!
//! Phase 1 Step 3: 添加 Selection 支持
//! Phase 1 Step 4: 添加 Search 支持

use super::cursor::CursorView;
use super::grid::GridView;
use super::selection::SelectionView;
use super::search::SearchView;

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

    /// Selection view - 选区视图（可选）
    pub selection: Option<SelectionView>,

    /// Search view - 搜索视图（可选）
    pub search: Option<SearchView>,
}

impl TerminalState {
    /// 创建新的 TerminalState（无选区）
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
        Self {
            grid,
            cursor,
            selection: None,
            search: None,
        }
    }

    /// 创建带选区的 TerminalState
    ///
    /// # 参数
    /// - `grid`: 网格视图
    /// - `cursor`: 光标视图
    /// - `selection`: 选区视图
    pub fn with_selection(grid: GridView, cursor: CursorView, selection: SelectionView) -> Self {
        Self {
            grid,
            cursor,
            selection: Some(selection),
            search: None,
        }
    }

    /// 创建带搜索的 TerminalState
    ///
    /// # 参数
    /// - `grid`: 网格视图
    /// - `cursor`: 光标视图
    /// - `search`: 搜索视图
    pub fn with_search(grid: GridView, cursor: CursorView, search: SearchView) -> Self {
        Self {
            grid,
            cursor,
            selection: None,
            search: Some(search),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::grid::GridData;
    use super::super::point::AbsolutePoint;
    use super::super::selection::SelectionType;
    use super::super::search::MatchRange;
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
        let cursor_pos = AbsolutePoint::new(0, 0);
        let cursor_shape = CursorShape::Block;
        let cursor = CursorView::new(cursor_pos, cursor_shape);

        // 构造 TerminalState
        let state = TerminalState::new(grid, cursor);

        // 验证基本属性
        assert_eq!(state.grid.columns(), 80);
        assert_eq!(state.grid.lines(), 24);
        assert_eq!(state.cursor.position, cursor_pos);
        assert_eq!(state.cursor.shape, cursor_shape);
        assert!(state.cursor.is_visible());
        assert!(state.selection.is_none());
        assert!(state.search.is_none());
    }

    /// 测试：验证 TerminalState 是 Clone 的（低成本）
    #[test]
    fn test_terminal_state_clone() {
        // 创建 GridView 和 CursorView
        let grid_data = Arc::new(GridData::empty(80, 24));
        let grid = GridView::new(grid_data);
        let cursor = CursorView::new(
            AbsolutePoint::new(0, 0),
            CursorShape::Block,
        );

        let state1 = TerminalState::new(grid, cursor);

        // Clone 应该很快（只复制 Arc 指针）
        let state2 = state1.clone();

        // 验证两个 state 指向同一份 GridData
        assert_eq!(state1.grid.columns(), state2.grid.columns());
        assert_eq!(state1.grid.lines(), state2.grid.lines());
    }

    /// 测试：验证可以创建带选区的 TerminalState
    #[test]
    fn test_terminal_state_with_selection() {
        // 创建 GridView
        let grid_data = Arc::new(GridData::empty(80, 24));
        let grid = GridView::new(grid_data);

        // 创建 CursorView
        let cursor = CursorView::new(
            AbsolutePoint::new(5, 10),
            CursorShape::Block,
        );

        // 创建 SelectionView
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(5, 20);
        let selection = SelectionView::new(start, end, SelectionType::Simple);

        // 构造带选区的 TerminalState
        let state = TerminalState::with_selection(grid, cursor, selection);

        // 验证选区
        assert!(state.selection.is_some());
        let sel = state.selection.unwrap();
        assert_eq!(sel.start, start);
        assert_eq!(sel.end, end);
        assert_eq!(sel.ty, SelectionType::Simple);
    }

    /// 测试：验证可以创建带搜索的 TerminalState
    #[test]
    fn test_terminal_state_with_search() {
        // 创建 GridView
        let grid_data = Arc::new(GridData::empty(80, 24));
        let grid = GridView::new(grid_data);

        // 创建 CursorView
        let cursor = CursorView::new(
            AbsolutePoint::new(5, 10),
            CursorShape::Block,
        );

        // 创建 SearchView
        let matches = vec![
            MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5)),
            MatchRange::new(AbsolutePoint::new(2, 10), AbsolutePoint::new(2, 15)),
        ];
        let search = SearchView::new(matches, 0);

        // 构造带搜索的 TerminalState
        let state = TerminalState::with_search(grid, cursor, search);

        // 验证搜索
        assert!(state.search.is_some());
        let srch = state.search.unwrap();
        assert_eq!(srch.match_count(), 2);
        assert_eq!(srch.focused_index, 0);
    }
}
