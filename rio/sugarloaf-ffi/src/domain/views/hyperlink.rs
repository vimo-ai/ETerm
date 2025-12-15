//! Hyperlink Hover View - 超链接悬停状态
//!
//! 设计原则：
//! - **只读快照**：HyperlinkHoverView 是值对象，不可变
//! - **复用 Selection 机制**：渲染时类似 SelectionInfo 处理高亮
//!
//! 与 rio-backend/square.rs 的 Hyperlink 的关系：
//! - rio-backend/Hyperlink: 存储在 Square.extra 中的超链接数据
//! - HyperlinkHoverView: 当前 hover 状态，用于渲染高亮

use crate::domain::primitives::AbsolutePoint;

/// 超链接悬停视图
///
/// 表示当前鼠标悬停的超链接区域，用于渲染高亮。
///
/// # 坐标系统
///
/// - `start`: 超链接起点（绝对坐标）
/// - `end`: 超链接终点（绝对坐标）
///
/// # 使用场景
///
/// 1. 用户按住 Cmd 键并移动鼠标
/// 2. Swift 调用 FFI 查询当前位置的超链接
/// 3. 如果有超链接，设置 HyperlinkHoverView
/// 4. 渲染器检测到 hover 状态，渲染高亮（下划线 + 颜色变化）
/// 5. 用户点击时，Swift 打开 URL
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HyperlinkHoverView {
    /// 超链接起点（绝对坐标）
    pub start: AbsolutePoint,
    /// 超链接终点（绝对坐标）
    pub end: AbsolutePoint,
    /// 超链接 URI
    pub uri: String,
}

impl HyperlinkHoverView {
    /// 创建新的超链接悬停视图
    pub fn new(start: AbsolutePoint, end: AbsolutePoint, uri: String) -> Self {
        Self { start, end, uri }
    }

    /// 判断指定行是否在超链接范围内
    #[inline]
    pub fn contains_line(&self, abs_line: usize) -> bool {
        abs_line >= self.start.line && abs_line <= self.end.line
    }

    /// 获取指定行的列范围
    ///
    /// 返回 (start_col, end_col)，如果行不在范围内返回 None
    pub fn column_range_on_line(&self, abs_line: usize, max_col: usize) -> Option<(usize, usize)> {
        if !self.contains_line(abs_line) {
            return None;
        }

        let start_col = if abs_line == self.start.line {
            self.start.col
        } else {
            0
        };

        let end_col = if abs_line == self.end.line {
            self.end.col
        } else {
            max_col
        };

        Some((start_col, end_col))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hyperlink_hover_view_construction() {
        let start = AbsolutePoint::new(10, 5);
        let end = AbsolutePoint::new(10, 25);
        let uri = "https://example.com".to_string();

        let hover = HyperlinkHoverView::new(start, end, uri.clone());

        assert_eq!(hover.start, start);
        assert_eq!(hover.end, end);
        assert_eq!(hover.uri, uri);
    }

    #[test]
    fn test_contains_line_single_line() {
        let hover = HyperlinkHoverView::new(
            AbsolutePoint::new(10, 5),
            AbsolutePoint::new(10, 25),
            "https://example.com".to_string(),
        );

        assert!(!hover.contains_line(9));
        assert!(hover.contains_line(10));
        assert!(!hover.contains_line(11));
    }

    #[test]
    fn test_contains_line_multi_line() {
        let hover = HyperlinkHoverView::new(
            AbsolutePoint::new(10, 5),
            AbsolutePoint::new(12, 15),
            "https://example.com".to_string(),
        );

        assert!(!hover.contains_line(9));
        assert!(hover.contains_line(10));
        assert!(hover.contains_line(11));
        assert!(hover.contains_line(12));
        assert!(!hover.contains_line(13));
    }

    #[test]
    fn test_column_range_single_line() {
        let hover = HyperlinkHoverView::new(
            AbsolutePoint::new(10, 5),
            AbsolutePoint::new(10, 25),
            "https://example.com".to_string(),
        );

        // 行不在范围内
        assert_eq!(hover.column_range_on_line(9, 80), None);

        // 单行超链接
        assert_eq!(hover.column_range_on_line(10, 80), Some((5, 25)));
    }

    #[test]
    fn test_column_range_multi_line() {
        let hover = HyperlinkHoverView::new(
            AbsolutePoint::new(10, 5),
            AbsolutePoint::new(12, 15),
            "https://example.com".to_string(),
        );

        // 起始行：从 start_col 到行末
        assert_eq!(hover.column_range_on_line(10, 80), Some((5, 80)));

        // 中间行：整行
        assert_eq!(hover.column_range_on_line(11, 80), Some((0, 80)));

        // 结束行：从行首到 end_col
        assert_eq!(hover.column_range_on_line(12, 80), Some((0, 15)));
    }
}
