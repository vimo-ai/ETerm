//! Terminal Aggregate Root
//!
//! 职责：终端聚合根，管理终端状态和行为
//!
//! 核心原则：
//! - 充血模型：包含所有终端行为
//! - 封装 Crosswords：不暴露底层实现
//! - 提供 state() 方法：返回只读快照

#[cfg(feature = "new_architecture")]
use rio_backend::crosswords::Crosswords;
#[cfg(feature = "new_architecture")]
use rio_backend::crosswords::grid::Dimensions;
#[cfg(feature = "new_architecture")]
use rio_backend::event::EventListener;
#[cfg(feature = "new_architecture")]
use rio_backend::event::{RioEvent as BackendRioEvent, WindowId};
#[cfg(feature = "new_architecture")]
use rio_backend::ansi::CursorShape;
#[cfg(feature = "new_architecture")]
use std::sync::Arc;
#[cfg(feature = "new_architecture")]
use parking_lot::RwLock;

#[cfg(feature = "new_architecture")]
use crate::domain::state::TerminalState;
#[cfg(feature = "new_architecture")]
use crate::domain::events::TerminalEvent;
#[cfg(feature = "new_architecture")]
use crate::domain::views::{GridData, GridView, CursorView};

/// Terminal ID
#[cfg(feature = "new_architecture")]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalId(pub usize);

/// 事件收集器（用于从 Crosswords 收集事件）
#[cfg(feature = "new_architecture")]
#[derive(Clone)]
struct EventCollector {
    events: Arc<RwLock<Vec<TerminalEvent>>>,
}

#[cfg(feature = "new_architecture")]
impl EventCollector {
    fn new() -> Self {
        Self {
            events: Arc::new(RwLock::new(Vec::new())),
        }
    }

    fn take_events(&self) -> Vec<TerminalEvent> {
        self.events.write().drain(..).collect()
    }
}

/// 实现 rio_backend::event::EventListener trait
#[cfg(feature = "new_architecture")]
impl EventListener for EventCollector {
    fn event(&self) -> (Option<BackendRioEvent>, bool) {
        (None, false)
    }

    fn send_event(&self, event: BackendRioEvent, _id: WindowId) {
        let terminal_event = match event {
            BackendRioEvent::Wakeup(_) => TerminalEvent::Wakeup,
            BackendRioEvent::Title(title) => TerminalEvent::Title(title),
            BackendRioEvent::Exit => TerminalEvent::Exit,
            BackendRioEvent::Bell => TerminalEvent::Bell,
            _ => return, // 忽略其他事件
        };

        self.events.write().push(terminal_event);
    }
}

/// 简单的 Dimensions 实现（用于测试）
#[cfg(feature = "new_architecture")]
struct SimpleDimensions {
    columns: usize,
    screen_lines: usize,
    history_size: usize,
}

#[cfg(feature = "new_architecture")]
impl Dimensions for SimpleDimensions {
    fn total_lines(&self) -> usize {
        self.history_size + self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

/// Terminal 聚合根
#[cfg(feature = "new_architecture")]
pub struct Terminal {
    /// 终端 ID
    id: TerminalId,

    /// 终端状态（Crosswords）
    crosswords: Arc<RwLock<Crosswords<EventCollector>>>,

    /// 事件收集器
    event_collector: EventCollector,

    /// 列数
    cols: usize,

    /// 行数
    rows: usize,
}

#[cfg(feature = "new_architecture")]
impl Terminal {
    /// 创建新的 Terminal（暂时用于测试，不处理真实 PTY）
    pub fn new_for_test(id: TerminalId, cols: usize, rows: usize) -> Self {
        let event_collector = EventCollector::new();

        // 创建 Crosswords
        let dimensions = SimpleDimensions {
            columns: cols,
            screen_lines: rows,
            history_size: 10_000, // 默认历史行数（Crosswords 硬编码）
        };

        let window_id = WindowId::from(id.0 as u64);
        let route_id = id.0;

        let crosswords = Crosswords::new(
            dimensions,
            CursorShape::Block, // 默认光标形状
            event_collector.clone(),
            window_id,
            route_id,
        );

        Self {
            id,
            crosswords: Arc::new(RwLock::new(crosswords)),
            event_collector,
            cols,
            rows,
        }
    }

    /// 获取终端 ID
    pub fn id(&self) -> TerminalId {
        self.id
    }

    /// 获取列数
    pub fn cols(&self) -> usize {
        self.cols
    }

    /// 获取行数
    pub fn rows(&self) -> usize {
        self.rows
    }

    /// 写入数据到终端（ANSI 序列）
    ///
    /// # 参数
    /// - `data`: 要写入的字节数据（通常是 ANSI 转义序列）
    ///
    /// # 说明
    /// 这个方法会：
    /// 1. 将数据喂给 Processor 进行 ANSI 解析
    /// 2. Processor 调用 Crosswords (Handler trait) 更新内部 Grid 状态
    /// 3. 可能产生事件（通过 EventCollector）
    pub fn write(&mut self, data: &[u8]) {
        use rio_backend::performer::handler::{Processor, StdSyncHandler};

        // 创建临时 Processor（在真实实现中会作为 Terminal 的字段）
        let mut processor: Processor<StdSyncHandler> = Processor::new();
        let mut crosswords = self.crosswords.write();

        // 使用 processor 解析数据，Crosswords 实现了 Handler
        processor.advance(&mut *crosswords, data);
    }

    /// 调整终端大小
    ///
    /// # 参数
    /// - `cols`: 新的列数
    /// - `rows`: 新的行数
    pub fn resize(&mut self, cols: usize, rows: usize) {
        // 更新内部尺寸
        self.cols = cols;
        self.rows = rows;

        // 创建新的 Dimensions
        let new_size = SimpleDimensions {
            columns: cols,
            screen_lines: rows,
            history_size: 10_000, // 保持历史大小不变
        };

        // 调整 Crosswords 的大小（传值而不是引用）
        let mut crosswords = self.crosswords.write();
        crosswords.resize(new_size);

        // 注意：这里暂时不处理真实 PTY 的 resize
        // 真实 PTY 的 resize 会在 Phase 3 Step 4 (tick) 实现
    }

    /// 获取终端状态快照
    pub fn state(&self) -> TerminalState {
        let crosswords = self.crosswords.read();

        // 1. 转换 Grid
        let grid_data = GridData::from_crosswords(&*crosswords);
        let grid = GridView::new(Arc::new(grid_data));

        // 2. 转换 Cursor
        let cursor_pos = {
            use crate::domain::primitives::AbsolutePoint;
            let cursor = &crosswords.grid.cursor;
            let pos = cursor.pos;
            let display_offset = crosswords.grid.display_offset();
            let history_size = crosswords.grid.history_size();

            // 转换为绝对坐标
            let absolute_line = (history_size as i32 + pos.row.0 - display_offset as i32) as usize;
            AbsolutePoint::new(absolute_line, pos.col.0 as usize)
        };
        let cursor_shape = crosswords.cursor_shape;
        let cursor = CursorView::new(cursor_pos, cursor_shape);

        // 3. 转换 Selection（如果有）
        let selection = crosswords.selection.as_ref().and_then(|sel| {
            use crate::domain::primitives::AbsolutePoint;
            use crate::domain::views::SelectionType;

            // 获取选区范围（可能返回 None）
            sel.to_range(&crosswords).map(|sel_range| {
                let display_offset = crosswords.grid.display_offset();
                let history_size = crosswords.grid.history_size();

                // 转换为绝对坐标
                let start_line = (history_size as i32 + sel_range.start.row.0 - display_offset as i32) as usize;
                let end_line = (history_size as i32 + sel_range.end.row.0 - display_offset as i32) as usize;

                let start = AbsolutePoint::new(start_line, sel_range.start.col.0 as usize);
                let end = AbsolutePoint::new(end_line, sel_range.end.col.0 as usize);

                // 转换选区类型
                let ty = match sel.ty {
                    rio_backend::selection::SelectionType::Simple => SelectionType::Simple,
                    rio_backend::selection::SelectionType::Block => SelectionType::Block,
                    rio_backend::selection::SelectionType::Lines => SelectionType::Lines,
                    rio_backend::selection::SelectionType::Semantic => SelectionType::Simple, // Semantic 转为 Simple
                };

                crate::domain::views::SelectionView::new(start, end, ty)
            })
        });

        // 4. 转换 Search（暂时不实现）
        let search = None;

        // 构造 TerminalState
        if let Some(sel) = selection {
            TerminalState::with_selection(grid, cursor, sel)
        } else if let Some(srch) = search {
            TerminalState::with_search(grid, cursor, srch)
        } else {
            TerminalState::new(grid, cursor)
        }
    }
}

#[cfg(all(test, feature = "new_architecture"))]
mod tests {
    use super::*;

    #[test]
    fn test_terminal_creation() {
        let terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        assert_eq!(terminal.id(), TerminalId(1));
        assert_eq!(terminal.cols(), 80);
        assert_eq!(terminal.rows(), 24);
    }

    #[test]
    fn test_terminal_state() {
        let terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 获取状态快照
        let state = terminal.state();

        // 验证 Grid
        assert_eq!(state.grid.columns(), 80);
        // Crosswords 初始创建时只有 screen_lines，历史缓冲区是按需分配的
        // 所以初始 total_lines = screen_lines = 24
        assert_eq!(state.grid.lines(), 24);

        // 验证 Cursor（默认在屏幕第 0 行第 0 列）
        // 由于没有历史缓冲区，光标在第 0 行
        assert_eq!(state.cursor.position.line, 0);
        assert_eq!(state.cursor.position.col, 0);

        // 验证没有选区和搜索
        assert!(state.selection.is_none());
        assert!(state.search.is_none());
    }

    #[test]
    fn test_terminal_state_clone() {
        let terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        let state1 = terminal.state();
        let state2 = state1.clone();

        // Clone 应该是低成本的（Arc 共享）
        assert_eq!(state1.grid.columns(), state2.grid.columns());
        assert_eq!(state1.grid.lines(), state2.grid.lines());
    }

    #[test]
    fn test_write_ansi_sequence() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入简单文本 "Hello"
        terminal.write(b"Hello");

        // 获取状态
        let state = terminal.state();

        // 验证第一行包含 "Hello"
        // 注意：Crosswords 初始创建时，屏幕第一行就是索引 0（没有历史缓冲区）
        let grid = &state.grid;

        if let Some(row) = grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'H');
            assert_eq!(cells[1].c, 'e');
            assert_eq!(cells[2].c, 'l');
            assert_eq!(cells[3].c, 'l');
            assert_eq!(cells[4].c, 'o');
        } else {
            panic!("Failed to get first screen line");
        }
    }

    #[test]
    fn test_write_with_newline() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入 "Hello\r\nWorld"（CRLF，终端标准换行）
        terminal.write(b"Hello\r\nWorld");

        let state = terminal.state();
        let grid = &state.grid;

        // 验证第一行是 "Hello"
        if let Some(row1) = grid.row(0) {
            let cells = row1.cells();
            assert_eq!(cells[0].c, 'H');
            assert_eq!(cells[4].c, 'o');
        } else {
            panic!("Failed to get first line");
        }

        // 验证第二行是 "World"
        if let Some(row2) = grid.row(1) {
            let cells = row2.cells();
            assert_eq!(cells[0].c, 'W');
            assert_eq!(cells[4].c, 'd');
        } else {
            panic!("Failed to get second line");
        }
    }

    #[test]
    fn test_resize() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 初始状态
        assert_eq!(terminal.cols(), 80);
        assert_eq!(terminal.rows(), 24);

        let state_before = terminal.state();
        assert_eq!(state_before.grid.columns(), 80);

        // Resize
        terminal.resize(100, 30);

        // 验证新尺寸
        assert_eq!(terminal.cols(), 100);
        assert_eq!(terminal.rows(), 30);

        let state_after = terminal.state();
        assert_eq!(state_after.grid.columns(), 100);
        // 注意：Crosswords 初始创建时只有 screen_lines，没有历史缓冲区
        // resize 后也应该只有 screen_lines
        assert_eq!(state_after.grid.lines(), 30);
    }
}
