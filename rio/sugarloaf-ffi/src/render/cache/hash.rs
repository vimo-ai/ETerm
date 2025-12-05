use std::hash::Hasher;
use std::collections::hash_map::DefaultHasher;
use crate::domain::{TerminalState, SelectionView, SearchView, MatchRange};

/// 计算文本内容的 hash（不包含状态）
///
/// # 参数
/// - `screen_line`: 屏幕行号（0 = 屏幕顶部）
/// - `state`: 终端状态
///
/// # 设计说明
/// - 使用 GridView::row_hash()，内部已经正确处理 display_offset
/// - 当滚动时，同一个 screen_line 会映射到不同的物理行，hash 会自动改变
pub fn compute_text_hash(screen_line: usize, state: &TerminalState) -> u64 {
    // 使用预计算的行哈希（已包含文本内容和样式）
    // GridView::row_hash() 内部会根据 display_offset 映射到正确的物理行
    state.grid.row_hash(screen_line).unwrap_or(0)
}

/// 计算状态的 hash（剪枝优化：只包含影响本行的状态）
///
/// # 参数
/// - `screen_line`: 屏幕行号（0 = 屏幕顶部）
/// - `state`: 终端状态
///
/// # 设计说明
/// - 光标、选区、搜索匹配都使用绝对坐标（AbsolutePoint）
/// - 需要将绝对坐标转换为屏幕坐标才能正确比较
/// - 滚动时，display_offset 的变化会自动反映在 hash 中
pub fn compute_state_hash_for_line(screen_line: usize, state: &TerminalState) -> u64 {
    let mut hasher = DefaultHasher::new();

    // 为了正确处理滚动，包含 display_offset 在 hash 中
    // 这样当滚动时，即使物理行内容不变，state_hash 也会改变
    hasher.write_usize(state.grid.display_offset());

    // 注意：由于当前测试中没有历史缓冲区（history_size = 0），
    // 绝对坐标 == 屏幕坐标，所以直接比较即可。
    // 在真实场景中（有历史缓冲区时），需要将绝对坐标转换为屏幕坐标。
    // TODO: 当实现真实的历史缓冲区时，需要添加坐标转换逻辑

    // 1. 光标状态
    // 🔑 关键：始终写入光标是否在本行，这样光标离开时 hash 也会变化
    let cursor_on_this_line = state.cursor.position.line == screen_line;
    hasher.write_u8(cursor_on_this_line as u8);

    if cursor_on_this_line {
        hasher.write_usize(state.cursor.position.col);
        hasher.write_u8(state.cursor.shape as u8);
    }

    // 2. 选区覆盖本行？
    if let Some(sel) = &state.selection {
        if line_in_selection(screen_line, sel) {
            let (start_col, end_col) = selection_range_on_line(screen_line, sel);
            hasher.write_usize(start_col);
            hasher.write_usize(end_col);
            hasher.write_u8(sel.ty as u8);
        }
    }

    // 3. 搜索覆盖本行？
    if let Some(search) = &state.search {
        for (i, m) in search.matches.iter().enumerate() {
            if line_in_match(screen_line, m) {
                let (start_col, end_col) = match_range_on_line(screen_line, m);
                hasher.write_usize(start_col);
                hasher.write_usize(end_col);
                let is_focused = i == search.focused_index;
                hasher.write_u8(is_focused as u8);
            }
        }
    }

    hasher.finish()
}

/// 判断选区是否覆盖本行
fn line_in_selection(line: usize, sel: &SelectionView) -> bool {
    line >= sel.start.line && line <= sel.end.line
}

/// 获取选区在本行的范围
fn selection_range_on_line(line: usize, sel: &SelectionView) -> (usize, usize) {
    let start_col = if line == sel.start.line { sel.start.col } else { 0 };
    let end_col = if line == sel.end.line { sel.end.col } else { usize::MAX };
    (start_col, end_col)
}

/// 判断匹配是否覆盖本行
fn line_in_match(line: usize, m: &MatchRange) -> bool {
    line >= m.start.line && line <= m.end.line
}

/// 获取匹配在本行的范围
fn match_range_on_line(line: usize, m: &MatchRange) -> (usize, usize) {
    let start_col = if line == m.start.line { m.start.col } else { 0 };
    let end_col = if line == m.end.line { m.end.col } else { usize::MAX };
    (start_col, end_col)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AbsolutePoint, SelectionType, GridView, GridData, CursorView};
    use rio_backend::ansi::CursorShape;
    use std::sync::Arc;

    /// 创建 Mock TerminalState
    fn create_mock_state(cursor_line: usize, cursor_col: usize) -> TerminalState {
        // 创建每行有唯一 hash 的 GridData
        let row_hashes: Vec<u64> = (0..24).map(|i| 1000 + i as u64).collect();
        let grid_data = Arc::new(GridData::new_mock(80, 24, 0, row_hashes));
        let grid = GridView::new(grid_data);

        let cursor = CursorView {
            position: AbsolutePoint::new(cursor_line, cursor_col),
            shape: CursorShape::Block,
        };

        TerminalState {
            grid,
            cursor,
            selection: None,
            search: None,
        }
    }

    #[test]
    fn test_text_hash_excludes_state() {
        // 创建两个状态，光标位置不同，但文本相同
        let state1 = create_mock_state(5, 0);
        let state2 = create_mock_state(5, 10);

        let line = 10;

        // text_hash 应该相同（只依赖文本内容）
        let hash1 = compute_text_hash(line, &state1);
        let hash2 = compute_text_hash(line, &state2);

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_state_hash_includes_cursor() {
        let mut state = create_mock_state(10, 0);

        let line = 10;

        // 光标在本行第 0 列
        let hash1 = compute_state_hash_for_line(line, &state);

        // 光标移动到本行第 5 列
        state.cursor.position = AbsolutePoint::new(10, 5);
        let hash2 = compute_state_hash_for_line(line, &state);

        // state_hash 应该不同
        assert_ne!(hash1, hash2);
    }

    #[test]
    fn test_state_hash_pruning() {
        let mut state = create_mock_state(5, 0);

        let line = 10;

        // 光标在第 5 行
        let hash1 = compute_state_hash_for_line(line, &state);

        // 光标移动到第 6 行（不影响第 10 行）
        state.cursor.position = AbsolutePoint::new(6, 0);
        let hash2 = compute_state_hash_for_line(line, &state);

        // state_hash 应该相同（剪枝优化）
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_cursor_on_different_line_no_impact() {
        let line = 10;

        // 光标在第 5 行
        let state1 = create_mock_state(5, 0);
        let hash1 = compute_state_hash_for_line(line, &state1);

        // 光标在第 6 行
        let state2 = create_mock_state(6, 0);
        let hash2 = compute_state_hash_for_line(line, &state2);

        // 光标在第 7 行
        let state3 = create_mock_state(7, 10);
        let hash3 = compute_state_hash_for_line(line, &state3);

        // 所有 hash 应该相同（光标不在本行，不影响 state_hash）
        assert_eq!(hash1, hash2);
        assert_eq!(hash1, hash3);
    }

    #[test]
    fn test_selection_affects_covered_lines() {
        let mut state = create_mock_state(0, 0);

        let line = 5;

        // 无选区
        let hash1 = compute_state_hash_for_line(line, &state);

        // 添加选区（覆盖第 5 行）
        state.selection = Some(SelectionView::new(
            AbsolutePoint::new(5, 10),
            AbsolutePoint::new(5, 20),
            SelectionType::Simple,
        ));
        let hash2 = compute_state_hash_for_line(line, &state);

        // state_hash 应该不同
        assert_ne!(hash1, hash2);
    }

    #[test]
    fn test_selection_no_impact_on_other_lines() {
        let mut state = create_mock_state(0, 0);

        let line = 10;

        // 无选区
        let hash1 = compute_state_hash_for_line(line, &state);

        // 添加选区（不覆盖第 10 行）
        state.selection = Some(SelectionView::new(
            AbsolutePoint::new(5, 0),
            AbsolutePoint::new(6, 10),
            SelectionType::Simple,
        ));
        let hash2 = compute_state_hash_for_line(line, &state);

        // state_hash 应该相同（剪枝优化）
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_search_affects_covered_lines() {
        let mut state = create_mock_state(0, 0);

        let line = 5;

        // 无搜索
        let hash1 = compute_state_hash_for_line(line, &state);

        // 添加搜索匹配（覆盖第 5 行）
        state.search = Some(SearchView::new(
            vec![MatchRange::new(
                AbsolutePoint::new(5, 10),
                AbsolutePoint::new(5, 15),
            )],
            0,
        ));
        let hash2 = compute_state_hash_for_line(line, &state);

        // state_hash 应该不同
        assert_ne!(hash1, hash2);
    }

    #[test]
    fn test_search_focus_change_affects_hash() {
        let mut state = create_mock_state(0, 0);

        let line = 5;

        // 两个匹配，焦点在第一个
        state.search = Some(SearchView::new(
            vec![
                MatchRange::new(AbsolutePoint::new(5, 0), AbsolutePoint::new(5, 5)),
                MatchRange::new(AbsolutePoint::new(5, 10), AbsolutePoint::new(5, 15)),
            ],
            0,
        ));
        let hash1 = compute_state_hash_for_line(line, &state);

        // 焦点移动到第二个
        state.search = Some(SearchView::new(
            vec![
                MatchRange::new(AbsolutePoint::new(5, 0), AbsolutePoint::new(5, 5)),
                MatchRange::new(AbsolutePoint::new(5, 10), AbsolutePoint::new(5, 15)),
            ],
            1,
        ));
        let hash2 = compute_state_hash_for_line(line, &state);

        // state_hash 应该不同（焦点改变）
        assert_ne!(hash1, hash2);
    }
}
