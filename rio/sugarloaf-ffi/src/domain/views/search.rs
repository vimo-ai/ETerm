//! Search - Read-only Search View
//!
//! 设计原则：
//! - **只读视图**：SearchView 是值对象，不可变
//! - **简洁**：只包含匹配结果，不包含搜索逻辑
//! - **独立**：不依赖具体的搜索实现

use crate::domain::primitives::AbsolutePoint;
use std::collections::HashMap;

/// 搜索视图 - 包含所有匹配结果
///
/// 代表当前搜索的所有匹配项和焦点位置。
///
/// # 字段说明
///
/// - `matches`: 所有匹配范围（保留用于导航）
/// - `matches_by_line`: 按行索引的匹配（用于快速渲染查询）
/// - `focused_index`: 当前焦点匹配的索引（0-based）
///
/// # 性能优化
///
/// `matches_by_line` 将匹配按行号分组，渲染某行时只需检查该行的匹配，
/// 避免遍历所有匹配（O(cells × matches) → O(cells)）。
///
/// # 使用场景
///
/// - 从 Domain 层的搜索状态提取只读视图
/// - 传递给 Render 层生成搜索高亮 overlays
#[derive(Debug, Clone, PartialEq)]
pub struct SearchView {
    /// 所有匹配范围（保留用于导航）
    pub matches: Vec<MatchRange>,
    /// 按行索引的匹配（用于快速渲染查询）
    /// key: 行号（绝对坐标）, value: matches 中的索引列表
    pub matches_by_line: HashMap<usize, Vec<usize>>,
    /// 当前焦点匹配的索引（0-based）
    pub focused_index: usize,
}

/// 匹配范围 - 表示单个搜索匹配的位置
///
/// 代表一个搜索匹配在终端网格中的位置范围。
///
/// # 字段说明
///
/// - `start`: 起点（绝对坐标）
/// - `end`: 终点（绝对坐标）
///
/// # 设计说明
///
/// - 使用绝对坐标系（含历史缓冲区）
/// - 范围是闭区间 [start, end]，包含两端
#[derive(Debug, Clone, PartialEq)]
pub struct MatchRange {
    /// 起点（绝对坐标）
    pub start: AbsolutePoint,
    /// 终点（绝对坐标）
    pub end: AbsolutePoint,
}

impl SearchView {
    /// 创建新的搜索视图
    ///
    /// # 参数
    ///
    /// - `matches`: 所有匹配范围
    /// - `focused_index`: 当前焦点匹配的索引（0-based）
    ///
    /// # 性能说明
    ///
    /// 构建时会自动生成 `matches_by_line` 索引，将匹配按行号分组。
    /// 如果一个匹配跨多行，会在所有涉及的行中添加索引。
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
        // 构建行号索引
        let mut matches_by_line: HashMap<usize, Vec<usize>> = HashMap::new();

        for (idx, m) in matches.iter().enumerate() {
            // 对于跨多行的匹配，需要在每一行的索引中都添加
            for line in m.start.line..=m.end.line {
                matches_by_line
                    .entry(line)
                    .or_insert_with(Vec::new)
                    .push(idx);
            }
        }

        Self {
            matches,
            matches_by_line,
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

    /// 获取某行的所有匹配索引
    ///
    /// # 参数
    ///
    /// - `line`: 行号（绝对坐标）
    ///
    /// # 返回
    ///
    /// - `Some(&[usize])`: 该行的匹配索引列表（指向 `matches` 中的下标）
    /// - `None`: 该行没有匹配
    ///
    /// # 性能
    ///
    /// O(1) HashMap 查询，比遍历所有匹配快得多。
    #[inline]
    pub fn get_matches_at_line(&self, line: usize) -> Option<&[usize]> {
        self.matches_by_line.get(&line).map(|v| v.as_slice())
    }
}

impl MatchRange {
    /// 创建新的匹配范围
    ///
    /// # 参数
    ///
    /// - `start`: 起点（绝对坐标）
    /// - `end`: 终点（绝对坐标）
    ///
    /// # 示例
    ///
    /// ```ignore
    /// // 单行匹配：第 0 行，列 0-5
    /// let single_line = MatchRange::new(
    ///     AbsolutePoint::new(0, 0),
    ///     AbsolutePoint::new(0, 5)
    /// );
    ///
    /// // 多行匹配：从第 0 行第 10 列到第 2 行第 5 列
    /// let multi_line = MatchRange::new(
    ///     AbsolutePoint::new(0, 10),
    ///     AbsolutePoint::new(2, 5)
    /// );
    /// ```
    pub fn new(start: AbsolutePoint, end: AbsolutePoint) -> Self {
        Self { start, end }
    }

    /// 判断是否为单行匹配
    #[inline]
    pub fn is_single_line(&self) -> bool {
        self.start.line == self.end.line
    }

    /// 判断是否为多行匹配
    #[inline]
    pub fn is_multi_line(&self) -> bool {
        self.start.line != self.end.line
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试：验证 SearchView 构造
    #[test]
    fn test_search_view_construction() {
        let matches = vec![
            MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5)),
            MatchRange::new(AbsolutePoint::new(2, 10), AbsolutePoint::new(2, 15)),
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
        let single_line = MatchRange::new(
            AbsolutePoint::new(0, 0),
            AbsolutePoint::new(0, 5)
        );
        assert_eq!(single_line.start.line, 0);
        assert_eq!(single_line.start.col, 0);
        assert_eq!(single_line.end.line, 0);
        assert_eq!(single_line.end.col, 5);
        assert!(single_line.is_single_line());
        assert!(!single_line.is_multi_line());

        // 多行匹配
        let multi_line = MatchRange::new(
            AbsolutePoint::new(0, 10),
            AbsolutePoint::new(2, 5)
        );
        assert_eq!(multi_line.start.line, 0);
        assert_eq!(multi_line.start.col, 10);
        assert_eq!(multi_line.end.line, 2);
        assert_eq!(multi_line.end.col, 5);
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
            MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5)),
            MatchRange::new(AbsolutePoint::new(1, 10), AbsolutePoint::new(1, 15)),
            MatchRange::new(AbsolutePoint::new(5, 0), AbsolutePoint::new(7, 10)),
        ];
        let search = SearchView::new(matches.clone(), 1);

        assert_eq!(search.match_count(), 3);
        assert!(search.has_matches());
        assert_eq!(search.focused_index, 1);

        // 验证焦点匹配
        let focused = search.focused_match();
        assert!(focused.is_some());
        let focused = focused.unwrap();
        assert_eq!(focused.start.line, 1);
        assert_eq!(focused.start.col, 10);
        assert_eq!(focused.end.line, 1);
        assert_eq!(focused.end.col, 15);
    }

    /// 测试：验证 MatchRange 的 PartialEq
    #[test]
    fn test_match_range_equality() {
        let range1 = MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5));
        let range2 = MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5));
        let range3 = MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 6));

        assert_eq!(range1, range2);
        assert_ne!(range1, range3);
    }

    /// 测试：验证 SearchView 的 PartialEq
    #[test]
    fn test_search_view_equality() {
        let matches1 = vec![MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5))];
        let matches2 = vec![MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5))];
        let matches3 = vec![MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 6))];

        let search1 = SearchView::new(matches1, 0);
        let search2 = SearchView::new(matches2, 0);
        let search3 = SearchView::new(matches3, 0);

        assert_eq!(search1, search2);
        assert_ne!(search1, search3);
    }

    /// 测试：验证按行索引功能
    #[test]
    fn test_get_matches_at_line() {
        let matches = vec![
            MatchRange::new(AbsolutePoint::new(0, 0), AbsolutePoint::new(0, 5)),   // 第 0 行
            MatchRange::new(AbsolutePoint::new(2, 10), AbsolutePoint::new(2, 15)), // 第 2 行
            MatchRange::new(AbsolutePoint::new(5, 0), AbsolutePoint::new(7, 10)),  // 第 5-7 行（跨行）
        ];
        let search = SearchView::new(matches, 0);

        // 第 0 行：有 1 个匹配（索引 0）
        let line0 = search.get_matches_at_line(0);
        assert!(line0.is_some());
        assert_eq!(line0.unwrap(), &[0]);

        // 第 1 行：没有匹配
        let line1 = search.get_matches_at_line(1);
        assert!(line1.is_none());

        // 第 2 行：有 1 个匹配（索引 1）
        let line2 = search.get_matches_at_line(2);
        assert!(line2.is_some());
        assert_eq!(line2.unwrap(), &[1]);

        // 第 5 行：有 1 个匹配（索引 2，跨行匹配的起始行）
        let line5 = search.get_matches_at_line(5);
        assert!(line5.is_some());
        assert_eq!(line5.unwrap(), &[2]);

        // 第 6 行：有 1 个匹配（索引 2，跨行匹配的中间行）
        let line6 = search.get_matches_at_line(6);
        assert!(line6.is_some());
        assert_eq!(line6.unwrap(), &[2]);

        // 第 7 行：有 1 个匹配（索引 2，跨行匹配的结束行）
        let line7 = search.get_matches_at_line(7);
        assert!(line7.is_some());
        assert_eq!(line7.unwrap(), &[2]);

        // 第 8 行：没有匹配
        let line8 = search.get_matches_at_line(8);
        assert!(line8.is_none());
    }

    /// 测试：验证按行索引的性能优化
    #[test]
    fn test_matches_by_line_performance() {
        // 创建大量匹配（模拟 50000 个匹配的场景）
        let mut matches = Vec::new();
        for i in 0..1000 {
            matches.push(MatchRange::new(
                AbsolutePoint::new(i, 0),
                AbsolutePoint::new(i, 5),
            ));
        }

        let search = SearchView::new(matches, 0);

        // 查询第 500 行的匹配（应该是 O(1) 查询，而不是 O(1000) 遍历）
        let line500 = search.get_matches_at_line(500);
        assert!(line500.is_some());
        assert_eq!(line500.unwrap(), &[500]);

        // 查询不存在的行（应该是 O(1) 查询）
        let line9999 = search.get_matches_at_line(9999);
        assert!(line9999.is_none());
    }
}
