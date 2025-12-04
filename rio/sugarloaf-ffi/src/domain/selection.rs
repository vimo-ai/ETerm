//! Selection - 选区视图
//!
//! 设计原则：
//! - **只读快照**：SelectionView 是值对象，不可变
//! - **简单数据**：只包含选区的起点、终点和类型
//! - **无依赖**：不依赖 rio-backend 的 Selection 复杂逻辑
//!
//! 与 rio-backend/selection.rs 的关系：
//! - rio-backend/Selection: 可变状态，包含复杂的选区操作逻辑
//! - SelectionView: 只读视图，只包含渲染所需的最小信息

/// 选区类型
///
/// 对应 rio-backend 的 SelectionType，但去掉 Semantic 类型
/// （Semantic 会在创建时转换为 Simple 类型的具体坐标）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectionType {
    /// 普通选区（按字符选择）
    Simple,
    /// 块选区（矩形区域选择）
    Block,
    /// 行选区（按行选择）
    Lines,
}

/// 选区端点
///
/// 表示选区的一个端点（起点或终点）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionPoint {
    /// 行号（0-based）
    pub line: usize,
    /// 列号（0-based）
    pub col: usize,
}

impl SelectionPoint {
    /// 创建新的选区端点
    ///
    /// # 参数
    /// - `line`: 行号（0-based）
    /// - `col`: 列号（0-based）
    pub fn new(line: usize, col: usize) -> Self {
        Self { line, col }
    }
}

/// 选区视图
///
/// 代表一个文本选区的只读快照，用于渲染。
///
/// # 坐标系统
///
/// - `start`: 选区起点（通常是左上角）
/// - `end`: 选区终点（通常是右下角）
/// - 坐标使用 0-based 索引
///
/// # 选区类型
///
/// - `Simple`: 普通选区，按字符选择
/// - `Block`: 块选区，矩形区域选择
/// - `Lines`: 行选区，整行选择
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionView {
    /// 选区起点
    pub start: SelectionPoint,
    /// 选区终点
    pub end: SelectionPoint,
    /// 选区类型
    pub ty: SelectionType,
}

impl SelectionView {
    /// 创建新的选区视图
    ///
    /// # 参数
    /// - `start`: 选区起点
    /// - `end`: 选区终点
    /// - `ty`: 选区类型
    ///
    /// # 示例
    ///
    /// ```ignore
    /// let start = SelectionPoint::new(0, 0);
    /// let end = SelectionPoint::new(5, 10);
    /// let selection = SelectionView::new(start, end, SelectionType::Simple);
    /// ```
    pub fn new(start: SelectionPoint, end: SelectionPoint, ty: SelectionType) -> Self {
        Self { start, end, ty }
    }

    /// 判断选区是否为块选区
    #[inline]
    pub fn is_block(&self) -> bool {
        self.ty == SelectionType::Block
    }

    /// 判断选区是否为行选区
    #[inline]
    pub fn is_lines(&self) -> bool {
        self.ty == SelectionType::Lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试：SelectionPoint 构造
    #[test]
    fn test_selection_point_basic() {
        let point = SelectionPoint::new(10, 20);
        assert_eq!(point.line, 10);
        assert_eq!(point.col, 20);
    }

    /// 测试：SelectionView 构造
    #[test]
    fn test_selection_view_construction() {
        let start = SelectionPoint::new(0, 0);
        let end = SelectionPoint::new(5, 10);
        let selection = SelectionView::new(start, end, SelectionType::Simple);

        assert_eq!(selection.start, start);
        assert_eq!(selection.end, end);
        assert_eq!(selection.ty, SelectionType::Simple);
        assert!(!selection.is_block());
        assert!(!selection.is_lines());
    }

    /// 测试：不同选区类型
    #[test]
    fn test_selection_types() {
        let start = SelectionPoint::new(0, 0);
        let end = SelectionPoint::new(5, 10);

        // Simple 类型
        let simple = SelectionView::new(start, end, SelectionType::Simple);
        assert_eq!(simple.ty, SelectionType::Simple);
        assert!(!simple.is_block());
        assert!(!simple.is_lines());

        // Block 类型
        let block = SelectionView::new(start, end, SelectionType::Block);
        assert_eq!(block.ty, SelectionType::Block);
        assert!(block.is_block());
        assert!(!block.is_lines());

        // Lines 类型
        let lines = SelectionView::new(start, end, SelectionType::Lines);
        assert_eq!(lines.ty, SelectionType::Lines);
        assert!(!lines.is_block());
        assert!(lines.is_lines());
    }

    /// 测试：SelectionPoint 相等性
    #[test]
    fn test_selection_point_equality() {
        let p1 = SelectionPoint::new(10, 20);
        let p2 = SelectionPoint::new(10, 20);
        let p3 = SelectionPoint::new(10, 21);

        assert_eq!(p1, p2);
        assert_ne!(p1, p3);
    }

    /// 测试：SelectionView 相等性
    #[test]
    fn test_selection_view_equality() {
        let start = SelectionPoint::new(0, 0);
        let end = SelectionPoint::new(5, 10);

        let s1 = SelectionView::new(start, end, SelectionType::Simple);
        let s2 = SelectionView::new(start, end, SelectionType::Simple);
        let s3 = SelectionView::new(start, end, SelectionType::Block);

        assert_eq!(s1, s2);
        assert_ne!(s1, s3); // 不同类型
    }
}
