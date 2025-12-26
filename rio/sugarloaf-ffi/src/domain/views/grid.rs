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

use once_cell::sync::Lazy;
use regex::Regex;
use rio_backend::crosswords::Crosswords;

use rio_backend::crosswords::grid::Dimensions;

use rio_backend::crosswords::pos::{Line, Column};

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

    /// 获取历史缓冲区大小
    #[inline]
    pub fn history_size(&self) -> usize {
        self.data.history_size
    }

    /// 将屏幕坐标转换为绝对坐标
    ///
    /// # 公式
    /// absolute_line = history_size + screen_line - display_offset
    ///
    /// # 参数
    /// - `screen_pos`: 屏幕坐标（ScreenPoint）
    ///
    /// # 返回
    /// 绝对坐标（AbsolutePoint）
    #[inline]
    pub fn screen_to_absolute(&self, screen_line: usize, col: usize) -> crate::domain::AbsolutePoint {
        let absolute_line = self.data.history_size
            .saturating_add(screen_line)
            .saturating_sub(self.data.display_offset);
        crate::domain::AbsolutePoint::new(absolute_line, col)
    }

    /// 将绝对坐标转换为屏幕坐标
    ///
    /// # 公式
    /// screen_line = absolute_line - history_size + display_offset
    ///
    /// # 参数
    /// - `abs_pos`: 绝对坐标（AbsolutePoint）
    ///
    /// # 返回
    /// - `Some(screen_line)`: 如果在可见区域内
    /// - `None`: 如果不在可见区域内
    #[inline]
    pub fn absolute_to_screen(&self, abs_line: usize) -> Option<usize> {
        let screen_line = abs_line
            .checked_sub(self.data.history_size)?
            .checked_add(self.data.display_offset)?;

        if screen_line < self.data.screen_lines {
            Some(screen_line)
        } else {
            None
        }
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
    #[inline]
    pub fn cells(&self) -> &[CellData] {
        // 计算实际数组索引
        let array_index = self.data.screen_line_to_array_index(self.screen_line)
            .expect("RowView should always have valid screen_line");
        &self.data.rows[array_index].cells  // Arc 自动 deref
    }

    /// 获取行的 URL 列表
    #[inline]
    pub fn urls(&self) -> &[UrlRange] {
        // 计算实际数组索引
        let array_index = self.data.screen_line_to_array_index(self.screen_line)
            .expect("RowView should always have valid screen_line");
        &self.data.rows[array_index].urls  // Arc 自动 deref
    }
}

/// Cell Data - 单个字符的数据

#[derive(Debug, Clone)]
pub struct CellData {
    pub c: char,
    pub fg: rio_backend::config::colors::AnsiColor,
    pub bg: rio_backend::config::colors::AnsiColor,
    pub flags: u16,
    /// 零宽字符（如 VS16 U+FE0F emoji 变体选择符）
    pub zerowidth: Vec<char>,
    /// 下划线颜色（ANSI escape 支持自定义下划线颜色）
    pub underline_color: Option<rio_backend::config::colors::AnsiColor>,
}


impl Default for CellData {
    fn default() -> Self {
        use rio_backend::config::colors::{AnsiColor, NamedColor};
        Self {
            c: ' ',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: 0,
            zerowidth: Vec::new(),
            underline_color: None,
        }
    }
}

// ========================================================================
// URL 自动检测
// ========================================================================

/// 预编译的 URL 正则表达式
///
/// 匹配 http:// 和 https:// 开头的 URL
/// 使用 \S+ 匹配非空白字符，简单高效
static URL_REGEX: Lazy<Regex> = Lazy::new(|| {
    // 匹配 http:// 和 https:// 开头的 URL
    // 排除空白符、控制字符、和一些特殊标点
    Regex::new(r#"https?://[^\s\x00-\x1f\x7f<>"'`\[\]{}|\\^]+"#).unwrap()
});

/// URL 范围信息
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UrlRange {
    /// 起始列（0-based，字符索引）
    pub start_col: usize,
    /// 结束列（包含，字符索引）
    pub end_col: usize,
    /// URL 字符串
    pub uri: String,
}

/// 检测文本中的 URL
///
/// # 参数
/// - `text`: 要检测的文本
///
/// # 返回
/// URL 范围列表，按起始位置排序
/// 需要从 URL 尾部移除的标点符号
const TRAILING_PUNCTUATION: &[char] = &['.', ',', ')', ']', ';', ':', '!', '?', '\'', '"'];

fn detect_urls(text: &str) -> Vec<UrlRange> {
    let mut urls = Vec::new();

    for mat in URL_REGEX.find_iter(text) {
        // 获取匹配的 URL 并移除尾部标点
        let raw_url = mat.as_str();
        let trimmed_url = raw_url.trim_end_matches(TRAILING_PUNCTUATION);

        // 如果 trim 后为空或太短，跳过
        if trimmed_url.len() < 10 {
            // http://x 至少 10 个字符
            continue;
        }

        // 计算 trim 掉了多少字符
        let trimmed_chars = raw_url.len() - trimmed_url.len();

        // 获取字节位置
        let byte_start = mat.start();
        let byte_end = mat.end() - trimmed_chars;

        // 转换为字符位置（处理 UTF-8 多字节字符）
        let char_start = text[..byte_start].chars().count();
        let char_end = char_start + text[byte_start..byte_end].chars().count() - 1;

        urls.push(UrlRange {
            start_col: char_start,
            end_col: char_end,
            uri: trimmed_url.to_string(),
        });
    }

    urls
}

/// Row Data - 单行的数据
#[derive(Debug, Clone)]
pub struct RowData {
    pub cells: Vec<CellData>,
    pub content_hash: u64,
    /// 该行检测到的 URL 列表
    pub urls: Vec<UrlRange>,
}


impl RowData {
    pub fn empty(columns: usize) -> Self {
        Self {
            cells: vec![CellData::default(); columns],
            content_hash: 0,
            urls: Vec::new(),
        }
    }

    /// 创建空行的 Arc（用于 COW）
    pub fn empty_arc(columns: usize) -> Arc<RowData> {
        Arc::new(Self::empty(columns))
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
    /// 行数据（COW: Arc 共享，clone 只复制指针）
    rows: Vec<Arc<RowData>>,
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
    /// # 映射公式（优化后）
    /// ```
    /// array_index = screen_line
    /// ```
    ///
    /// # 说明
    /// 优化后的快照只包含可见行（display_offset + screen_lines），
    /// 数组索引直接对应屏幕行号：
    /// - rows[0] = 屏幕第一行
    /// - rows[1] = 屏幕第二行
    /// - ...
    ///
    /// display_offset 的处理已在 from_crosswords() 中完成，
    /// 快照的第一行就是当前可见的第一行。
    #[inline]
    fn screen_line_to_array_index(&self, screen_line: usize) -> Option<usize> {
        if screen_line >= self.screen_lines {
            return None;
        }

        // 优化后的映射：直接使用 screen_line 作为索引
        // rows 数组的布局：[可见行 0, 可见行 1, ..., 可见行 N-1]
        let array_index = screen_line;

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
            rows: (0..total_lines).map(|_| RowData::empty_arc(columns)).collect(),
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
            rows: (0..screen_lines).map(|_| RowData::empty_arc(columns)).collect(),
        }
    }

    /// 创建新的 GridData
    ///
    /// # 参数
    /// - `columns`: 列数
    /// - `screen_lines`: 屏幕行数
    /// - `history_size`: 历史缓冲区大小
    /// - `display_offset`: 滚动偏移
    /// - `rows`: 行数据
    /// - `row_hashes`: 行哈希列表
    pub fn new(
        columns: usize,
        screen_lines: usize,
        history_size: usize,
        display_offset: usize,
        rows: Vec<RowData>,
        row_hashes: Vec<u64>,
    ) -> Self {
        Self {
            columns,
            screen_lines,
            history_size,
            display_offset,
            rows: rows.into_iter().map(Arc::new).collect(),
            row_hashes,
        }
    }

    /// 获取行数据的 Arc（用于 COW）
    #[inline]
    pub fn row_arc(&self, index: usize) -> Option<&Arc<RowData>> {
        self.rows.get(index)
    }

    /// 创建带内容的 mock GridData（用于性能测试）
    ///
    /// 生成包含真实字符的测试数据，模拟终端典型内容
    #[cfg(test)]
    pub fn new_mock_with_content(columns: usize, screen_lines: usize) -> Self {
        use rio_backend::config::colors::{AnsiColor, NamedColor};
        use std::hash::{Hash, Hasher};

        // 典型终端内容：代码、命令行、日志等
        let sample_lines = [
            "fn main() { println!(\"Hello, World!\"); }",
            "$ cargo build --release",
            "[INFO] 2024-01-15 10:30:45 - Server started on port 8080",
            "error[E0382]: borrow of moved value: `x`",
            "const MAX_SIZE: usize = 1024 * 1024;",
            "impl Iterator for MyStruct { type Item = u32; }",
            "export PATH=\"$HOME/.cargo/bin:$PATH\"",
            "drwxr-xr-x  5 user staff  160 Jan 15 10:30 src",
            "git commit -m \"Fix: resolve memory leak in renderer\"",
            "这是中文测试文本，包含各种字符：你好世界！",
        ];

        let mut rows = Vec::with_capacity(screen_lines);
        let mut row_hashes = Vec::with_capacity(screen_lines);

        for line_idx in 0..screen_lines {
            let content = sample_lines[line_idx % sample_lines.len()];
            let mut cells = Vec::with_capacity(columns);

            // 使用不同颜色
            let colors = [
                AnsiColor::Named(NamedColor::Foreground),
                AnsiColor::Named(NamedColor::Green),
                AnsiColor::Named(NamedColor::Yellow),
                AnsiColor::Named(NamedColor::Red),
                AnsiColor::Named(NamedColor::Cyan),
            ];
            let fg = colors[line_idx % colors.len()];

            let mut col = 0;
            for c in content.chars() {
                if col >= columns {
                    break;
                }
                cells.push(CellData {
                    c,
                    fg,
                    bg: AnsiColor::Named(NamedColor::Background),
                    flags: 0,
                    zerowidth: Vec::new(),
                    underline_color: None,
                });
                col += 1;
            }

            // 填充剩余列为空格
            while cells.len() < columns {
                cells.push(CellData::default());
            }

            // 计算行哈希
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            content.hash(&mut hasher);
            line_idx.hash(&mut hasher);
            let hash = hasher.finish();

            rows.push(Arc::new(RowData {
                cells,
                content_hash: hash,
                urls: Vec::new(),
            }));
            row_hashes.push(hash);
        }

        Self {
            columns,
            screen_lines,
            history_size: 0,
            display_offset: 0,
            row_hashes,
            rows,
        }
    }

    /// 从 Crosswords 构造 GridData
    ///
    /// 优化：只快照可见区域（屏幕行 + 当前滚动偏移需要的历史行）
    /// 而不是整个历史缓冲区，大幅减少数据拷贝
    pub fn from_crosswords<T: EventListener>(crosswords: &Crosswords<T>) -> Self {
        let grid = &crosswords.grid;
        let display_offset = grid.display_offset();

        let columns = grid.columns();
        let screen_lines = grid.screen_lines();
        let history_size = grid.history_size();

        // 计算需要快照的行数范围
        // 如果 display_offset = 0（在底部），只需快照屏幕行
        // 如果 display_offset > 0（向上滚动），需要快照部分历史行
        let visible_lines = screen_lines + display_offset;

        // 收集可见行数据
        let mut rows = Vec::with_capacity(visible_lines);
        let mut row_hashes = Vec::with_capacity(visible_lines);

        // 遍历可见行（从需要显示的第一行开始）
        // Crosswords 的 Line 是 i32，Line(0) 是屏幕顶部，负数是历史缓冲区
        // 当 display_offset > 0 时，我们需要从 Line(-display_offset) 开始
        let start_line = -(display_offset as i32);
        let end_line = screen_lines as i32;

        for line_value in start_line..end_line {
            let line = Line(line_value);

            // 获取该行数据
            let row_data = Self::convert_row::<T>(grid, line, columns);
            row_hashes.push(row_data.content_hash);
            rows.push(Arc::new(row_data));
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

    /// 从 Crosswords 增量构造 GridData（COW 优化）
    ///
    /// 只更新变化的行，未变化的行共享 Arc
    ///
    /// # 参数
    /// - `crosswords`: 终端数据
    /// - `previous`: 上一帧的 GridData（用于复用未变化的行）
    /// - `damaged_lines`: 已损坏的行索引列表（需要重新转换）
    ///
    /// # 性能
    /// - 未变化的行：O(1)（Arc clone）
    /// - 变化的行：O(columns)（需要转换）
    pub fn incremental_from_crosswords<T: EventListener>(
        crosswords: &Crosswords<T>,
        previous: &GridData,
        damaged_lines: &[usize],
    ) -> Self {
        let grid = &crosswords.grid;
        let display_offset = grid.display_offset();
        let columns = grid.columns();
        let screen_lines = grid.screen_lines();
        let history_size = grid.history_size();

        // 如果尺寸变化或 display_offset 变化，回退到全量构建
        if screen_lines != previous.screen_lines
            || columns != previous.columns
            || display_offset != previous.display_offset
        {
            return Self::from_crosswords(crosswords);
        }

        // COW: 复用未变化的行
        let mut rows = Vec::with_capacity(screen_lines);
        let mut row_hashes = Vec::with_capacity(screen_lines);

        let start_line = -(display_offset as i32);

        for screen_line in 0..screen_lines {
            if damaged_lines.contains(&screen_line) {
                // 脏行：需要重新转换
                let line = Line(start_line + screen_line as i32);
                let row_data = Self::convert_row::<T>(grid, line, columns);
                row_hashes.push(row_data.content_hash);
                rows.push(Arc::new(row_data));
            } else {
                // 干净行：复用 Arc（O(1)）
                rows.push(previous.rows[screen_line].clone());
                row_hashes.push(previous.row_hashes[screen_line]);
            }
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
    fn convert_row<T>(
        grid: &rio_backend::crosswords::grid::Grid<rio_backend::crosswords::square::Square>,
        line: Line,
        columns: usize,
    ) -> RowData {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut cells = Vec::with_capacity(columns);
        let mut hasher = DefaultHasher::new();
        let mut row_text = String::with_capacity(columns);

        // 遍历该行的所有列
        for col_index in 0..columns {
            let col = Column(col_index);
            let square = &grid[line][col];

            // 收集行文本用于 URL 检测
            row_text.push(square.c);

            // 转换 cell 数据
            let cell = CellData {
                c: square.c,
                fg: square.fg,
                bg: square.bg,
                flags: square.flags.bits(),
                // 复制零宽字符（如 VS16 emoji 变体选择符）
                zerowidth: square.zerowidth()
                    .map(|chars| chars.to_vec())
                    .unwrap_or_default(),
                underline_color: square.underline_color(),
            };

            // 计算 hash（字符内容 + 颜色 + 样式 flags）
            // 颜色变化（如选择高亮）和 flags 变化都需要触发重绘
            cell.c.hash(&mut hasher);
            cell.fg.hash(&mut hasher);
            cell.bg.hash(&mut hasher);
            cell.flags.hash(&mut hasher);

            cells.push(cell);
        }

        let content_hash = hasher.finish();

        // 检测 URL（使用预编译的正则，性能开销很小）
        let urls = detect_urls(&row_text);

        RowData {
            cells,
            content_hash,
            urls,
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

    // ========================================================================
    // URL 检测测试
    // ========================================================================

    /// 测试：检测简单的 HTTP URL
    #[test]
    fn test_detect_urls_simple_http() {
        let text = "Visit http://example.com for more info";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].uri, "http://example.com");
        assert_eq!(urls[0].start_col, 6);  // "Visit " = 6 chars
        assert_eq!(urls[0].end_col, 23);   // end of URL
    }

    /// 测试：检测 HTTPS URL
    #[test]
    fn test_detect_urls_https() {
        let text = "Check https://github.com/user/repo";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].uri, "https://github.com/user/repo");
        assert_eq!(urls[0].start_col, 6);
    }

    /// 测试：一行中有多个 URL
    #[test]
    fn test_detect_urls_multiple() {
        let text = "http://a.com and https://b.com";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 2);
        assert_eq!(urls[0].uri, "http://a.com");
        assert_eq!(urls[1].uri, "https://b.com");
    }

    /// 测试：没有 URL 的文本
    #[test]
    fn test_detect_urls_none() {
        let text = "No URLs here, just plain text";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 0);
    }

    /// 测试：URL 在行首
    #[test]
    fn test_detect_urls_at_start() {
        let text = "https://start.com is at the beginning";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].start_col, 0);
        assert_eq!(urls[0].uri, "https://start.com");
    }

    /// 测试：URL 在行尾
    #[test]
    fn test_detect_urls_at_end() {
        let text = "End with https://end.com";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].uri, "https://end.com");
    }

    /// 测试：URL 带路径和查询参数
    #[test]
    fn test_detect_urls_with_path_and_query() {
        let text = "API: https://api.example.com/v1/users?id=123&sort=name";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].uri, "https://api.example.com/v1/users?id=123&sort=name");
    }

    /// 测试：URL 后面紧跟标点（应该不包含标点）
    #[test]
    fn test_detect_urls_followed_by_punctuation() {
        // 尾部标点应该被移除
        let text = "See https://example.com, for details.";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        // 验证逗号被移除
        assert_eq!(urls[0].uri, "https://example.com");
    }

    /// 测试：各种尾部标点都应该被移除
    #[test]
    fn test_detect_urls_trim_various_punctuation() {
        // 句号
        let urls = detect_urls("Visit https://example.com.");
        assert_eq!(urls[0].uri, "https://example.com");

        // 感叹号
        let urls = detect_urls("Check https://example.com!");
        assert_eq!(urls[0].uri, "https://example.com");

        // 问号（URL 中的有效字符，但作为句子结尾时应移除）
        let urls = detect_urls("Is it https://example.com?");
        assert_eq!(urls[0].uri, "https://example.com");

        // 右括号
        let urls = detect_urls("(see https://example.com)");
        assert_eq!(urls[0].uri, "https://example.com");

        // 多个标点
        let urls = detect_urls("Really? https://example.com...");
        assert_eq!(urls[0].uri, "https://example.com");
    }

    /// 测试：验证 end_col 在移除尾部标点后正确调整
    #[test]
    fn test_detect_urls_end_col_after_trim() {
        // "See https://example.com, for"
        //  0123456789...
        // URL 从位置 4 开始，"https://example.com" 有 19 个字符
        // 所以 end_col 应该是 4 + 19 - 1 = 22
        let text = "See https://example.com, for";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].start_col, 4); // "See " = 4 个字符
        assert_eq!(urls[0].end_col, 22);  // 4 + 19 - 1 = 22 (不包含逗号)
        assert_eq!(urls[0].uri, "https://example.com");

        // 验证逗号在位置 23
        let chars: Vec<char> = text.chars().collect();
        assert_eq!(chars[23], ',');
        // 验证 'm' 在位置 22
        assert_eq!(chars[22], 'm');
    }

    /// 测试：包含中文的文本中的 URL
    #[test]
    fn test_detect_urls_with_chinese() {
        let text = "访问 https://example.com 获取更多信息";
        let urls = detect_urls(text);

        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].uri, "https://example.com");
        // 中文字符按字符计数
        assert_eq!(urls[0].start_col, 3);  // "访问 " = 3 chars
    }

    /// 测试：空字符串
    #[test]
    fn test_detect_urls_empty_string() {
        let urls = detect_urls("");
        assert_eq!(urls.len(), 0);
    }
}
