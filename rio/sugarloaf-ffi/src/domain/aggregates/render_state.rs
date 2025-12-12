//! RenderState - 渲染状态
//!
//! 职责：存储可渲染的终端状态
//!
//! 设计原则：
//! - 渲染线程独占，无需锁
//! - 通过消费 RenderEvent 更新状态
//! - 提供只读访问给渲染器

use rio_backend::ansi::CursorShape;
use rio_backend::config::colors::{AnsiColor, NamedColor};
use rio_backend::crosswords::pos::{Column, Line};
use rio_backend::crosswords::square::Flags;
use std::ops::Range;

use crate::domain::events::{CellData, LineClearMode, RenderEvent, ScreenClearMode};

/// 默认历史缓冲区大小
const DEFAULT_HISTORY_SIZE: usize = 10_000;

/// 渲染状态
///
/// 渲染线程独占的终端状态，通过消费 RenderEvent 更新
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
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            c: ' ',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
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
        }
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
        }
    }

    /// 应用单个渲染事件
    pub fn apply_event(&mut self, event: RenderEvent) {
        match event {
            RenderEvent::CharInput { line, col, c, fg, bg, flags } => {
                let grid = self.active_grid_mut();
                grid.set_cell(line, col, Cell { c, fg, bg, flags });
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
}
