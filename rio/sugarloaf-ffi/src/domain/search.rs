//! Search - Read-only Search View
//!
//! 设计原则：
//! - **只读视图**：SearchView 是值对象，不可变
//! - **简洁**：只包含匹配结果，不包含搜索逻辑
//! - **独立**：不依赖具体的搜索实现

/// 搜索视图 - 包含所有匹配结果
///
/// 代表当前搜索的所有匹配项和焦点位置。
///
/// # 字段说明
///
/// - `matches`: 所有匹配范围
/// - `focused_index`: 当前焦点匹配的索引（0-based）
///
/// # 使用场景
///
/// - 从 Domain 层的搜索状态提取只读视图
/// - 传递给 Render 层生成搜索高亮 overlays
#[derive(Debug, Clone, PartialEq)]
pub struct SearchView {
    /// 所有匹配范围
    pub matches: Vec<MatchRange>,
    /// 当前焦点匹配的索引（0-based）
    pub focused_index: usize,
}

/// 匹配范围 - 表示单个搜索匹配的位置
///
/// 代表一个搜索匹配在终端网格中的位置范围。
///
/// # 字段说明
///
/// - `start_line`: 起点行号（0-based）
/// - `start_col`: 起点列号（0-based）
/// - `end_line`: 终点行号（0-based）
/// - `end_col`: 终点列号（0-based）
///
/// # 设计说明
///
/// - 使用 0-based 索引与 GridView 保持一致
/// - 范围是闭区间 [start, end]，包含两端
#[derive(Debug, Clone, PartialEq)]
pub struct MatchRange {
    /// 起点行号（0-based）
    pub start_line: usize,
    /// 起点列号（0-based）
    pub start_col: usize,
    /// 终点行号（0-based）
    pub end_line: usize,
    /// 终点列号（0-based）
    pub end_col: usize,
}

impl SearchView {
    /// 创建新的搜索视图
    ///
    /// # 参数
    ///
    /// - `matches`: 所有匹配范围
    /// - `focused_index`: 当前焦点匹配的索引（0-based）
    ///
    /// # 示例
    ///
    /// ```ignore
    /// let matches = vec![
    ///     MatchRange::new(0, 0, 0, 5),
    ///     MatchRange::new(2, 10, 2, 15),
    /// ];
    /// let search = SearchView::new(matches, 0);
    /// ```
    pub fn new(matches: Vec<MatchRange>, focused_index: usize) -> Self {
        Self {
            matches,
            focused_index,
        }
    }

    /// 判断是否有匹配结果
    #[inline]
    pub fn has_matches(&self) -> bool {
        !self.matches.is_empty()
    }

    /// 获取匹配数量
    #[inline]
    pub fn match_count(&self) -> usize {
        self.matches.len()
    }

    /// 获取焦点匹配（如果存在）
    #[inline]
    pub fn focused_match(&self) -> Option<&MatchRange> {
        self.matches.get(self.focused_index)
    }
}

impl MatchRange {
    /// 创建新的匹配范围
    ///
    /// # 参数
    ///
    /// - `start_line`: 起点行号（0-based）
    /// - `start_col`: 起点列号（0-based）
    /// - `end_line`: 终点行号（0-based）
    /// - `end_col`: 终点列号（0-based）
    ///
    /// # 示例
    ///
    /// ```ignore
    /// // 单行匹配：第 0 行，列 0-5
    /// let single_line = MatchRange::new(0, 0, 0, 5);
    ///
    /// // 多行匹配：从第 0 行第 10 列到第 2 行第 5 列
    /// let multi_line = MatchRange::new(0, 10, 2, 5);
    /// ```
    pub fn new(start_line: usize, start_col: usize, end_line: usize, end_col: usize) -> Self {
        Self {
            start_line,
            start_col,
            end_line,
            end_col,
        }
    }

    /// 判断是否为单行匹配
    #[inline]
    pub fn is_single_line(&self) -> bool {
        self.start_line == self.end_line
    }

    /// 判断是否为多行匹配
    #[inline]
    pub fn is_multi_line(&self) -> bool {
        self.start_line != self.end_line
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试：验证 SearchView 构造
    #[test]
    fn test_search_view_construction() {
        let matches = vec![
            MatchRange::new(0, 0, 0, 5),
            MatchRange::new(2, 10, 2, 15),
        ];
        let search = SearchView::new(matches.clone(), 0);

        assert_eq!(search.match_count(), 2);
        assert!(search.has_matches());
        assert_eq!(search.focused_index, 0);
        assert_eq!(search.matches, matches);
    }

    /// 测试：验证 MatchRange 基本功能
    #[test]
    fn test_match_range_basic() {
        // 单行匹配
        let single_line = MatchRange::new(0, 0, 0, 5);
        assert_eq!(single_line.start_line, 0);
        assert_eq!(single_line.start_col, 0);
        assert_eq!(single_line.end_line, 0);
        assert_eq!(single_line.end_col, 5);
        assert!(single_line.is_single_line());
        assert!(!single_line.is_multi_line());

        // 多行匹配
        let multi_line = MatchRange::new(0, 10, 2, 5);
        assert_eq!(multi_line.start_line, 0);
        assert_eq!(multi_line.start_col, 10);
        assert_eq!(multi_line.end_line, 2);
        assert_eq!(multi_line.end_col, 5);
        assert!(!multi_line.is_single_line());
        assert!(multi_line.is_multi_line());
    }

    /// 测试：验证空搜索视图
    #[test]
    fn test_search_view_empty_matches() {
        let search = SearchView::new(vec![], 0);

        assert_eq!(search.match_count(), 0);
        assert!(!search.has_matches());
        assert!(search.focused_match().is_none());
    }

    /// 测试：验证多个匹配的搜索视图
    #[test]
    fn test_search_view_multiple_matches() {
        let matches = vec![
            MatchRange::new(0, 0, 0, 5),
            MatchRange::new(1, 10, 1, 15),
            MatchRange::new(5, 0, 7, 10),
        ];
        let search = SearchView::new(matches.clone(), 1);

        assert_eq!(search.match_count(), 3);
        assert!(search.has_matches());
        assert_eq!(search.focused_index, 1);

        // 验证焦点匹配
        let focused = search.focused_match();
        assert!(focused.is_some());
        let focused = focused.unwrap();
        assert_eq!(focused.start_line, 1);
        assert_eq!(focused.start_col, 10);
        assert_eq!(focused.end_line, 1);
        assert_eq!(focused.end_col, 15);
    }

    /// 测试：验证 MatchRange 的 PartialEq
    #[test]
    fn test_match_range_equality() {
        let range1 = MatchRange::new(0, 0, 0, 5);
        let range2 = MatchRange::new(0, 0, 0, 5);
        let range3 = MatchRange::new(0, 0, 0, 6);

        assert_eq!(range1, range2);
        assert_ne!(range1, range3);
    }

    /// 测试：验证 SearchView 的 PartialEq
    #[test]
    fn test_search_view_equality() {
        let matches1 = vec![MatchRange::new(0, 0, 0, 5)];
        let matches2 = vec![MatchRange::new(0, 0, 0, 5)];
        let matches3 = vec![MatchRange::new(0, 0, 0, 6)];

        let search1 = SearchView::new(matches1, 0);
        let search2 = SearchView::new(matches2, 0);
        let search3 = SearchView::new(matches3, 0);

        assert_eq!(search1, search2);
        assert_ne!(search1, search3);
    }
}
