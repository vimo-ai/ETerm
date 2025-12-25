//! RenderState - 渲染状态
//!
//! 职责：存储可渲染的终端状态
//!
//! 设计原则：
//! - 渲染线程独占，无需锁
//! - 通过消费 RenderEvent 更新状态
//! - 支持从 Crosswords 增量同步（row_hash 对比）
//! - 提供只读访问给渲染器

use rio_backend::ansi::CursorShape;
use rio_backend::config::colors::{AnsiColor, NamedColor};
use rio_backend::crosswords::grid::Dimensions;
use rio_backend::crosswords::pos::{Column, Line};
use rio_backend::crosswords::square::Flags;
use rio_backend::crosswords::{Crosswords, Mode};
use rio_backend::event::{EventListener, TerminalDamage};
use smallvec::SmallVec;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::ops::Range;

use crate::domain::events::{CellData, LineClearMode, RenderEvent, ScreenClearMode};

/// 默认历史缓冲区大小
const DEFAULT_HISTORY_SIZE: usize = 10_000;

/// 渲染状态
///
/// 渲染线程独占的终端状态，支持两种更新模式：
/// 1. 事件驱动：通过消费 RenderEvent 更新
/// 2. 增量同步：通过 sync_from_crosswords() 从 Crosswords 同步变化行
pub struct RenderState {
    /// 网格数据（主屏幕）
    grid: Grid,

    /// 备用屏幕网格
    alt_grid: Grid,

    /// 是否在备用屏幕
    alt_screen: bool,

    /// 光标位置（行）
    cursor_line: Line,

    /// 光标位置（列）
    cursor_col: Column,

    /// 光标样式
    cursor_shape: CursorShape,

    /// 光标是否可见
    cursor_visible: bool,

    /// 当前属性（用于新字符）
    current_fg: AnsiColor,
    current_bg: AnsiColor,
    current_flags: Flags,

    /// 滚动区域
    scroll_region: Range<Line>,

    /// 显示偏移（滚动查看历史时非 0）
    display_offset: usize,

    /// 是否有脏区域需要重绘
    damaged: bool,

    /// 脏行标记
    dirty_lines: Vec<bool>,

    // ==================== 增量同步相关字段 ====================

    /// 上次同步时的行哈希（用于变化检测）
    synced_row_hashes: Vec<u64>,

    /// 上次同步时的 display_offset
    synced_display_offset: usize,

    /// 是否需要全量同步（首次或 resize 后）
    needs_full_sync: bool,
}

/// 网格数据
struct Grid {
    /// 列数
    columns: usize,

    /// 屏幕行数
    screen_lines: usize,

    /// 历史缓冲区最大行数
    history_size: usize,

    /// 所有行（历史 + 屏幕）
    /// 索引 0 是最旧的历史行，索引 history_size 是屏幕第一行
    lines: Vec<Vec<Cell>>,

    /// 当前历史行数（动态增长，最多 history_size）
    current_history_lines: usize,
}

/// 单元格数据
///
/// 使用 SmallVec 存储零宽字符，大多数情况下零分配（内联 2 个字符）
#[derive(Clone, Debug)]
pub struct Cell {
    /// 字符
    pub c: char,
    /// 前景色
    pub fg: AnsiColor,
    /// 背景色
    pub bg: AnsiColor,
    /// 标志位
    pub flags: Flags,
    /// 零宽字符（如 VS16 U+FE0F emoji 变体选择符）
    /// 使用 SmallVec 内联存储 2 个字符，超出时动态分配
    pub zerowidth: SmallVec<[char; 2]>,
    /// 下划线颜色（ANSI escape 支持自定义下划线颜色）
    pub underline_color: Option<AnsiColor>,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            c: ' ',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
            zerowidth: SmallVec::new(),
            underline_color: None,
        }
    }
}

impl From<CellData> for Cell {
    fn from(data: CellData) -> Self {
        Self {
            c: data.c,
            fg: data.fg,
            bg: data.bg,
            flags: data.flags,
            zerowidth: SmallVec::new(), // CellData 没有 zerowidth，同步时单独处理
            underline_color: None,
        }
    }
}

impl Cell {
    /// 从 Crosswords 的 Square 创建 Cell
    #[inline]
    pub fn from_square(square: &rio_backend::crosswords::square::Square) -> Self {
        Self {
            c: square.c,
            fg: square.fg,
            bg: square.bg,
            flags: square.flags,
            zerowidth: square
                .zerowidth()
                .map(|chars| SmallVec::from_iter(chars.iter().copied()))
                .unwrap_or_default(),
            underline_color: square.underline_color(),
        }
    }

    /// 计算 Cell 的哈希值（用于变化检测）
    #[inline]
    pub fn content_hash(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        self.c.hash(&mut hasher);
        self.fg.hash(&mut hasher);
        self.bg.hash(&mut hasher);
        self.flags.bits().hash(&mut hasher);
        // zerowidth 也参与哈希
        for &c in &self.zerowidth {
            c.hash(&mut hasher);
        }
        hasher.finish()
    }
}

impl Grid {
    /// 创建新的网格
    fn new(columns: usize, screen_lines: usize, history_size: usize) -> Self {
        let total_lines = screen_lines; // 初始只分配屏幕行，历史按需增长
        let lines = (0..total_lines)
            .map(|_| vec![Cell::default(); columns])
            .collect();

        Self {
            columns,
            screen_lines,
            history_size,
            lines,
            current_history_lines: 0,
        }
    }

    /// 获取总行数（历史 + 屏幕）
    #[inline]
    fn total_lines(&self) -> usize {
        self.lines.len()
    }

    /// 将 Grid Line 坐标转换为 lines 数组索引
    ///
    /// Grid Line 坐标系：
    /// - Line(-history_size) = 最旧的历史行
    /// - Line(0) = 屏幕第一行
    /// - Line(screen_lines - 1) = 屏幕最后一行
    #[inline]
    fn line_to_index(&self, line: Line) -> usize {
        // line.0 可能是负数（历史区域）
        let index = self.current_history_lines as i32 + line.0;
        index.max(0) as usize
    }

    /// 获取指定行（Grid Line 坐标）
    #[inline]
    fn get_line(&self, line: Line) -> Option<&Vec<Cell>> {
        let index = self.line_to_index(line);
        self.lines.get(index)
    }

    /// 获取指定行可变引用
    #[inline]
    fn get_line_mut(&mut self, line: Line) -> Option<&mut Vec<Cell>> {
        let index = self.line_to_index(line);
        self.lines.get_mut(index)
    }

    /// 设置单元格
    fn set_cell(&mut self, line: Line, col: Column, cell: Cell) {
        if let Some(row) = self.get_line_mut(line) {
            if (col.0) < row.len() {
                row[col.0] = cell;
            }
        }
    }

    /// 向上滚动（内容上移，底部出现新行）
    ///
    /// region: 滚动区域（Grid Line 坐标）
    /// count: 滚动行数
    fn scroll_up(&mut self, region: Range<Line>, count: usize) {
        let start = self.line_to_index(region.start);
        let end = self.line_to_index(region.end).min(self.lines.len());

        if start >= end || count == 0 {
            return;
        }

        let region_size = end - start;
        let scroll_count = count.min(region_size);

        // 如果是全屏滚动，将滚出的行保存到历史
        if region.start == Line(0) {
            for i in 0..scroll_count {
                let line_idx = start + i;
                if line_idx < self.lines.len() {
                    // 将行移动到历史（在当前行列表开头插入）
                    let scrolled_line = self.lines[line_idx].clone();

                    if self.current_history_lines < self.history_size {
                        // 历史未满，插入到开头
                        self.lines.insert(0, scrolled_line);
                        self.current_history_lines += 1;
                    } else {
                        // 历史已满，移除最旧的行，在历史末尾插入新行
                        self.lines.remove(0);
                        // 插入到 current_history_lines 位置之前
                        self.lines.insert(self.current_history_lines - 1, scrolled_line);
                    }
                }
            }
        }

        // 重新计算索引（因为历史行可能增加了）
        let start = self.line_to_index(region.start);
        let end = self.line_to_index(region.end).min(self.lines.len());

        // 移动区域内的行（跳过已保存到历史的行）
        // 从 start+scroll_count 开始的行向上移动 scroll_count 行
        for i in 0..(region_size - scroll_count) {
            let src = start + scroll_count + i;
            let dst = start + i;
            if src < self.lines.len() && dst < self.lines.len() {
                self.lines.swap(src, dst);
            }
        }

        // 清空底部的行
        for i in (end - scroll_count)..end {
            if i < self.lines.len() {
                self.lines[i] = vec![Cell::default(); self.columns];
            }
        }
    }

    /// 向下滚动（内容下移，顶部出现新行）
    fn scroll_down(&mut self, region: Range<Line>, count: usize) {
        let start = self.line_to_index(region.start);
        let end = self.line_to_index(region.end).min(self.lines.len());

        if start >= end || count == 0 {
            return;
        }

        let region_size = end - start;
        let scroll_count = count.min(region_size);

        // 从底部向上移动
        for i in (0..region_size - scroll_count).rev() {
            let src = start + i;
            let dst = start + i + scroll_count;
            if dst < end {
                self.lines.swap(src, dst);
            }
        }

        // 清空顶部的行
        for i in start..(start + scroll_count) {
            if i < self.lines.len() {
                self.lines[i] = vec![Cell::default(); self.columns];
            }
        }
    }

    /// 清除行
    fn clear_line(&mut self, line: Line, mode: LineClearMode, cursor_col: Column) {
        if let Some(row) = self.get_line_mut(line) {
            match mode {
                LineClearMode::Right => {
                    // 清除光标右侧（含光标位置）
                    for i in cursor_col.0..row.len() {
                        row[i] = Cell::default();
                    }
                }
                LineClearMode::Left => {
                    // 清除光标左侧（含光标位置）
                    for i in 0..=cursor_col.0.min(row.len().saturating_sub(1)) {
                        row[i] = Cell::default();
                    }
                }
                LineClearMode::All => {
                    // 清除整行
                    for cell in row.iter_mut() {
                        *cell = Cell::default();
                    }
                }
            }
        }
    }

    /// 清屏
    fn clear_screen(&mut self, mode: ScreenClearMode, cursor_line: Line, cursor_col: Column) {
        match mode {
            ScreenClearMode::Below => {
                // 清除光标下方（含光标行）
                // 先清除当前行光标右侧
                self.clear_line(cursor_line, LineClearMode::Right, cursor_col);
                // 清除下方所有行
                for i in (cursor_line.0 + 1)..(self.screen_lines as i32) {
                    self.clear_line(Line(i), LineClearMode::All, Column(0));
                }
            }
            ScreenClearMode::Above => {
                // 清除光标上方（含光标行）
                // 清除上方所有行
                for i in 0..cursor_line.0 {
                    self.clear_line(Line(i), LineClearMode::All, Column(0));
                }
                // 清除当前行光标左侧
                self.clear_line(cursor_line, LineClearMode::Left, cursor_col);
            }
            ScreenClearMode::All => {
                // 清除整个屏幕
                for i in 0..(self.screen_lines as i32) {
                    self.clear_line(Line(i), LineClearMode::All, Column(0));
                }
            }
            ScreenClearMode::Saved => {
                // 清除历史缓冲区
                if self.current_history_lines > 0 {
                    self.lines.drain(0..self.current_history_lines);
                    self.current_history_lines = 0;
                }
            }
        }
    }

    /// 调整大小
    fn resize(&mut self, new_columns: usize, new_screen_lines: usize) {
        // 调整列数
        if new_columns != self.columns {
            for row in &mut self.lines {
                row.resize(new_columns, Cell::default());
            }
            self.columns = new_columns;
        }

        // 调整屏幕行数
        if new_screen_lines > self.screen_lines {
            // 增加行
            let add_count = new_screen_lines - self.screen_lines;
            for _ in 0..add_count {
                self.lines.push(vec![Cell::default(); self.columns]);
            }
        } else if new_screen_lines < self.screen_lines {
            // 减少行（移动到历史或丢弃）
            let remove_count = self.screen_lines - new_screen_lines;
            for _ in 0..remove_count {
                if self.lines.len() > new_screen_lines {
                    // 移除屏幕顶部的行
                    if self.current_history_lines < self.history_size {
                        // 还有历史空间，保留
                        self.current_history_lines += 1;
                    } else {
                        // 历史已满，移除最旧的
                        self.lines.remove(0);
                    }
                }
            }
        }

        self.screen_lines = new_screen_lines;
    }
}

impl RenderState {
    /// 创建新的渲染状态
    pub fn new(columns: usize, rows: usize) -> Self {
        let grid = Grid::new(columns, rows, DEFAULT_HISTORY_SIZE);
        let alt_grid = Grid::new(columns, rows, 0); // 备用屏幕无历史

        Self {
            grid,
            alt_grid,
            alt_screen: false,
            cursor_line: Line(0),
            cursor_col: Column(0),
            cursor_shape: CursorShape::Block,
            cursor_visible: true,
            current_fg: AnsiColor::Named(NamedColor::Foreground),
            current_bg: AnsiColor::Named(NamedColor::Background),
            current_flags: Flags::empty(),
            scroll_region: Line(0)..Line(rows as i32),
            display_offset: 0,
            damaged: true,
            dirty_lines: vec![true; rows],
            // 增量同步字段
            synced_row_hashes: vec![0; rows],
            synced_display_offset: 0,
            needs_full_sync: true, // 首次需要全量同步
        }
    }

    // ==================== 增量同步 API ====================

    /// 从 Crosswords 增量同步变化
    ///
    /// 返回是否有变化（用于决定是否需要渲染）
    ///
    /// # 同步策略
    /// 1. 如果 needs_full_sync 为 true，全量同步
    /// 2. 如果 display_offset 变化（滚动），使用行移位 + 部分同步
    /// 3. 否则，逐行对比 row_hash，只同步变化的行
    pub fn sync_from_crosswords<T: EventListener>(
        &mut self,
        crosswords: &Crosswords<T>,
    ) -> bool {
        let grid = &crosswords.grid;
        let new_display_offset = grid.display_offset();
        let screen_lines = grid.screen_lines();
        let columns = grid.columns();

        // 检测 alt_screen 切换
        let new_alt_screen = crosswords.mode().contains(Mode::ALT_SCREEN);
        if new_alt_screen != self.alt_screen {
            self.alt_screen = new_alt_screen;
            self.needs_full_sync = true;
        }

        // 检测尺寸变化
        if screen_lines != self.screen_lines() || columns != self.columns() {
            self.handle_resize(columns, screen_lines);
            self.needs_full_sync = true;
        }

        // 情况 1：需要全量同步
        if self.needs_full_sync {
            self.full_sync(crosswords);
            self.needs_full_sync = false;
            return true;
        }

        // 情况 2：display_offset 变化（滚动）
        if new_display_offset != self.synced_display_offset {
            return self.handle_scroll(crosswords, new_display_offset);
        }

        // 情况 3：逐行对比，增量同步
        self.incremental_sync(crosswords)
    }

    /// 全量同步所有可见行
    fn full_sync<T: EventListener>(&mut self, crosswords: &Crosswords<T>) {
        let grid = &crosswords.grid;
        let screen_lines = grid.screen_lines();
        let columns = grid.columns();
        let display_offset = grid.display_offset();

        // 同步光标状态
        self.sync_cursor(crosswords);

        // 确保 synced_row_hashes 有正确的大小
        self.synced_row_hashes.resize(screen_lines, 0);

        // 同步所有可见行，并更新行哈希
        for screen_line in 0..screen_lines {
            let grid_line = Line(screen_line as i32 - display_offset as i32);
            self.sync_row_from_crosswords(crosswords, screen_line, grid_line, columns);
            // 更新行哈希，避免下一帧再次判定为脏
            let hash = self.compute_row_hash_from_crosswords(crosswords, grid_line, columns);
            self.synced_row_hashes[screen_line] = hash;
        }

        self.synced_display_offset = display_offset;
        self.needs_full_sync = false;  // 全量同步完成，重置标记
        self.mark_all_dirty();
    }

    /// 增量同步变化的行
    ///
    /// 优化：利用 Crosswords 的 damage 信息，只处理真正变化的行
    /// 避免每帧计算所有行的哈希（O(rows * columns) -> O(脏行数 * columns)）
    fn incremental_sync<T: EventListener>(&mut self, crosswords: &Crosswords<T>) -> bool {
        let grid = &crosswords.grid;
        let columns = grid.columns();
        let display_offset = grid.display_offset();

        let mut changed = false;

        // 同步光标状态（光标移动也需要检测）
        let cursor_changed = self.sync_cursor(crosswords);
        if cursor_changed {
            changed = true;
        }

        // 利用 Crosswords 的 damage 信息，只处理脏行
        match crosswords.peek_damage_event() {
            Some(TerminalDamage::Full) => {
                // 全量同步（罕见情况，如 resize、alt_screen 切换等）
                self.full_sync(crosswords);
                return true;
            }
            Some(TerminalDamage::Partial(damaged_lines)) => {
                // 只同步脏行（常见情况：单行或少量行变化）
                for line_damage in damaged_lines.iter() {
                    if line_damage.damaged {
                        let screen_line = line_damage.line;
                        let grid_line = Line(screen_line as i32 - display_offset as i32);

                        // 同步该行数据
                        self.sync_row_from_crosswords(crosswords, screen_line, grid_line, columns);

                        // 更新行哈希（用于后续对比）
                        let new_hash =
                            self.compute_row_hash_from_crosswords(crosswords, grid_line, columns);
                        if screen_line < self.synced_row_hashes.len() {
                            self.synced_row_hashes[screen_line] = new_hash;
                        }

                        self.mark_line_dirty(Line(screen_line as i32));
                        changed = true;
                    }
                }
            }
            Some(TerminalDamage::CursorOnly) => {
                // 只有光标变化，不需要同步任何行数据
                // cursor_changed 已在上面处理
            }
            None => {
                // 无变化，跳过
            }
        }

        changed
    }

    /// 处理滚动（display_offset 变化）
    fn handle_scroll<T: EventListener>(
        &mut self,
        crosswords: &Crosswords<T>,
        new_offset: usize,
    ) -> bool {
        let delta = new_offset as i32 - self.synced_display_offset as i32;
        let screen_lines = self.screen_lines();

        if delta.abs() as usize >= screen_lines {
            // 滚动太大，全量同步
            self.full_sync(crosswords);
        } else if delta > 0 {
            // 向上滚动（查看历史）：内容下移，顶部露出新行
            self.shift_rows_down(delta as usize);
            // 同步新露出的顶部行
            let grid = &crosswords.grid;
            let columns = grid.columns();
            for i in 0..(delta as usize) {
                let screen_line = i;
                let grid_line = Line(screen_line as i32 - new_offset as i32);
                self.sync_row_from_crosswords(crosswords, screen_line, grid_line, columns);
                let new_hash = self.compute_row_hash_from_crosswords(crosswords, grid_line, columns);
                if screen_line < self.synced_row_hashes.len() {
                    self.synced_row_hashes[screen_line] = new_hash;
                }
            }
        } else {
            // 向下滚动（回到底部）：内容上移，底部露出新行
            let shift = (-delta) as usize;
            self.shift_rows_up(shift);
            // 同步新露出的底部行
            let grid = &crosswords.grid;
            let columns = grid.columns();
            for i in 0..shift {
                let screen_line = screen_lines - 1 - i;
                let grid_line = Line(screen_line as i32 - new_offset as i32);
                self.sync_row_from_crosswords(crosswords, screen_line, grid_line, columns);
                let new_hash = self.compute_row_hash_from_crosswords(crosswords, grid_line, columns);
                if screen_line < self.synced_row_hashes.len() {
                    self.synced_row_hashes[screen_line] = new_hash;
                }
            }
        }

        self.synced_display_offset = new_offset;
        self.display_offset = new_offset;
        self.mark_all_dirty();
        true
    }

    /// 行向上移位（用于向下滚动）
    fn shift_rows_up(&mut self, count: usize) {
        let grid = self.active_grid_mut();
        if count > 0 && count < grid.lines.len() {
            grid.lines.rotate_left(count);
            self.synced_row_hashes.rotate_left(count);
        }
    }

    /// 行向下移位（用于向上滚动）
    fn shift_rows_down(&mut self, count: usize) {
        let grid = self.active_grid_mut();
        if count > 0 && count < grid.lines.len() {
            grid.lines.rotate_right(count);
            self.synced_row_hashes.rotate_right(count);
        }
    }

    /// 同步单行数据
    fn sync_row_from_crosswords<T: EventListener>(
        &mut self,
        crosswords: &Crosswords<T>,
        screen_line: usize,
        grid_line: Line,
        columns: usize,
    ) {
        let crosswords_grid = &crosswords.grid;

        // 获取目标行
        let target_grid = self.active_grid_mut();
        let target_line = Line(screen_line as i32);

        if let Some(target_row) = target_grid.get_line_mut(target_line) {
            // 确保行长度正确
            target_row.resize(columns, Cell::default());

            // 复制每个单元格
            for col in 0..columns {
                let col_idx = Column(col);
                let square = &crosswords_grid[grid_line][col_idx];
                target_row[col] = Cell::from_square(square);
            }
        }
    }

    /// 计算 Crosswords 中一行的哈希值
    fn compute_row_hash_from_crosswords<T: EventListener>(
        &self,
        crosswords: &Crosswords<T>,
        grid_line: Line,
        columns: usize,
    ) -> u64 {
        let grid = &crosswords.grid;
        let mut hasher = DefaultHasher::new();

        for col in 0..columns {
            let col_idx = Column(col);
            let square = &grid[grid_line][col_idx];
            square.c.hash(&mut hasher);
            square.fg.hash(&mut hasher);
            square.bg.hash(&mut hasher);
            square.flags.bits().hash(&mut hasher);
            // 下划线颜色也参与哈希
            if let Some(underline_color) = square.underline_color() {
                underline_color.hash(&mut hasher);
            }
            // 零宽字符也参与哈希
            if let Some(zerowidth) = square.zerowidth() {
                for &c in zerowidth {
                    c.hash(&mut hasher);
                }
            }
        }

        hasher.finish()
    }

    /// 同步光标状态，返回是否有变化
    fn sync_cursor<T: EventListener>(&mut self, crosswords: &Crosswords<T>) -> bool {
        let cursor = &crosswords.grid.cursor;
        let new_line = cursor.pos.row;
        let new_col = cursor.pos.col;

        // 获取光标可见性（考虑 SHOW_CURSOR 模式）
        let cursor_state = crosswords.cursor();
        let new_visible = cursor_state.is_visible();
        let new_shape = cursor_state.content;

        let changed = self.cursor_line != new_line
            || self.cursor_col != new_col
            || self.cursor_visible != new_visible
            || self.cursor_shape != new_shape;

        if changed {
            // 标记旧位置和新位置为脏
            self.mark_line_dirty(self.cursor_line);
            self.cursor_line = new_line;
            self.cursor_col = new_col;
            self.cursor_visible = new_visible;
            self.cursor_shape = new_shape;
            self.mark_line_dirty(new_line);
        }

        changed
    }

    /// 处理尺寸变化
    pub fn handle_resize(&mut self, new_cols: usize, new_rows: usize) {
        self.grid.resize(new_cols, new_rows);
        self.alt_grid.resize(new_cols, new_rows);
        self.scroll_region = Line(0)..Line(new_rows as i32);
        self.dirty_lines.resize(new_rows, true);
        self.synced_row_hashes.resize(new_rows, 0);
        // 重置同步状态，下次 sync 时进行全量同步
        self.needs_full_sync = true;
        self.synced_display_offset = 0;  // 重置偏移，避免滚动分支做错误的 rotate
        self.mark_all_dirty();
    }

    /// 获取同步后的行哈希（供渲染器缓存使用）
    #[inline]
    pub fn get_row_hash(&self, screen_line: usize) -> Option<u64> {
        self.synced_row_hashes.get(screen_line).copied()
    }

    /// 应用单个渲染事件
    pub fn apply_event(&mut self, event: RenderEvent) {
        match event {
            RenderEvent::CharInput { line, col, c, fg, bg, flags } => {
                let grid = self.active_grid_mut();
                grid.set_cell(line, col, Cell {
                    c,
                    fg,
                    bg,
                    flags,
                    zerowidth: SmallVec::new(),
                    underline_color: None,
                });
                self.mark_line_dirty(line);
            }

            RenderEvent::CellsUpdate { line, start_col, cells } => {
                let grid = self.active_grid_mut();
                for (i, cell_data) in cells.into_iter().enumerate() {
                    let col = Column(start_col.0 + i);
                    grid.set_cell(line, col, cell_data.into());
                }
                self.mark_line_dirty(line);
            }

            RenderEvent::CursorMove { line, col } => {
                self.mark_line_dirty(self.cursor_line);
                self.cursor_line = line;
                self.cursor_col = col;
                self.mark_line_dirty(line);
            }

            RenderEvent::CursorStyle { shape } => {
                self.cursor_shape = shape;
                self.mark_line_dirty(self.cursor_line);
            }

            RenderEvent::CursorVisible { visible } => {
                self.cursor_visible = visible;
                self.mark_line_dirty(self.cursor_line);
            }

            RenderEvent::LineFeed => {
                // 换行：光标移到下一行
                let next_line = Line(self.cursor_line.0 + 1);
                let scroll_region = self.scroll_region.clone();
                if next_line >= scroll_region.end {
                    // 需要滚动
                    let grid = self.active_grid_mut();
                    grid.scroll_up(scroll_region, 1);
                    self.mark_all_dirty();
                } else {
                    self.mark_line_dirty(self.cursor_line);
                    self.cursor_line = next_line;
                    self.mark_line_dirty(self.cursor_line);
                }
            }

            RenderEvent::CarriageReturn => {
                self.cursor_col = Column(0);
                self.mark_line_dirty(self.cursor_line);
            }

            RenderEvent::ClearLine { line, mode } => {
                let cursor_col = self.cursor_col;
                let grid = self.active_grid_mut();
                grid.clear_line(line, mode, cursor_col);
                self.mark_line_dirty(line);
            }

            RenderEvent::InsertLines { line, count } => {
                let region = line..self.scroll_region.end;
                let grid = self.active_grid_mut();
                grid.scroll_down(region, count);
                self.mark_all_dirty();
            }

            RenderEvent::DeleteLines { line, count } => {
                let region = line..self.scroll_region.end;
                let grid = self.active_grid_mut();
                grid.scroll_up(region, count);
                self.mark_all_dirty();
            }

            RenderEvent::ScrollUp { region, lines } => {
                let grid = self.active_grid_mut();
                grid.scroll_up(region, lines);
                self.mark_all_dirty();
            }

            RenderEvent::ScrollDown { region, lines } => {
                let grid = self.active_grid_mut();
                grid.scroll_down(region, lines);
                self.mark_all_dirty();
            }

            RenderEvent::ClearScreen { mode } => {
                let cursor_line = self.cursor_line;
                let cursor_col = self.cursor_col;
                let grid = self.active_grid_mut();
                grid.clear_screen(mode, cursor_line, cursor_col);
                self.mark_all_dirty();
            }

            RenderEvent::Resize { cols, rows } => {
                self.grid.resize(cols, rows);
                self.alt_grid.resize(cols, rows);
                self.scroll_region = Line(0)..Line(rows as i32);
                self.dirty_lines.resize(rows, true);
                self.mark_all_dirty();
            }

            RenderEvent::SetAttribute { fg, bg, flags } => {
                self.current_fg = fg;
                self.current_bg = bg;
                self.current_flags = flags;
            }

            RenderEvent::Damage { full, lines } => {
                if full {
                    self.mark_all_dirty();
                } else if let Some(range) = lines {
                    // Line 不实现 Step，手动迭代
                    let mut line = range.start.0;
                    while line < range.end.0 {
                        self.mark_line_dirty(Line(line));
                        line += 1;
                    }
                }
                self.damaged = true;
            }

            RenderEvent::EnterAltScreen => {
                if !self.alt_screen {
                    self.alt_screen = true;
                    self.mark_all_dirty();
                }
            }

            RenderEvent::ExitAltScreen => {
                if self.alt_screen {
                    self.alt_screen = false;
                    self.mark_all_dirty();
                }
            }
        }
    }

    /// 批量应用事件
    pub fn apply_events(&mut self, events: impl IntoIterator<Item = RenderEvent>) {
        for event in events {
            self.apply_event(event);
        }
    }

    /// 获取当前活跃的网格
    #[inline]
    fn active_grid(&self) -> &Grid {
        if self.alt_screen {
            &self.alt_grid
        } else {
            &self.grid
        }
    }

    /// 获取当前活跃的网格（可变）
    #[inline]
    fn active_grid_mut(&mut self) -> &mut Grid {
        if self.alt_screen {
            &mut self.alt_grid
        } else {
            &mut self.grid
        }
    }

    /// 标记指定行为脏
    #[inline]
    fn mark_line_dirty(&mut self, line: Line) {
        let index = line.0 as usize;
        if index < self.dirty_lines.len() {
            self.dirty_lines[index] = true;
        }
        self.damaged = true;
    }

    /// 标记所有行为脏
    #[inline]
    fn mark_all_dirty(&mut self) {
        self.dirty_lines.fill(true);
        self.damaged = true;
    }

    // ==================== 只读访问接口 ====================

    /// 获取列数
    #[inline]
    pub fn columns(&self) -> usize {
        self.active_grid().columns
    }

    /// 获取屏幕行数
    #[inline]
    pub fn screen_lines(&self) -> usize {
        self.active_grid().screen_lines
    }

    /// 获取历史行数
    #[inline]
    pub fn history_lines(&self) -> usize {
        self.grid.current_history_lines
    }

    /// 获取总行数
    #[inline]
    pub fn total_lines(&self) -> usize {
        self.active_grid().total_lines()
    }

    /// 获取显示偏移
    #[inline]
    pub fn display_offset(&self) -> usize {
        self.display_offset
    }

    /// 设置显示偏移（滚动查看历史）
    pub fn set_display_offset(&mut self, offset: usize) {
        let max_offset = self.history_lines();
        self.display_offset = offset.min(max_offset);
        self.mark_all_dirty();
    }

    /// 获取光标位置
    #[inline]
    pub fn cursor_position(&self) -> (Line, Column) {
        (self.cursor_line, self.cursor_col)
    }

    /// 获取光标样式
    #[inline]
    pub fn cursor_shape(&self) -> CursorShape {
        self.cursor_shape
    }

    /// 光标是否可见
    #[inline]
    pub fn cursor_visible(&self) -> bool {
        self.cursor_visible
    }

    /// 是否有脏区域
    #[inline]
    pub fn is_damaged(&self) -> bool {
        self.damaged
    }

    /// 重置脏标记
    #[inline]
    pub fn reset_damage(&mut self) {
        self.damaged = false;
        self.dirty_lines.fill(false);
    }

    /// 获取屏幕行（考虑 display_offset）
    ///
    /// screen_row: 0 = 屏幕顶部
    pub fn get_screen_row(&self, screen_row: usize) -> Option<&Vec<Cell>> {
        let grid = self.active_grid();
        // 考虑 display_offset
        let line = Line((screen_row as i32) - (self.display_offset as i32));
        grid.get_line(line)
    }

    /// 获取指定位置的单元格
    pub fn get_cell(&self, line: Line, col: Column) -> Option<&Cell> {
        let grid = self.active_grid();
        grid.get_line(line).and_then(|row| row.get(col.0))
    }

    /// 是否在备用屏幕
    #[inline]
    pub fn is_alt_screen(&self) -> bool {
        self.alt_screen
    }

    /// 获取滚动区域
    #[inline]
    pub fn scroll_region(&self) -> &Range<Line> {
        &self.scroll_region
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_state_new() {
        let state = RenderState::new(80, 24);
        assert_eq!(state.columns(), 80);
        assert_eq!(state.screen_lines(), 24);
        assert_eq!(state.cursor_position(), (Line(0), Column(0)));
        assert!(state.cursor_visible());
        assert!(state.is_damaged());
    }

    #[test]
    fn test_char_input() {
        let mut state = RenderState::new(80, 24);

        state.apply_event(RenderEvent::CharInput {
            line: Line(0),
            col: Column(0),
            c: 'H',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
        });

        let cell = state.get_cell(Line(0), Column(0)).unwrap();
        assert_eq!(cell.c, 'H');
    }

    #[test]
    fn test_cells_update() {
        let mut state = RenderState::new(80, 24);

        let cells = vec![
            CellData::new('H', AnsiColor::Named(NamedColor::Foreground), AnsiColor::Named(NamedColor::Background), Flags::empty()),
            CellData::new('i', AnsiColor::Named(NamedColor::Foreground), AnsiColor::Named(NamedColor::Background), Flags::empty()),
        ];

        state.apply_event(RenderEvent::CellsUpdate {
            line: Line(0),
            start_col: Column(0),
            cells,
        });

        assert_eq!(state.get_cell(Line(0), Column(0)).unwrap().c, 'H');
        assert_eq!(state.get_cell(Line(0), Column(1)).unwrap().c, 'i');
    }

    #[test]
    fn test_cursor_move() {
        let mut state = RenderState::new(80, 24);

        state.apply_event(RenderEvent::CursorMove {
            line: Line(5),
            col: Column(10),
        });

        assert_eq!(state.cursor_position(), (Line(5), Column(10)));
    }

    #[test]
    fn test_line_feed_without_scroll() {
        let mut state = RenderState::new(80, 24);

        state.apply_event(RenderEvent::CursorMove {
            line: Line(5),
            col: Column(0),
        });

        state.apply_event(RenderEvent::LineFeed);

        assert_eq!(state.cursor_position().0, Line(6));
    }

    #[test]
    fn test_carriage_return() {
        let mut state = RenderState::new(80, 24);

        state.apply_event(RenderEvent::CursorMove {
            line: Line(5),
            col: Column(10),
        });

        state.apply_event(RenderEvent::CarriageReturn);

        let (line, col) = state.cursor_position();
        assert_eq!(line, Line(5));
        assert_eq!(col, Column(0));
    }

    #[test]
    fn test_clear_line() {
        let mut state = RenderState::new(80, 24);

        // 写入一些字符
        for i in 0..10 {
            state.apply_event(RenderEvent::CharInput {
                line: Line(0),
                col: Column(i),
                c: 'X',
                fg: AnsiColor::Named(NamedColor::Foreground),
                bg: AnsiColor::Named(NamedColor::Background),
                flags: Flags::empty(),
            });
        }

        // 清除整行
        state.apply_event(RenderEvent::ClearLine {
            line: Line(0),
            mode: LineClearMode::All,
        });

        // 验证被清除
        for i in 0..10 {
            assert_eq!(state.get_cell(Line(0), Column(i)).unwrap().c, ' ');
        }
    }

    #[test]
    fn test_scroll_up() {
        let mut state = RenderState::new(80, 24);

        // 在第一行写入内容
        state.apply_event(RenderEvent::CharInput {
            line: Line(0),
            col: Column(0),
            c: 'A',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
        });

        // 向上滚动
        state.apply_event(RenderEvent::ScrollUp {
            region: Line(0)..Line(24),
            lines: 1,
        });

        // 原来第一行的内容现在应该在历史中
        // 当前屏幕第一行应该是空的
        // （历史缓冲区需要 display_offset 才能访问）
        assert_eq!(state.get_cell(Line(0), Column(0)).unwrap().c, ' ');
    }

    #[test]
    fn test_resize() {
        let mut state = RenderState::new(80, 24);

        state.apply_event(RenderEvent::Resize { cols: 100, rows: 30 });

        assert_eq!(state.columns(), 100);
        assert_eq!(state.screen_lines(), 30);
    }

    #[test]
    fn test_alt_screen() {
        let mut state = RenderState::new(80, 24);

        // 在主屏幕写入
        state.apply_event(RenderEvent::CharInput {
            line: Line(0),
            col: Column(0),
            c: 'M',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
        });

        // 切换到备用屏幕
        state.apply_event(RenderEvent::EnterAltScreen);
        assert!(state.is_alt_screen());

        // 备用屏幕应该是空的
        assert_eq!(state.get_cell(Line(0), Column(0)).unwrap().c, ' ');

        // 在备用屏幕写入
        state.apply_event(RenderEvent::CharInput {
            line: Line(0),
            col: Column(0),
            c: 'A',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
        });

        // 退出备用屏幕
        state.apply_event(RenderEvent::ExitAltScreen);
        assert!(!state.is_alt_screen());

        // 主屏幕内容应该恢复
        assert_eq!(state.get_cell(Line(0), Column(0)).unwrap().c, 'M');
    }

    #[test]
    fn test_clear_screen() {
        let mut state = RenderState::new(80, 24);

        // 写入内容
        for i in 0..10 {
            for j in 0..10 {
                state.apply_event(RenderEvent::CharInput {
                    line: Line(i),
                    col: Column(j as usize),
                    c: 'X',
                    fg: AnsiColor::Named(NamedColor::Foreground),
                    bg: AnsiColor::Named(NamedColor::Background),
                    flags: Flags::empty(),
                });
            }
        }

        // 清屏
        state.apply_event(RenderEvent::ClearScreen {
            mode: ScreenClearMode::All,
        });

        // 验证被清除
        for i in 0..10 {
            for j in 0..10 {
                assert_eq!(state.get_cell(Line(i), Column(j as usize)).unwrap().c, ' ');
            }
        }
    }

    #[test]
    fn test_damage_tracking() {
        let mut state = RenderState::new(80, 24);

        // 初始状态应该是脏的
        assert!(state.is_damaged());

        // 重置脏标记
        state.reset_damage();
        assert!(!state.is_damaged());

        // 写入字符应该标记为脏
        state.apply_event(RenderEvent::CharInput {
            line: Line(0),
            col: Column(0),
            c: 'X',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
        });
        assert!(state.is_damaged());
    }

    #[test]
    fn test_cursor_style() {
        let mut state = RenderState::new(80, 24);

        state.apply_event(RenderEvent::CursorStyle {
            shape: CursorShape::Beam,
        });

        assert_eq!(state.cursor_shape(), CursorShape::Beam);
    }

    #[test]
    fn test_cursor_visibility() {
        let mut state = RenderState::new(80, 24);

        assert!(state.cursor_visible());

        state.apply_event(RenderEvent::CursorVisible { visible: false });
        assert!(!state.cursor_visible());

        state.apply_event(RenderEvent::CursorVisible { visible: true });
        assert!(state.cursor_visible());
    }

    // ==================== sync_from_crosswords 测试 ====================

    use rio_backend::crosswords::CrosswordsSize;
    use rio_backend::event::VoidListener;
    use rio_backend::performer::handler::Handler; // 提供 input() 方法

    /// 辅助函数：创建测试用的 Crosswords
    fn create_test_crosswords(cols: usize, rows: usize) -> Crosswords<VoidListener> {
        let size = CrosswordsSize::new(cols, rows);
        let window_id = rio_backend::event::WindowId::from(0);
        Crosswords::new(size, CursorShape::Block, VoidListener {}, window_id, 0)
    }

    #[test]
    fn test_sync_from_crosswords_initial_full_sync() {
        // 首次同步应该触发全量同步
        let mut state = RenderState::new(80, 24);
        let cw = create_test_crosswords(80, 24);

        // 首次同步，needs_full_sync 应该为 true
        assert!(state.needs_full_sync);

        let changed = state.sync_from_crosswords(&cw);

        // 应该有变化（全量同步）
        assert!(changed);
        // 同步后 needs_full_sync 应该为 false
        assert!(!state.needs_full_sync);
    }

    #[test]
    fn test_sync_from_crosswords_no_change() {
        // 连续两次同步，第二次应该检测到无变化
        let mut state = RenderState::new(80, 24);
        let mut cw = create_test_crosswords(80, 24);

        // 首次同步
        state.sync_from_crosswords(&cw);

        // 模拟渲染完成后清除 damage 标记（实际渲染流程会做这一步）
        cw.reset_damage();

        // 第二次同步（无变化）
        let changed = state.sync_from_crosswords(&cw);

        // 应该无变化（因为 damage 已清除且没有新输入）
        assert!(!changed);
    }

    #[test]
    fn test_sync_from_crosswords_single_line_change() {
        // 修改单行后同步应该检测到变化
        let mut state = RenderState::new(80, 24);
        let mut cw = create_test_crosswords(80, 24);

        // 首次同步
        state.sync_from_crosswords(&cw);

        // 修改第一行
        cw.input('H');
        cw.input('e');
        cw.input('l');
        cw.input('l');
        cw.input('o');

        // 再次同步
        let changed = state.sync_from_crosswords(&cw);

        // 应该检测到变化
        assert!(changed);

        // 验证数据已同步
        let cell = state.get_cell(Line(0), Column(0)).unwrap();
        assert_eq!(cell.c, 'H');
    }

    #[test]
    fn test_sync_from_crosswords_cursor_movement() {
        // 光标移动应该触发变化
        let mut state = RenderState::new(80, 24);
        let mut cw = create_test_crosswords(80, 24);

        // 首次同步
        state.sync_from_crosswords(&cw);

        // 移动光标
        cw.goto(Line(5), Column(10));

        // 再次同步
        let changed = state.sync_from_crosswords(&cw);

        // 光标移动应该触发变化
        assert!(changed);

        // 验证光标位置已同步
        let (line, col) = state.cursor_position();
        assert_eq!(line, Line(5));
        assert_eq!(col, Column(10));
    }

    #[test]
    fn test_sync_from_crosswords_resize_triggers_full_sync() {
        // resize 后应该触发全量同步
        let mut state = RenderState::new(80, 24);
        let cw = create_test_crosswords(80, 24);

        // 首次同步
        state.sync_from_crosswords(&cw);
        assert!(!state.needs_full_sync);

        // 创建不同尺寸的 Crosswords
        let cw_resized = create_test_crosswords(100, 30);

        // 同步会触发 resize 处理
        let changed = state.sync_from_crosswords(&cw_resized);

        // 应该有变化
        assert!(changed);
        // 尺寸应该更新
        assert_eq!(state.columns(), 100);
        assert_eq!(state.screen_lines(), 30);
    }

    #[test]
    fn test_sync_from_crosswords_preserves_row_hashes() {
        // 同步后应该保存行哈希，用于下次变化检测
        let mut state = RenderState::new(80, 24);
        let mut cw = create_test_crosswords(80, 24);

        // 首次同步
        state.sync_from_crosswords(&cw);

        // 记录第一行的哈希
        let hash_before = state.get_row_hash(0);
        assert!(hash_before.is_some());

        // 修改第一行
        cw.input('X');

        // 再次同步
        state.sync_from_crosswords(&cw);

        // 哈希应该变化
        let hash_after = state.get_row_hash(0);
        assert!(hash_after.is_some());
        assert_ne!(hash_before, hash_after);
    }

    #[test]
    fn test_sync_from_crosswords_multiple_lines() {
        // 修改多行后同步
        let mut state = RenderState::new(80, 24);
        let mut cw = create_test_crosswords(80, 24);

        // 首次同步
        state.sync_from_crosswords(&cw);

        // 在不同行写入内容
        cw.goto(Line(0), Column(0));
        cw.input('A');
        cw.goto(Line(5), Column(0));
        cw.input('B');
        cw.goto(Line(10), Column(0));
        cw.input('C');

        // 再次同步
        let changed = state.sync_from_crosswords(&cw);
        assert!(changed);

        // 验证所有行都已同步
        assert_eq!(state.get_cell(Line(0), Column(0)).unwrap().c, 'A');
        assert_eq!(state.get_cell(Line(5), Column(0)).unwrap().c, 'B');
        assert_eq!(state.get_cell(Line(10), Column(0)).unwrap().c, 'C');
    }
}
