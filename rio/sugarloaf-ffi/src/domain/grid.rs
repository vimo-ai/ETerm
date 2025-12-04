//! Grid View - Zero-copy Grid Snapshot
//!
//! 设计要点：
//! - 使用 `Arc<GridData>` 零拷贝共享底层数据
//! - 提供 `row_hash()` 方法用于缓存查询
//! - 延迟加载行数据（通过 `RowView`）
//!
//! 为什么使用 Arc：
//! - 避免大量内存拷贝（Grid 可能有数千行）
//! - 多线程安全共享
//! - Clone 成本低（只复制指针）

use std::sync::Arc;

/// Grid View - Zero-copy Grid Snapshot
///
/// 设计要点：
/// - 使用 `Arc<GridData>` 零拷贝共享底层数据
/// - 提供 `row_hash()` 方法用于缓存查询
/// - 延迟加载行数据（通过 `RowView`）
///
/// 为什么使用 Arc：
/// - 避免大量内存拷贝（Grid 可能有数千行）
/// - 多线程安全共享
/// - Clone 成本低（只复制指针）
#[derive(Debug, Clone)]
pub struct GridView {
    /// 底层网格数据（Arc 共享）
    data: Arc<GridData>,
}

impl GridView {
    /// 创建新的 GridView
    pub fn new(data: Arc<GridData>) -> Self {
        Self { data }
    }

    /// 获取列数
    #[inline]
    pub fn columns(&self) -> usize {
        self.data.columns
    }

    /// 获取行数（可见区域）
    #[inline]
    pub fn lines(&self) -> usize {
        self.data.lines
    }

    /// 获取滚动偏移
    #[inline]
    pub fn display_offset(&self) -> usize {
        self.data.display_offset
    }

    /// 获取指定行的哈希值（用于缓存查询）
    ///
    /// # 设计原理
    /// 当行内容改变时，哈希值会变化，从而使缓存失效。
    /// 这是实现增量渲染的关键。
    ///
    /// # 参数
    /// - `line`: 行号（0-based，相对于可见区域）
    ///
    /// # 返回
    /// - `Some(hash)`: 行哈希值
    /// - `None`: 行不存在
    pub fn row_hash(&self, line: usize) -> Option<u64> {
        self.data.row_hashes.get(line).copied()
    }

    /// 获取指定行的视图（延迟加载）
    ///
    /// # 参数
    /// - `line`: 行号（0-based，相对于可见区域）
    ///
    /// # 返回
    /// - `Some(RowView)`: 行视图
    /// - `None`: 行不存在
    pub fn row(&self, line: usize) -> Option<RowView> {
        if line < self.data.lines {
            Some(RowView::new(self.data.clone(), line))
        } else {
            None
        }
    }

    /// 迭代所有可见行（延迟加载）
    pub fn rows(&self) -> impl Iterator<Item = RowView> {
        let data = self.data.clone();
        let lines = self.data.lines;
        (0..lines).map(move |line| RowView::new(data.clone(), line))
    }
}

/// Row View - Lazy-loaded Row Snapshot
///
/// 设计要点：
/// - 延迟加载：只在需要时加载行数据
/// - 不直接存储 cells，减少内存占用
/// - 通过 Arc 共享底层数据
///
/// 使用场景：
/// - 渲染时按需加载每行
/// - 差分比较时先比较 hash，再加载内容
#[derive(Debug, Clone)]
pub struct RowView {
    /// 底层网格数据（Arc 共享）
    data: Arc<GridData>,
    /// 行号
    line: usize,
}

impl RowView {
    /// 创建新的 RowView
    fn new(data: Arc<GridData>, line: usize) -> Self {
        Self { data, line }
    }

    /// 获取行号
    #[inline]
    pub fn line(&self) -> usize {
        self.line
    }

    /// 获取行哈希值
    #[inline]
    pub fn hash(&self) -> u64 {
        self.data.row_hashes[self.line]
    }

    /// 获取列数
    #[inline]
    pub fn columns(&self) -> usize {
        self.data.columns
    }

    // TODO: Phase 1 暂不实现 cells() 方法，因为需要定义 CellView
    // 后续会添加：
    // pub fn cells(&self) -> &[CellData] { ... }
}

/// Grid Data - Underlying Grid Storage
///
/// 设计要点：
/// - 被 `Arc` 包装，多线程共享
/// - 只读数据，创建后不可修改
/// - 包含预计算的行哈希
///
/// 为什么分离 GridData 和 GridView：
/// - GridData 是纯数据（可以被多个 GridView 共享）
/// - GridView 是视图（提供访问接口）
/// - 这样可以灵活组合（例如：不同的 display_offset）
#[derive(Debug)]
pub struct GridData {
    /// 列数
    columns: usize,
    /// 行数（可见区域）
    lines: usize,
    /// 滚动偏移
    display_offset: usize,
    /// 行哈希列表（预计算）
    row_hashes: Vec<u64>,
    // TODO: Phase 1 暂不存储实际 cells，因为需要定义 CellData
    // 后续会添加：
    // cells: Vec<Vec<CellData>>,
}

impl GridData {
    /// 创建新的 GridData（用于测试）
    ///
    /// # 参数
    /// - `columns`: 列数
    /// - `lines`: 行数
    /// - `display_offset`: 滚动偏移
    /// - `row_hashes`: 行哈希列表
    #[cfg(test)]
    pub fn new_mock(
        columns: usize,
        lines: usize,
        display_offset: usize,
        row_hashes: Vec<u64>,
    ) -> Self {
        assert_eq!(row_hashes.len(), lines, "row_hashes length must match lines");
        Self {
            columns,
            lines,
            display_offset,
            row_hashes,
        }
    }

    /// 创建空的 GridData（用于测试）
    #[cfg(test)]
    pub fn empty(columns: usize, lines: usize) -> Self {
        Self {
            columns,
            lines,
            display_offset: 0,
            row_hashes: vec![0; lines],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试：验证 row_hash() 方法
    #[test]
    fn test_grid_view_row_hash() {
        // 创建带有特定哈希的 GridData
        let row_hashes = vec![
            0x1111111111111111,
            0x2222222222222222,
            0x3333333333333333,
        ];
        let grid_data = Arc::new(GridData::new_mock(80, 3, 0, row_hashes.clone()));
        let grid_view = GridView::new(grid_data);

        // 验证 row_hash 返回正确的值
        assert_eq!(grid_view.row_hash(0), Some(0x1111111111111111));
        assert_eq!(grid_view.row_hash(1), Some(0x2222222222222222));
        assert_eq!(grid_view.row_hash(2), Some(0x3333333333333333));

        // 验证越界返回 None
        assert_eq!(grid_view.row_hash(3), None);
        assert_eq!(grid_view.row_hash(100), None);
    }

    /// 测试：验证 row() 方法返回 RowView
    #[test]
    fn test_grid_view_row() {
        let row_hashes = vec![0xAAAA, 0xBBBB, 0xCCCC];
        let grid_data = Arc::new(GridData::new_mock(80, 3, 0, row_hashes));
        let grid_view = GridView::new(grid_data);

        // 获取第 1 行
        let row1 = grid_view.row(1).expect("row 1 should exist");
        assert_eq!(row1.line(), 1);
        assert_eq!(row1.hash(), 0xBBBB);
        assert_eq!(row1.columns(), 80);

        // 验证越界返回 None
        assert!(grid_view.row(3).is_none());
    }

    /// 测试：验证 rows() 迭代器
    #[test]
    fn test_grid_view_rows_iterator() {
        let row_hashes = vec![0x1111, 0x2222, 0x3333];
        let grid_data = Arc::new(GridData::new_mock(80, 3, 0, row_hashes));
        let grid_view = GridView::new(grid_data);

        // 收集所有行
        let rows: Vec<_> = grid_view.rows().collect();
        assert_eq!(rows.len(), 3);

        // 验证每行的信息
        assert_eq!(rows[0].line(), 0);
        assert_eq!(rows[0].hash(), 0x1111);
        assert_eq!(rows[1].line(), 1);
        assert_eq!(rows[1].hash(), 0x2222);
        assert_eq!(rows[2].line(), 2);
        assert_eq!(rows[2].hash(), 0x3333);
    }

    /// 测试：验证 GridView 的 display_offset
    #[test]
    fn test_grid_view_display_offset() {
        let grid_data = Arc::new(GridData::new_mock(
            80,
            24,
            5, // display_offset = 5
            vec![0; 24],
        ));
        let grid_view = GridView::new(grid_data);

        assert_eq!(grid_view.display_offset(), 5);
    }
}
