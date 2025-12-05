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

#[cfg(feature = "new_architecture")]
use rio_backend::crosswords::Crosswords;
#[cfg(feature = "new_architecture")]
use rio_backend::crosswords::grid::Dimensions;
#[cfg(feature = "new_architecture")]
use rio_backend::crosswords::pos::{Line, Column};
#[cfg(feature = "new_architecture")]
use rio_backend::event::EventListener;

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

    /// 获取行数（屏幕可见区域）
    #[inline]
    pub fn lines(&self) -> usize {
        self.data.screen_lines
    }

    /// 获取滚动偏移
    #[inline]
    pub fn display_offset(&self) -> usize {
        self.data.display_offset
    }

    /// 获取指定屏幕行的哈希值（用于缓存查询）
    ///
    /// # 设计原理
    /// 当行内容改变时，哈希值会变化，从而使缓存失效。
    /// 这是实现增量渲染的关键。
    ///
    /// # 参数
    /// - `screen_line`: 屏幕行号（0-based，0 = 屏幕顶部）
    ///
    /// # 返回
    /// - `Some(hash)`: 行哈希值
    /// - `None`: 行不存在
    pub fn row_hash(&self, screen_line: usize) -> Option<u64> {
        // 计算实际数组索引
        let array_index = self.data.screen_line_to_array_index(screen_line)?;
        self.data.row_hashes.get(array_index).copied()
    }

    /// 获取指定屏幕行的视图（延迟加载）
    ///
    /// # 参数
    /// - `screen_line`: 屏幕行号（0-based，0 = 屏幕顶部）
    ///
    /// # 返回
    /// - `Some(RowView)`: 行视图
    /// - `None`: 行不存在
    pub fn row(&self, screen_line: usize) -> Option<RowView> {
        if screen_line < self.data.screen_lines {
            Some(RowView::new(self.data.clone(), screen_line))
        } else {
            None
        }
    }

    /// 迭代所有可见屏幕行（延迟加载）
    pub fn rows(&self) -> impl Iterator<Item = RowView> {
        let data = self.data.clone();
        let screen_lines = self.data.screen_lines;
        (0..screen_lines).map(move |screen_line| RowView::new(data.clone(), screen_line))
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
    /// 屏幕行号（0 = 屏幕顶部）
    screen_line: usize,
}

impl RowView {
    /// 创建新的 RowView
    fn new(data: Arc<GridData>, screen_line: usize) -> Self {
        Self { data, screen_line }
    }

    /// 获取屏幕行号
    #[inline]
    pub fn line(&self) -> usize {
        self.screen_line
    }

    /// 获取行哈希值
    #[inline]
    pub fn hash(&self) -> u64 {
        // 计算实际数组索引
        let array_index = self.data.screen_line_to_array_index(self.screen_line)
            .expect("RowView should always have valid screen_line");
        self.data.row_hashes[array_index]
    }

    /// 获取列数
    #[inline]
    pub fn columns(&self) -> usize {
        self.data.columns
    }

    /// 获取行的所有 cell 数据
    #[cfg(feature = "new_architecture")]
    #[inline]
    pub fn cells(&self) -> &[CellData] {
        // 计算实际数组索引
        let array_index = self.data.screen_line_to_array_index(self.screen_line)
            .expect("RowView should always have valid screen_line");
        &self.data.rows[array_index].cells
    }
}

/// Cell Data - 单个字符的数据
#[cfg(feature = "new_architecture")]
#[derive(Debug, Clone)]
pub struct CellData {
    pub c: char,
    pub fg: rio_backend::config::colors::AnsiColor,
    pub bg: rio_backend::config::colors::AnsiColor,
    pub flags: u16,
}

#[cfg(feature = "new_architecture")]
impl Default for CellData {
    fn default() -> Self {
        use rio_backend::config::colors::{AnsiColor, NamedColor};
        Self {
            c: ' ',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: 0,
        }
    }
}

/// Row Data - 单行的数据
#[cfg(feature = "new_architecture")]
#[derive(Debug, Clone)]
pub struct RowData {
    pub cells: Vec<CellData>,
    pub content_hash: u64,
}

#[cfg(feature = "new_architecture")]
impl RowData {
    pub fn empty(columns: usize) -> Self {
        Self {
            cells: vec![CellData::default(); columns],
            content_hash: 0,
        }
    }
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
///
/// 数据存储布局：
/// - `rows` 存储所有行（历史缓冲区 + 屏幕行）
/// - 索引 0 是历史缓冲区的最顶部
/// - 索引 history_size 是屏幕的第一行
/// - 索引映射：array_index = history_size - display_offset + screen_line
#[derive(Debug)]
pub struct GridData {
    /// 列数
    columns: usize,
    /// 屏幕行数（可见区域）
    screen_lines: usize,
    /// 历史缓冲区大小
    history_size: usize,
    /// 滚动偏移（0 = 在底部，> 0 = 向上滚动）
    display_offset: usize,
    /// 行哈希列表（预计算，与 rows 一一对应）
    row_hashes: Vec<u64>,
    /// 行数据（包含实际的 cells）
    #[cfg(feature = "new_architecture")]
    rows: Vec<RowData>,
}

impl GridData {
    /// 将屏幕行号转换为数组索引
    ///
    /// # 参数
    /// - `screen_line`: 屏幕行号（0 = 屏幕顶部）
    ///
    /// # 返回
    /// - `Some(array_index)`: 实际数组索引
    /// - `None`: 行不存在
    ///
    /// # 映射公式
    /// ```
    /// array_index = history_size - display_offset + screen_line
    /// ```
    ///
    /// # 示例
    /// - 假设 history_size = 1000, display_offset = 0（在底部）
    ///   - screen_line 0 → array_index 1000（屏幕第一行）
    ///   - screen_line 23 → array_index 1023（屏幕最后一行）
    /// - 假设 history_size = 1000, display_offset = 5（向上滚动 5 行）
    ///   - screen_line 0 → array_index 995（历史缓冲区的某一行）
    ///   - screen_line 23 → array_index 1018
    #[inline]
    fn screen_line_to_array_index(&self, screen_line: usize) -> Option<usize> {
        if screen_line >= self.screen_lines {
            return None;
        }

        // 计算数组索引
        // 注意：当 display_offset > 0 时，我们向上滚动，看到的是更早的历史行
        let array_index = self.history_size
            .checked_sub(self.display_offset)?
            .checked_add(screen_line)?;

        // 验证索引在有效范围内
        if array_index < self.rows.len() {
            Some(array_index)
        } else {
            None
        }
    }

    /// 创建新的 GridData（用于测试）
    ///
    /// # 参数
    /// - `columns`: 列数
    /// - `screen_lines`: 屏幕行数
    /// - `display_offset`: 滚动偏移
    /// - `row_hashes`: 行哈希列表
    #[cfg(test)]
    pub fn new_mock(
        columns: usize,
        screen_lines: usize,
        display_offset: usize,
        row_hashes: Vec<u64>,
    ) -> Self {
        // 对于测试，假设没有历史缓冲区（或历史缓冲区为空）
        let history_size = 0;
        let total_lines = screen_lines;

        assert_eq!(row_hashes.len(), total_lines, "row_hashes length must match total_lines");

        Self {
            columns,
            screen_lines,
            history_size,
            display_offset,
            row_hashes: row_hashes.clone(),
            #[cfg(feature = "new_architecture")]
            rows: vec![RowData::empty(columns); total_lines],
        }
    }

    /// 创建空的 GridData（用于测试）
    #[cfg(test)]
    pub fn empty(columns: usize, screen_lines: usize) -> Self {
        Self {
            columns,
            screen_lines,
            history_size: 0,
            display_offset: 0,
            row_hashes: vec![0; screen_lines],
            #[cfg(feature = "new_architecture")]
            rows: vec![RowData::empty(columns); screen_lines],
        }
    }

    /// 从 Crosswords 构造 GridData
    #[cfg(feature = "new_architecture")]
    pub fn from_crosswords<T: EventListener>(crosswords: &Crosswords<T>) -> Self {
        let grid = &crosswords.grid;
        let display_offset = grid.display_offset();

        let columns = grid.columns();
        let screen_lines = grid.screen_lines();
        let history_size = grid.history_size();

        // 计算总行数（历史 + 屏幕）
        let total_lines = grid.total_lines();

        // 收集所有行数据
        let mut rows = Vec::with_capacity(total_lines);
        let mut row_hashes = Vec::with_capacity(total_lines);

        // 遍历所有行（从历史缓冲区开始）
        // Crosswords 的 Line 是 i32，Line(0) 是屏幕顶部，负数是历史缓冲区
        for line_index in 0..total_lines {
            // 计算相对于屏幕顶部的行号
            // line_index 0 = 历史缓冲区最顶部
            // line_index history_size = 屏幕第一行（Line(0)）
            let line = Line((line_index as i32) - (history_size as i32));

            // 获取该行数据
            let row_data = Self::convert_row::<T>(grid, line, columns);
            row_hashes.push(row_data.content_hash);
            rows.push(row_data);
        }

        Self {
            columns,
            screen_lines,
            history_size,
            display_offset,
            row_hashes,
            rows,
        }
    }

    /// 转换 Crosswords 的一行到 RowData
    #[cfg(feature = "new_architecture")]
    fn convert_row<T>(
        grid: &rio_backend::crosswords::grid::Grid<rio_backend::crosswords::square::Square>,
        line: Line,
        columns: usize,
    ) -> RowData {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut cells = Vec::with_capacity(columns);
        let mut hasher = DefaultHasher::new();

        // 遍历该行的所有列
        for col_index in 0..columns {
            let col = Column(col_index);
            let square = &grid[line][col];

            // 转换 cell 数据
            let cell = CellData {
                c: square.c,
                fg: square.fg,
                bg: square.bg,
                flags: square.flags.bits(),
            };

            // 计算 hash（只基于字符内容）
            cell.c.hash(&mut hasher);

            cells.push(cell);
        }

        let content_hash = hasher.finish();

        RowData {
            cells,
            content_hash,
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
