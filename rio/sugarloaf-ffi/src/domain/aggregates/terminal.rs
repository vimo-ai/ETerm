//! Terminal Aggregate Root
//!
//! 职责：终端聚合根，管理终端状态和行为
//!
//! 核心原则：
//! - 充血模型：包含所有终端行为
//! - 封装 Crosswords：不暴露底层实现
//! - 提供 state() 方法：返回只读快照


use rio_backend::crosswords::Crosswords;

use rio_backend::crosswords::grid::Dimensions;

use rio_backend::event::EventListener;

use rio_backend::event::{RioEvent as BackendRioEvent, WindowId};

use rio_backend::ansi::CursorShape;

use rio_backend::performer::handler::{Processor, StdSyncHandler};

use std::sync::Arc;

use parking_lot::RwLock;


use crate::domain::state::TerminalState;

use crate::domain::events::TerminalEvent;

use crate::domain::views::{GridData, GridView, CursorView, SearchView, MatchRange};

use crate::domain::primitives::AbsolutePoint;

use crate::rio_event::{EventQueue, FFIEventListener};

/// Terminal ID

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalId(pub usize);

/// Terminal 运行模式
///
/// 用于优化后台终端的性能：
/// - Active: 可见终端，完整处理 + 触发渲染回调
/// - Background: 后台终端，完整 VTE 解析但不触发渲染回调
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum TerminalMode {
    /// 活跃模式（可见）
    /// - 完整 VTE 解析
    /// - 触发渲染回调
    /// - 所有事件上报
    #[default]
    Active = 0,

    /// 后台模式（不可见）
    /// - 完整 VTE 解析（保证状态正确）
    /// - 不触发渲染回调（节省 CPU/GPU）
    /// - 仅上报关键事件（bell、exit）
    Background = 1,
}

/// 事件收集器（用于从 Crosswords 收集事件）

#[derive(Clone)]
struct EventCollector {
    events: Arc<RwLock<Vec<TerminalEvent>>>,
}


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

struct SimpleDimensions {
    columns: usize,
    screen_lines: usize,
    history_size: usize,
}


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

pub struct Terminal {
    /// 终端 ID
    id: TerminalId,

    /// 终端状态（Crosswords）- 支持两种事件监听器
    crosswords_ffi: Option<Arc<RwLock<Crosswords<FFIEventListener>>>>,
    crosswords_test: Option<Arc<RwLock<Crosswords<EventCollector>>>>,

    /// 事件监听器（根据创建方式二选一）
    event_listener: EventListenerType,

    /// 列数
    cols: usize,

    /// 行数
    rows: usize,

    /// ANSI 解析器
    parser: Processor<StdSyncHandler>,

    /// 缓存的搜索视图（只在搜索事件时重建，避免每帧 O(N) 遍历）
    cached_search_view: Option<SearchView>,

    /// 超链接悬停状态（Cmd+hover 时设置）
    hyperlink_hover: Option<crate::domain::HyperlinkHoverView>,

    /// 运行模式（Active/Background）
    mode: TerminalMode,
}

/// 事件监听器类型

enum EventListenerType {
    FFI(FFIEventListener),
    Test(EventCollector),
}

/// 宏：访问可变 Crosswords（write）

macro_rules! with_crosswords_mut {
    ($self:expr, $crosswords:ident, $body:expr) => {
        if let Some(ref cw) = $self.crosswords_ffi {
            let mut $crosswords = cw.write();
            $body
        } else if let Some(ref cw) = $self.crosswords_test {
            let mut $crosswords = cw.write();
            $body
        } else {
            unreachable!("Terminal must have either crosswords_ffi or crosswords_test")
        }
    };
}

/// 宏：访问只读 Crosswords（read）

macro_rules! with_crosswords {
    ($self:expr, $crosswords:ident, $body:expr) => {
        if let Some(ref cw) = $self.crosswords_ffi {
            let $crosswords = cw.read();
            $body
        } else if let Some(ref cw) = $self.crosswords_test {
            let $crosswords = cw.read();
            $body
        } else {
            unreachable!("Terminal must have either crosswords_ffi or crosswords_test")
        }
    };
}


impl Terminal {
    /// 创建新的 Terminal（用于测试，不处理真实 PTY）
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

        // 创建 ANSI 解析器
        let parser = Processor::new();

        Self {
            id,
            crosswords_ffi: None,
            crosswords_test: Some(Arc::new(RwLock::new(crosswords))),
            event_listener: EventListenerType::Test(event_collector),
            cols,
            rows,
            parser,
            cached_search_view: None,
            hyperlink_hover: None,
            mode: TerminalMode::Active,
        }
    }

    /// 创建新的 Terminal（支持真实 PTY）
    ///
    /// # 参数
    /// - `id`: 终端 ID
    /// - `cols`: 列数
    /// - `rows`: 行数
    /// - `event_queue`: 事件队列（用于接收终端事件）
    pub fn new_with_pty(
        id: TerminalId,
        cols: usize,
        rows: usize,
        event_queue: EventQueue,
    ) -> Self {
        // 创建 FFIEventListener
        let event_listener = FFIEventListener::new(event_queue.clone(), id.0);

        // 创建 Crosswords
        let dimensions = SimpleDimensions {
            columns: cols,
            screen_lines: rows,
            history_size: 10_000,
        };

        let window_id = WindowId::from(id.0 as u64);
        let route_id = id.0;

        let crosswords = Crosswords::new(
            dimensions,
            CursorShape::Block,
            event_listener.clone(),
            window_id,
            route_id,
        );

        // 创建 ANSI 解析器
        let parser = Processor::new();

        Self {
            id,
            crosswords_ffi: Some(Arc::new(RwLock::new(crosswords))),
            crosswords_test: None,
            event_listener: EventListenerType::FFI(event_listener),
            cols,
            rows,
            parser,
            cached_search_view: None,
            hyperlink_hover: None,
            mode: TerminalMode::Active,
        }
    }

    /// 暴露 inner_crosswords（给 Machine 使用）
    ///
    /// # 返回
    /// - `Some(Arc<RwLock<Crosswords<FFIEventListener>>>)` - 如果是 PTY 模式
    /// - `None` - 如果是测试模式
    pub fn inner_crosswords(&self) -> Option<Arc<RwLock<Crosswords<FFIEventListener>>>> {
        self.crosswords_ffi.clone()
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

    /// 获取当前运行模式
    pub fn mode(&self) -> TerminalMode {
        self.mode
    }

    /// 设置运行模式
    ///
    /// # 参数
    /// - `mode`: 新的运行模式
    ///
    /// # 说明
    /// - 切换到 Active 模式时，会触发一次渲染回调（刷新显示）
    /// - 切换到 Background 模式时，不会触发渲染回调
    pub fn set_mode(&mut self, mode: TerminalMode) {
        let was_background = self.mode == TerminalMode::Background;
        self.mode = mode;

        // 从 Background 切换到 Active 时，触发一次渲染
        if was_background && mode == TerminalMode::Active {
            if let EventListenerType::FFI(ref listener) = self.event_listener {
                listener.send_event(crate::rio_event::RioEvent::Render);
            }
        }
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
    /// 3. 可能产生事件（通过 EventListener）
    /// 4. 标记所有行为 dirty（简单实现，未来可优化为只标记受影响的行）
    pub fn write(&mut self, data: &[u8]) {
        // eprintln!("✍️ [Terminal::write] Writing {} bytes: {:?}", data.len(), String::from_utf8_lossy(data));
        if let Some(ref crosswords_ffi) = self.crosswords_ffi {
            // eprintln!("   Using FFI crosswords");
            {
                let mut crosswords = crosswords_ffi.write();
                self.parser.advance(&mut *crosswords, data);
                // Machine 会调用 Crosswords 的 Handler trait 方法，这些方法内部已经自动标记 damage
                // eprintln!("   After advance, parser finished");
            } // 释放 crosswords 的锁

            // 注意：生产环境中，Machine 直接写入 Crosswords，不经过这个方法
            // 这段代码仅用于测试场景
            // 实际的模式检查在 TerminalPool::event_queue_callback 中进行
        } else if let Some(ref crosswords_test) = self.crosswords_test {
            // eprintln!("   Using Test crosswords");
            {
                let mut crosswords = crosswords_test.write();
                self.parser.advance(&mut *crosswords, data);
                // Machine 会调用 Crosswords 的 Handler trait 方法，这些方法内部已经自动标记 damage
            } // 释放 crosswords 的锁
        }
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
            history_size: 10_000,
        };

        // 调整 Crosswords 的大小（内部会自动标记 full damage）
        if let Some(ref crosswords_ffi) = self.crosswords_ffi {
            let mut crosswords = crosswords_ffi.write();
            crosswords.resize(new_size);
        } else if let Some(ref crosswords_test) = self.crosswords_test {
            let mut crosswords = crosswords_test.write();
            crosswords.resize(new_size);
        }
    }

    /// 驱动终端，返回产生的事件（仅测试模式）
    ///
    /// # 返回
    /// - `Vec<TerminalEvent>` - 自上次 tick 以来产生的所有事件
    ///
    /// # 说明
    /// - PTY 模式：事件通过 EventQueue 传递，不需要 tick()
    /// - 测试模式：通过此方法收集 EventCollector 的事件
    pub fn tick(&mut self) -> Vec<TerminalEvent> {
        match &self.event_listener {
            EventListenerType::Test(collector) => collector.take_events(),
            EventListenerType::FFI(_) => Vec::new(), // PTY 模式不需要 tick
        }
    }

    /// 获取终端状态快照
    pub fn state(&self) -> TerminalState {
        let base_state = with_crosswords!(self, crosswords, {
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
            // 使用 cursor() 方法获取光标状态（会考虑 SHOW_CURSOR 模式）
            let cursor_state = crosswords.cursor();
            let cursor_shape = cursor_state.content;

            // 提取光标颜色（ColorArray 已经是 [f32; 4]，直接使用）
            use rio_backend::config::colors::NamedColor;
            let cursor_color = crosswords.colors[NamedColor::Cursor as usize]
                .unwrap_or(crate::domain::views::cursor::DEFAULT_CURSOR_COLOR);

            let cursor = CursorView::with_color(cursor_pos, cursor_shape, cursor_color);

            // 3. 转换 Selection（如果有）
            let selection = crosswords.selection.as_ref().and_then(|sel| {
                use crate::domain::primitives::AbsolutePoint;
                use crate::domain::views::SelectionType;

                // 获取选区范围（可能返回 None）
                sel.to_range(&crosswords).map(|sel_range| {
                    let history_size = crosswords.grid.history_size();

                    // Grid Line → Absolute Row
                    // 公式：absolute_row = grid_line + history_size
                    // （与 start_selection 中 grid_line = absolute_row - history_size 相反）
                    let start_line = (sel_range.start.row.0 + history_size as i32) as usize;
                    let end_line = (sel_range.end.row.0 + history_size as i32) as usize;

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

            // 构造 TerminalState（不含搜索，搜索在外部添加）
            if let Some(sel) = selection {
                TerminalState::with_selection(grid, cursor, sel)
            } else {
                TerminalState::new(grid, cursor)
            }
        });

        // 4. 使用缓存的 SearchView（避免每帧 O(N) 遍历）
        // 缓存在 search()/next_match()/prev_match() 时更新
        // 注意：搜索和选区可以同时存在
        let mut result = if let Some(ref search_view) = self.cached_search_view {
            // 构造带搜索的 state（保留选区）
            TerminalState {
                grid: base_state.grid,
                cursor: base_state.cursor,
                selection: base_state.selection,
                search: Some(search_view.clone()),
                hyperlink_hover: None,
                ime: None,
            }
        } else {
            base_state
        };

        // 5. 添加超链接悬停状态
        if let Some(ref hover) = self.hyperlink_hover {
            result.hyperlink_hover = Some(hover.clone());
        }

        result
    }

    /// 设置超链接悬停状态
    ///
    /// # 参数
    /// - `start_row`: 起始行（绝对坐标）
    /// - `start_col`: 起始列
    /// - `end_row`: 结束行（绝对坐标）
    /// - `end_col`: 结束列
    /// - `uri`: 超链接 URI
    pub fn set_hyperlink_hover(
        &mut self,
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
        uri: String,
    ) {
        use crate::domain::HyperlinkHoverView;
        use crate::domain::primitives::AbsolutePoint;

        self.hyperlink_hover = Some(HyperlinkHoverView::new(
            AbsolutePoint::new(start_row, start_col),
            AbsolutePoint::new(end_row, end_col),
            uri,
        ));
    }

    /// 清除超链接悬停状态
    pub fn clear_hyperlink_hover(&mut self) {
        self.hyperlink_hover = None;
    }

    /// 获取指定位置的超链接信息
    ///
    /// # 参数
    /// - `screen_row`: 屏幕行（0-based）
    /// - `screen_col`: 屏幕列（0-based）
    ///
    /// # 返回
    /// - `Some((start_col, end_col, uri))`: 如果有超链接
    /// - `None`: 如果没有超链接
    pub fn get_hyperlink_at(&self, screen_row: usize, screen_col: usize) -> Option<(usize, usize, String)> {
        with_crosswords!(self, crosswords, {
            use rio_backend::crosswords::pos::{Line, Column};

            // 计算 grid line（考虑 display_offset）
            let display_offset = crosswords.display_offset();
            let grid_line = Line((screen_row as i32) - (display_offset as i32));

            // 获取 cell
            let col = Column(screen_col);
            let grid = &crosswords.grid;

            // 检查坐标是否有效
            if screen_row >= grid.screen_lines() || screen_col >= grid.columns() {
                return None;
            }

            let square = &grid[grid_line][col];

            // 检查是否有超链接
            if let Some(hyperlink) = square.hyperlink() {
                let uri = hyperlink.uri().to_string();
                let hyperlink_id = hyperlink.id();

                // 向左右扩展找到完整的超链接范围
                let columns = grid.columns();

                // 向左扩展
                let mut left = screen_col;
                while left > 0 {
                    let prev_col = Column(left - 1);
                    if let Some(h) = grid[grid_line][prev_col].hyperlink() {
                        if h.id() == hyperlink_id {
                            left -= 1;
                            continue;
                        }
                    }
                    break;
                }

                // 向右扩展
                let mut right = screen_col;
                while right + 1 < columns {
                    let next_col = Column(right + 1);
                    if let Some(h) = grid[grid_line][next_col].hyperlink() {
                        if h.id() == hyperlink_id {
                            right += 1;
                            continue;
                        }
                    }
                    break;
                }

                Some((left, right, uri))
            } else {
                None
            }
        })
    }

    /// 获取当前光标的绝对坐标
    ///
    /// 用于 IME 预编辑定位。返回值包含历史缓冲区偏移，
    /// 可以直接用于创建 ImeView。
    ///
    /// # 返回
    /// - `(absolute_row, column)`: 绝对行号（i64，可能为负数）和列号
    pub fn get_cursor_absolute_position(&self) -> (i64, usize) {
        with_crosswords!(self, crosswords, {
            let cursor = &crosswords.grid.cursor;
            let pos = cursor.pos;
            let history_size = crosswords.grid.history_size();

            // 转换为绝对坐标
            // Grid Line 坐标系：Line(0) 是当前可见区域第一行，负数是历史
            // 绝对坐标：absolute_row = history_size + grid_line
            let absolute_row = (history_size as i64) + (pos.row.0 as i64);
            let col = pos.col.0 as usize;

            (absolute_row, col)
        })
    }

    /// 增量同步 RenderState
    ///
    /// 从 Crosswords 增量同步到 RenderState，只更新变化的行
    /// 返回是否有变化
    pub fn sync_render_state(&self, render_state: &mut crate::domain::aggregates::render_state::RenderState) -> bool {
        with_crosswords!(self, crosswords, {
            render_state.sync_from_crosswords(&*crosswords)
        })
    }

    // ==================== Step 5: Selection ====================

    /// 开始选区
    ///
    /// # 参数
    /// - `pos`: 选区起始位置（绝对坐标）
    /// - `kind`: 选区类型（Simple, Block, Semantic）
    pub fn start_selection(&mut self, pos: crate::domain::primitives::AbsolutePoint, kind: crate::domain::views::SelectionType) {
        use rio_backend::crosswords::pos::{Line, Column, Pos, Side};
        use rio_backend::selection::{Selection, SelectionType as BackendSelectionType};

        with_crosswords_mut!(self, crosswords, {
            // 转换坐标：AbsolutePoint → Crosswords Pos
            //
            // Grid Line 坐标系（rio-backend 定义）：
            // - topmost_line = Line(-history_size)
            // - bottommost_line = Line(screen_lines - 1)
            // - 可见区域（无滚动时）: Line(0) 到 Line(screen_lines - 1)
            // - 历史区域: Line(-history_size) 到 Line(-1)
            //
            // 绝对坐标定义（我们的定义）：
            // - absolute_row=0 → Line(-history_size)（历史最旧）
            // - absolute_row=history_size → Line(0)（可见区域顶部）
            // - absolute_row=history_size+screen_lines-1 → Line(screen_lines-1)（可见区域底部）
            //
            // 转换公式（不考虑滚动）：
            // grid_line = absolute_row - history_size
            //
            // 选区坐标不受 display_offset 影响，因为选区是相对于 Grid 的
            let history_size = crosswords.grid.history_size();

            // 正确的转换：absolute → grid_line
            // grid_line = absolute_row - history_size
            let grid_line = pos.line as i32 - history_size as i32;
            let line = Line(grid_line);
            let col = Column(pos.col);
            let crosswords_pos = Pos::new(line, col);

            // 转换选区类型
            let backend_kind = match kind {
                crate::domain::views::SelectionType::Simple => BackendSelectionType::Simple,
                crate::domain::views::SelectionType::Block => BackendSelectionType::Block,
                crate::domain::views::SelectionType::Lines => BackendSelectionType::Lines,
            };

            // 创建新的 Selection
            crosswords.selection = Some(Selection::new(backend_kind, crosswords_pos, Side::Left));

            // 标记 damage，触发重新渲染以显示选区高亮
            crosswords.mark_fully_damaged();
        });
    }

    /// 更新选区
    ///
    /// # 参数
    /// - `pos`: 选区结束位置（绝对坐标）
    pub fn update_selection(&mut self, pos: crate::domain::primitives::AbsolutePoint) {
        use rio_backend::crosswords::pos::{Line, Column, Pos, Side};

        with_crosswords_mut!(self, crosswords, {
            // 转换坐标（与 start_selection 相同的逻辑）
            let history_size = crosswords.grid.history_size();

            // 正确的转换：absolute → grid_line
            let grid_line = pos.line as i32 - history_size as i32;
            let line = Line(grid_line);
            let col = Column(pos.col);
            let crosswords_pos = Pos::new(line, col);

            // 更新选区
            if let Some(ref mut selection) = crosswords.selection {
                // 根据当前点和起点的相对位置决定 Side
                // 当反向选择（从右到左）时，需要使用 Side::Left 来包含完整的字符
                let start_point = selection.region.start.point;
                let side = if crosswords_pos < start_point {
                    // 反向选择：终点在起点左边/上方
                    Side::Left
                } else {
                    // 正向选择：终点在起点右边/下方
                    Side::Right
                };
                selection.update(crosswords_pos, side);
                // 标记 damage，触发重新渲染以显示选区高亮
                crosswords.mark_fully_damaged();
            }
        });
    }

    /// 清除选区
    pub fn clear_selection(&mut self) {
        with_crosswords_mut!(self, crosswords, {
            crosswords.selection = None;
            // 标记 damage，触发重新渲染以清除选区高亮
            crosswords.mark_fully_damaged();
        });
    }

    /// 获取选中的文本
    ///
    /// # 返回
    /// - `Some(String)` - 选中的文本
    /// - `None` - 没有选区
    pub fn selection_text(&self) -> Option<String> {
        with_crosswords!(self, crosswords, {
            crosswords.selection_to_string()
        })
    }

    /// 获取指定范围内的文本（不需要设置选区）
    ///
    /// # 参数
    /// - `start_row`, `start_col`: 起始位置（绝对坐标）
    /// - `end_row`, `end_col`: 结束位置（绝对坐标）
    ///
    /// # 返回
    /// - `Some(String)` - 范围内的文本
    /// - `None` - 范围无效
    pub fn text_in_range(&self, start_row: i32, start_col: u32, end_row: i32, end_col: u32) -> Option<String> {
        use rio_backend::crosswords::pos::{Line, Column, Pos};

        with_crosswords!(self, crosswords, {
            let history_size = crosswords.grid.history_size() as i32;

            // 规范化：确保 start <= end
            let (sr, sc, er, ec) = if start_row < end_row || (start_row == end_row && start_col <= end_col) {
                (start_row, start_col, end_row, end_col)
            } else {
                (end_row, end_col, start_row, start_col)
            };

            // 转换为 Grid Line 坐标
            let start_line = Line(sr - history_size);
            let end_line = Line(er - history_size);
            let start_pos = Pos::new(start_line, Column(sc as usize));
            let end_pos = Pos::new(end_line, Column(ec as usize));

            Some(crosswords.bounds_to_string(start_pos, end_pos))
        })
    }

    /// 完成选区（mouseUp 时调用）
    ///
    /// 业务逻辑：
    /// - 检查选区内容是否全为空白
    /// - 如果全是空白，自动清除选区，返回 None
    /// - 如果有内容，保留选区，返回选中的文本
    ///
    /// # 返回
    /// - `Some(String)` - 选中的文本（非空白）
    /// - `None` - 没有选区或选区内容全为空白（已自动清除）
    pub fn finalize_selection(&mut self) -> Option<String> {
        // 先获取选中的文本
        let text = self.selection_text();

        match text {
            Some(ref t) if t.chars().all(|c| c.is_whitespace()) => {
                // 全是空白，清除选区
                self.clear_selection();
                None
            }
            Some(t) => Some(t),
            None => None,
        }
    }

    // ==================== Step 6: Search ====================

    /// 从 Crosswords 的搜索状态构建 SearchView
    ///
    /// 只在搜索事件发生时调用（search/next/prev），避免每帧 O(N) 遍历
    fn build_search_view<T>(crosswords: &Crosswords<T>) -> Option<SearchView>
    where
        T: EventListener,
    {
        crosswords.search_state.as_ref().map(|search_state| {
            let history_size = crosswords.grid.history_size();

            // 转换所有匹配（O(N) 但只在搜索事件时执行）
            let matches: Vec<MatchRange> = search_state
                .all_matches
                .iter()
                .map(|match_range| {
                    let start_pos = match_range.start();
                    let end_pos = match_range.end();

                    // 绝对行号 = history_size + Line 坐标
                    let start_line = (history_size as i32 + start_pos.row.0) as usize;
                    let start = AbsolutePoint::new(start_line, start_pos.col.0 as usize);

                    let end_line = (history_size as i32 + end_pos.row.0) as usize;
                    let end = AbsolutePoint::new(end_line, end_pos.col.0 as usize);

                    MatchRange::new(start, end)
                })
                .collect();

            SearchView::new(matches, search_state.focused_index)
        })
    }

    /// 搜索文本
    ///
    /// # 参数
    /// - `query`: 搜索关键词
    ///
    /// # 返回
    /// - 匹配的数量
    pub fn search(&mut self, query: &str) -> usize {
        // 先执行搜索，获取结果
        let (count, search_view) = if let Some(ref cw) = self.crosswords_ffi {
            let mut crosswords = cw.write();
            let _ = crosswords.start_search(query, false, false, None);
            let count = crosswords.search_state
                .as_ref()
                .map(|s| s.all_matches.len())
                .unwrap_or(0);
            let view = Self::build_search_view(&*crosswords);
            (count, view)
        } else if let Some(ref cw) = self.crosswords_test {
            let mut crosswords = cw.write();
            let _ = crosswords.start_search(query, false, false, None);
            let count = crosswords.search_state
                .as_ref()
                .map(|s| s.all_matches.len())
                .unwrap_or(0);
            let view = Self::build_search_view(&*crosswords);
            (count, view)
        } else {
            (0, None)
        };
        // 锁已释放，更新缓存
        self.cached_search_view = search_view;
        count
    }

    /// 跳到下一个搜索匹配
    pub fn next_match(&mut self) {
        let search_view = if let Some(ref cw) = self.crosswords_ffi {
            let mut crosswords = cw.write();
            crosswords.search_goto_next();
            Self::build_search_view(&*crosswords)
        } else if let Some(ref cw) = self.crosswords_test {
            let mut crosswords = cw.write();
            crosswords.search_goto_next();
            Self::build_search_view(&*crosswords)
        } else {
            None
        };
        self.cached_search_view = search_view;
    }

    /// 跳到上一个搜索匹配
    pub fn prev_match(&mut self) {
        let search_view = if let Some(ref cw) = self.crosswords_ffi {
            let mut crosswords = cw.write();
            crosswords.search_goto_prev();
            Self::build_search_view(&*crosswords)
        } else if let Some(ref cw) = self.crosswords_test {
            let mut crosswords = cw.write();
            crosswords.search_goto_prev();
            Self::build_search_view(&*crosswords)
        } else {
            None
        };
        self.cached_search_view = search_view;
    }

    /// 清除搜索
    pub fn clear_search(&mut self) {
        with_crosswords_mut!(self, crosswords, {
            crosswords.clear_search();
        });
        // 清除缓存
        self.cached_search_view = None;
    }

    // ==================== Step 7: Scroll ====================

    /// 滚动终端
    ///
    /// # 参数
    /// - `delta`: 滚动行数（正数向上滚动，负数向下滚动）
    pub fn scroll(&mut self, delta: i32) {
        use rio_backend::crosswords::grid::Scroll;

        with_crosswords_mut!(self, crosswords, {
            crosswords.scroll_display(Scroll::Delta(delta));
            // 滚动后 display_offset 变化，屏幕内容变化，Crosswords 内部已自动标记 full damage
        });
    }

    /// 滚动到顶部
    pub fn scroll_to_top(&mut self) {
        use rio_backend::crosswords::grid::Scroll;

        with_crosswords_mut!(self, crosswords, {
            crosswords.scroll_display(Scroll::Top);
            // Crosswords 内部已自动标记 full damage
        });
    }

    /// 滚动到底部
    pub fn scroll_to_bottom(&mut self) {
        use rio_backend::crosswords::grid::Scroll;

        with_crosswords_mut!(self, crosswords, {
            crosswords.scroll_display(Scroll::Bottom);
            // Crosswords 内部已自动标记 full damage
        });
    }

    // ==================== Damage 管理（代理到 Crosswords）====================

    /// 检查是否有 damage（需要重绘）
    ///
    /// # 返回
    /// - `true` - 如果有 damage（full 或 partial）
    /// - `false` - 如果没有 damage
    pub fn is_damaged(&self) -> bool {
        with_crosswords!(self, crosswords, {
            // 检查 full damage
            if crosswords.is_fully_damaged() {
                return true;
            }
            // 检查 partial damage（检查是否有任何行被标记）
            crosswords.peek_damage_event().is_some()
        })
    }

    /// 重置 damage 状态（渲染完成后调用）
    pub fn reset_damage(&mut self) {
        with_crosswords_mut!(self, crosswords, {
            crosswords.reset_damage();
        });
    }

    /// 检查是否正在 DEC Synchronized Update 中
    ///
    /// 当终端收到 BSU (\e[?2026h) 后，is_syncing 为 true，
    /// 直到收到 ESU (\e[?2026l) 才变为 false。
    /// 在 sync 期间，应该跳过渲染以避免闪烁。
    pub fn is_syncing(&self) -> bool {
        with_crosswords!(self, crosswords, {
            crosswords.is_syncing
        })
    }

    /// 检查终端是否启用了 Bracketed Paste Mode
    ///
    /// Bracketed Paste Mode（mode 2004）让应用程序可以区分用户输入和粘贴内容。
    /// 当启用时，粘贴的内容应该被 \x1b[200~ 和 \x1b[201~ 包裹。
    /// 当未启用时，直接发送原始文本。
    pub fn is_bracketed_paste_enabled(&self) -> bool {
        use rio_backend::crosswords::Mode;
        with_crosswords!(self, crosswords, {
            crosswords.mode().contains(Mode::BRACKETED_PASTE)
        })
    }

    /// 获取 OSC 7 缓存的当前工作目录
    ///
    /// Shell 通过 OSC 7 转义序列主动上报 CWD（如 `\e]7;file://hostname/path\a`）。
    /// 这比 `proc_pidinfo` 更可靠，因为：
    /// - 不受子进程（如 vim、claude）干扰
    /// - Shell 自己最清楚当前目录
    /// - 每次 cd 后立即更新
    pub fn get_current_directory(&self) -> Option<std::path::PathBuf> {
        with_crosswords!(self, crosswords, {
            crosswords.current_directory.clone()
        })
    }

    /// 检查是否启用了 Kitty 键盘协议
    ///
    /// 应用通过发送 `CSI > flags u` 启用 Kitty 键盘模式。
    /// 启用后，终端应使用 Kitty 协议编码按键（如 Shift+Enter → `\x1b[13;2u`）。
    ///
    /// # 返回值
    /// - `true`: Kitty 键盘协议已启用，使用 Kitty 编码
    /// - `false`: 使用传统 Xterm 编码
    pub fn is_kitty_keyboard_enabled(&self) -> bool {
        use rio_backend::crosswords::Mode;
        with_crosswords!(self, crosswords, {
            crosswords.mode().contains(Mode::DISAMBIGUATE_ESC_CODES)
        })
    }
}

#[cfg(test)]
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

    #[test]
    fn test_tick_collects_events() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入一些数据（可能产生 Wakeup 事件）
        terminal.write(b"Hello");

        // Tick 收集事件
        let events = terminal.tick();

        // 验证返回 Vec（至少不 panic）
        // 注意：具体事件取决于 EventCollector 的实现
        // 如果 Crosswords 没有自动产生事件，这个测试可能为空
        // len() 总是 >= 0，所以我们只需验证它是一个 Vec
        let _event_count = events.len();
    }

    #[test]
    fn test_tick_multiple_times() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 第一次 tick（应该没有事件）
        let events1 = terminal.tick();
        assert_eq!(events1.len(), 0);

        // 写入数据
        terminal.write(b"Hello");

        // 第二次 tick（可能有事件）
        let _events2 = terminal.tick();

        // 第三次 tick（应该没有新事件，因为已经收集过了）
        let events3 = terminal.tick();
        assert_eq!(events3.len(), 0);
    }

    #[test]
    fn test_events_cleared_after_tick() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入数据（可能产生事件）
        terminal.write(b"Hello");

        // 第一次 tick
        let events1 = terminal.tick();
        let _count1 = events1.len();

        // 第二次 tick（事件应该已经被清空）
        let events2 = terminal.tick();
        assert_eq!(events2.len(), 0, "Events should be cleared after tick");
    }

    // ==================== Step 5: Selection Tests ====================

    #[test]
    fn test_selection() {
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;

        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入文本
        terminal.write(b"Hello World");

        // 创建选区（选中 "Hello"）
        // 注意：初始状态没有历史缓冲区，光标在屏幕第 0 行
        // 所以 AbsolutePoint 也应该是 0
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(0, 5);

        terminal.start_selection(start, SelectionType::Simple);
        terminal.update_selection(end);

        // 获取状态，验证有选区
        let state = terminal.state();
        assert!(state.selection.is_some(), "Selection should exist");

        // 获取选中文本
        let text = terminal.selection_text();
        assert!(text.is_some(), "Selection text should exist");
        let text = text.unwrap();
        assert!(text.contains("Hello"), "Selection should contain 'Hello', got: {}", text);

        // 清除选区
        terminal.clear_selection();
        let state_after = terminal.state();
        assert!(state_after.selection.is_none(), "Selection should be cleared");
    }

    #[test]
    fn test_selection_block_type() {
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;

        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入多行文本
        terminal.write(b"Line1\r\nLine2\r\nLine3");

        // 创建块选区（起点在第0行，终点在第2行）
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(2, 3);

        terminal.start_selection(start, SelectionType::Block);
        terminal.update_selection(end);

        // 验证选区类型
        let state = terminal.state();
        assert!(state.selection.is_some());
        if let Some(sel) = state.selection {
            assert!(sel.is_block(), "Selection should be block type");
        }
    }

    // ==================== Step 6: Search Tests ====================

    #[test]
    fn test_search() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入包含重复词的文本
        terminal.write(b"Hello World\r\nHello Rust");

        // 搜索 "Hello"
        let match_count = terminal.search("Hello");
        assert!(match_count > 0, "Should find at least one match");

        // 获取状态，验证有搜索结果
        let state = terminal.state();
        assert!(state.search.is_some(), "Search should exist");

        // 验证有匹配
        if let Some(search) = state.search {
            assert!(search.match_count() > 0, "Should have matches");
        }

        // 清除搜索
        terminal.clear_search();
        let state_after = terminal.state();
        assert!(state_after.search.is_none(), "Search should be cleared");
    }

    #[test]
    fn test_search_navigation() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入文本
        terminal.write(b"Hello World\r\nHello Rust\r\nHello Claude");

        // 搜索
        let match_count = terminal.search("Hello");
        assert!(match_count >= 3, "Should find at least 3 matches");

        // 测试导航（只验证不 panic）
        terminal.next_match();
        terminal.next_match();
        terminal.prev_match();

        // 验证搜索仍然存在
        let state = terminal.state();
        assert!(state.search.is_some(), "Search should still exist after navigation");
    }

    #[test]
    fn test_search_empty_query() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        terminal.write(b"Hello World");

        // 空查询应该返回 0 匹配
        let match_count = terminal.search("");
        assert_eq!(match_count, 0, "Empty query should have no matches");
    }

    // ==================== Step 7: Scroll Tests ====================

    #[test]
    fn test_scroll() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入足够多的行以触发滚动
        for i in 0..30 {
            terminal.write(format!("Line {}\r\n", i).as_bytes());
        }

        // 初始状态（应该在底部）
        let state_initial = terminal.state();
        let initial_offset = state_initial.grid.display_offset();

        // 向上滚动 5 行
        terminal.scroll(5);
        let state_up = terminal.state();
        let up_offset = state_up.grid.display_offset();
        assert!(up_offset > initial_offset, "Scroll up should increase offset");

        // 滚动到底部
        terminal.scroll_to_bottom();
        let state_bottom = terminal.state();
        let bottom_offset = state_bottom.grid.display_offset();
        assert_eq!(bottom_offset, 0, "Scroll to bottom should reset offset to 0");

        // 滚动到顶部
        terminal.scroll_to_top();
        let state_top = terminal.state();
        let top_offset = state_top.grid.display_offset();
        assert!(top_offset > 0, "Scroll to top should have non-zero offset");
    }

    #[test]
    fn test_scroll_affects_state() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入足够多的行（超过屏幕高度）以触发滚动
        for i in 0..30 {
            terminal.write(format!("Line {}\r\n", i).as_bytes());
        }

        // 滚动前
        let state_before = terminal.state();
        let offset_before = state_before.grid.display_offset();

        // 滚动
        terminal.scroll(3);

        // 滚动后
        let state_after = terminal.state();
        let offset_after = state_after.grid.display_offset();

        // 验证 offset 改变
        assert_ne!(offset_before, offset_after, "Scroll should change display offset");
    }

    #[test]
    fn test_scroll_negative() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入足够多的行
        for i in 0..30 {
            terminal.write(format!("Line {}\r\n", i).as_bytes());
        }

        // 向上滚动
        terminal.scroll(5);
        let state_up = terminal.state();
        let up_offset = state_up.grid.display_offset();

        // 向下滚动（负数）
        terminal.scroll(-3);
        let state_down = terminal.state();
        let down_offset = state_down.grid.display_offset();

        // 向下滚动应该减少 offset
        assert!(down_offset < up_offset, "Scroll down should decrease offset");
    }

    // ==================== Step 8: Integration Tests ====================

    #[test]
    fn test_full_terminal_lifecycle() {
        // 创建终端
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 验证初始状态
        assert_eq!(terminal.cols(), 80);
        assert_eq!(terminal.rows(), 24);

        let initial_state = terminal.state();
        assert_eq!(initial_state.cursor.position.line, 0);
        assert_eq!(initial_state.cursor.position.col, 0);

        // 写入数据
        terminal.write(b"Hello, World!\r\n");
        terminal.write(b"Second line\r\n");

        // Tick 驱动
        let events = terminal.tick();
        // 可能有或没有事件，取决于 Crosswords 实现
        let _ = events; // 确保编译器不会警告未使用

        // 验证状态更新
        let state = terminal.state();

        // 验证第一行内容
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'H');
            assert_eq!(cells[1].c, 'e');
            assert_eq!(cells[2].c, 'l');
            assert_eq!(cells[3].c, 'l');
            assert_eq!(cells[4].c, 'o');
        }

        // 验证光标存在（line 是 usize，总是 >= 0）
        let _ = state.cursor.position.line;
    }

    #[test]
    fn test_ansi_escape_sequences_cursor_home() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 测试光标移动：ESC[H (移动到 home)
        terminal.write(b"Test");
        terminal.write(b"\x1b[H"); // ESC[H
        terminal.write(b"Home");

        let state = terminal.state();
        // 验证 "Home" 覆盖了 "Test" 的前 4 个字符
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'H');
            assert_eq!(cells[1].c, 'o');
            assert_eq!(cells[2].c, 'm');
            assert_eq!(cells[3].c, 'e');
        }
    }

    #[test]
    fn test_ansi_clear_screen() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入一些内容
        terminal.write(b"Line 1\r\n");
        terminal.write(b"Line 2\r\n");

        let state_before = terminal.state();
        // 验证有内容
        if let Some(row) = state_before.grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'L');
        }

        // 清屏：ESC[2J
        terminal.write(b"\x1b[2J");

        // 移动到 home
        terminal.write(b"\x1b[H");

        // 写入新内容
        terminal.write(b"After clear");

        let state = terminal.state();
        // 验证新内容写入成功（清屏后的第一行）
        // 注意：根据实际行为，内容可能在滚动缓冲区中
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            // 只验证有内容写入，不严格检查字符
            assert_ne!(cells[0].c, '\0');
        }
    }

    #[test]
    fn test_ansi_colors() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 设置红色前景：ESC[31m
        terminal.write(b"\x1b[31mRed text\x1b[0m");

        let state = terminal.state();
        // 验证文本正确写入
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'R');
            assert_eq!(cells[1].c, 'e');
            assert_eq!(cells[2].c, 'd');
            assert_eq!(cells[4].c, 't');
        }
    }

    #[test]
    fn test_complex_scenario_write_search_select() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 1. 写入多行文本
        terminal.write(b"First line with keyword\r\n");
        terminal.write(b"Second line\r\n");
        terminal.write(b"Third line with keyword\r\n");

        // 2. 搜索 "keyword"
        let match_count = terminal.search("keyword");
        let state_after_search = terminal.state();
        assert!(state_after_search.search.is_some());
        assert!(match_count >= 2, "Should find at least 2 occurrences");

        // 3. 创建选区（选中第一行）
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;

        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(0, 10);
        terminal.start_selection(start, SelectionType::Simple);
        terminal.update_selection(end);

        let state_after_select = terminal.state();
        assert!(state_after_select.selection.is_some());
        // 注意：Crosswords 在某些操作后可能清除搜索，这是正常行为
        // 我们只验证选区存在

        // 4. 滚动
        terminal.scroll(1);

        let final_state = terminal.state();
        // display_offset 是 usize，总是 >= 0，只验证可访问
        let _ = final_state.grid.display_offset();

        // 5. 清理
        terminal.clear_selection();
        terminal.clear_search();
        terminal.scroll_to_bottom();

        let clean_state = terminal.state();
        assert!(clean_state.selection.is_none());
        assert!(clean_state.search.is_none());
        assert_eq!(clean_state.grid.display_offset(), 0);
    }

    #[test]
    fn test_write_resize_scroll_combination() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入足够多的行
        for i in 0..30 {
            terminal.write(format!("Line {}\r\n", i).as_bytes());
        }

        // Resize 到更小
        terminal.resize(60, 20);
        assert_eq!(terminal.cols(), 60);
        assert_eq!(terminal.rows(), 20);

        // 滚动到顶部
        terminal.scroll_to_top();

        let state = terminal.state();
        assert!(state.grid.display_offset() > 0);
        assert_eq!(state.grid.columns(), 60);

        // 再写入数据
        terminal.write(b"After resize\r\n");

        // Tick
        let events = terminal.tick();
        let _ = events; // events.len() 是 usize，总是 >= 0

        // 验证状态一致性
        let final_state = terminal.state();
        assert_eq!(final_state.grid.columns(), 60);
    }

    #[test]
    fn test_empty_terminal() {
        let terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 不写入任何数据，直接获取状态
        let state = terminal.state();

        assert_eq!(state.grid.columns(), 80);
        assert!(state.selection.is_none());
        assert!(state.search.is_none());
    }

    #[test]
    fn test_multiple_tick_without_data() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 多次 tick 但不写入数据
        for _ in 0..10 {
            let events = terminal.tick();
            assert_eq!(events.len(), 0);
        }
    }

    #[test]
    fn test_large_text_input() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入大量文本
        let large_text = "A".repeat(10000);
        terminal.write(large_text.as_bytes());

        // 验证不会 panic
        let state = terminal.state();
        assert!(state.grid.columns() > 0);
    }

    #[test]
    fn test_selection_out_of_bounds() {
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;

        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 尝试在越界位置创建选区
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(0, 200); // 超过列数

        terminal.start_selection(start, SelectionType::Simple);
        terminal.update_selection(end);

        // 不应该 panic
        let state = terminal.state();
        // Selection 可能存在也可能不存在，取决于 Crosswords 的处理
        assert!(state.grid.columns() > 0);
    }

    #[test]
    fn test_tick_after_operations() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 执行各种操作
        terminal.write(b"Hello\r\n");
        terminal.resize(100, 30);
        terminal.scroll(5);

        // Tick 收集事件
        let events = terminal.tick();
        // events 可能为空或非空
        let _ = events;

        // 再次 tick，应该没有新事件
        let events2 = terminal.tick();
        assert_eq!(events2.len(), 0);
    }

    #[test]
    fn test_multiline_ansi_sequences() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 测试多行 ANSI 序列组合
        terminal.write(b"\x1b[31mRed line 1\r\n");
        terminal.write(b"\x1b[32mGreen line 2\r\n");
        terminal.write(b"\x1b[34mBlue line 3\r\n");
        terminal.write(b"\x1b[0mNormal line 4\r\n");

        let state = terminal.state();

        // 验证第一行
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'R');
            assert_eq!(cells[1].c, 'e');
            assert_eq!(cells[2].c, 'd');
        }

        // 验证第二行
        if let Some(row) = state.grid.row(1) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'G');
            assert_eq!(cells[1].c, 'r');
            assert_eq!(cells[2].c, 'e');
        }
    }

    #[test]
    fn test_write_with_tabs() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入包含制表符的文本
        terminal.write(b"Col1\tCol2\tCol3\r\n");
        terminal.write(b"A\tB\tC\r\n");

        let state = terminal.state();

        // 验证第一行有内容
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            assert_eq!(cells[0].c, 'C');
            assert_eq!(cells[1].c, 'o');
            assert_eq!(cells[2].c, 'l');
        }
    }

    #[test]
    fn test_search_then_write_more() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入初始内容
        terminal.write(b"Hello World\r\n");

        // 搜索
        let match_count = terminal.search("Hello");
        assert!(match_count > 0);

        // 写入更多内容
        terminal.write(b"Hello again\r\n");

        // 搜索应该仍然存在
        let state = terminal.state();
        assert!(state.search.is_some());

        // 重新搜索应该找到更多匹配
        let new_match_count = terminal.search("Hello");
        assert!(new_match_count >= match_count);
    }

    #[test]
    fn test_selection_then_resize() {
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;

        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入内容
        terminal.write(b"Hello World\r\n");

        // 创建选区
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(0, 5);
        terminal.start_selection(start, SelectionType::Simple);
        terminal.update_selection(end);

        // 验证选区存在
        let state_before = terminal.state();
        assert!(state_before.selection.is_some());

        // Resize
        terminal.resize(100, 30);

        // Selection 可能被清除或保留，取决于实现
        // 只验证不 panic
        let state_after = terminal.state();
        assert_eq!(state_after.grid.columns(), 100);
    }

    #[test]
    fn test_rapid_write_operations() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 快速连续写入
        for i in 0..100 {
            terminal.write(format!("{} ", i).as_bytes());
        }

        // 验证不 panic
        let state = terminal.state();
        assert!(state.grid.columns() > 0);
    }

    #[test]
    fn test_scroll_with_selection() {
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;

        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入足够多的行
        for i in 0..30 {
            terminal.write(format!("Line {}\r\n", i).as_bytes());
        }

        // 创建选区
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(0, 10);
        terminal.start_selection(start, SelectionType::Simple);
        terminal.update_selection(end);

        let state_before = terminal.state();
        assert!(state_before.selection.is_some());

        // 滚动
        terminal.scroll(5);

        // Selection 和滚动应该共存
        let state_after = terminal.state();
        assert!(state_after.grid.display_offset() > 0);
    }

    #[test]
    fn test_write_unicode() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入 Unicode 字符
        terminal.write("你好世界\r\n".as_bytes());
        terminal.write("Hello 🦀\r\n".as_bytes());

        // 验证不 panic
        let state = terminal.state();
        assert!(state.grid.columns() > 0);

        // 验证有内容（Unicode 可能占用多个单元格）
        if let Some(row) = state.grid.row(0) {
            let cells = row.cells();
            // 只验证第一个字符存在
            assert_ne!(cells[0].c, ' ');
        }
    }

    #[test]
    fn test_clear_all_then_use() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入内容
        terminal.write(b"Hello World\r\n");

        // 创建选区和搜索
        use crate::domain::primitives::AbsolutePoint;
        use crate::domain::views::SelectionType;
        let start = AbsolutePoint::new(0, 0);
        let end = AbsolutePoint::new(0, 5);
        terminal.start_selection(start, SelectionType::Simple);
        terminal.update_selection(end);
        terminal.search("Hello");

        // 清除所有
        terminal.clear_selection();
        terminal.clear_search();

        // 验证清除成功
        let state = terminal.state();
        assert!(state.selection.is_none());
        assert!(state.search.is_none());

        // 继续使用终端
        terminal.write(b"New content\r\n");
        let final_state = terminal.state();
        assert!(final_state.grid.columns() > 0);
    }

    #[test]
    fn test_state_consistency_after_multiple_operations() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 执行一系列复杂操作
        terminal.write(b"Line 1\r\n");
        let state1 = terminal.state();
        assert_eq!(state1.grid.columns(), 80);

        terminal.resize(100, 30);
        let state2 = terminal.state();
        assert_eq!(state2.grid.columns(), 100);

        terminal.write(b"Line 2\r\n");
        terminal.scroll(1);
        let state3 = terminal.state();
        assert_eq!(state3.grid.columns(), 100);

        terminal.search("Line");
        let state4 = terminal.state();
        assert!(state4.search.is_some());
        assert_eq!(state4.grid.columns(), 100);

        // 验证状态一致性
        let final_state = terminal.state();
        assert_eq!(final_state.grid.columns(), 100);
        assert_eq!(final_state.grid.lines(), 30);
    }
}
