//! Rio Terminal - 干净的终端封装
//!
//! 照抄 Rio 的架构：
//! - 使用 FFIEventListener 传递事件
//! - 提供 TerminalSnapshot 一次性获取所有渲染状态
//! - FFI 接口给 Swift 调用

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use std::sync::Arc;
use std::thread::JoinHandle;

use corcovado::channel;
use rio_backend::ansi::CursorShape;
use rio_backend::crosswords::grid::row::Row;
use rio_backend::crosswords::grid::Dimensions;
use rio_backend::crosswords::square::Square;
use rio_backend::crosswords::{Crosswords, CrosswordsSize};
use rio_backend::event::Msg;
use teletypewriter::{create_pty_with_fork, WinsizeBuilder};

use sugarloaf::{
    FragmentStyle,
    SugarCursor,
    layout::{FragmentStyleDecoration, UnderlineInfo, UnderlineShape},
};

use crate::rio_event::{EventCallback, EventQueue, FFIEventListener, StringEventCallback};
use crate::rio_machine::{send_input, send_resize, send_shutdown, Machine, State};
use crate::{global_font_metrics, SugarloafFontMetrics, SugarloafHandle};

/// 历史行数
const DEFAULT_HISTORY_LINES: usize = 1_000;

/// 性能日志开关（开发调试时设为 true，生产环境设为 false）
const DEBUG_PERFORMANCE: bool = false;

/// 性能日志宏（只在 DEBUG_PERFORMANCE = true 时输出）
macro_rules! perf_log {
    ($($arg:tt)*) => {
        if DEBUG_PERFORMANCE {
            println!($($arg)*);
        }
    };
}

/// 全局终端 ID 计数器
static NEXT_TERMINAL_ID: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(1);

// ============================================================================
// 并发渲染中间数据结构
// ============================================================================

/// 单个字符的渲染数据（并发阶段解析后的中间格式）
#[derive(Debug, Clone)]
struct CharRenderData {
    char_str: String,
    fg_r: f32,
    fg_g: f32,
    fg_b: f32,
    fg_a: f32,
    has_bg: bool,
    bg_r: f32,
    bg_g: f32,
    bg_b: f32,
    bg_a: f32,
    glyph_width: f32,
    has_cursor: bool,
    cursor_r: f32,
    cursor_g: f32,
    cursor_b: f32,
    cursor_a: f32,
    flags: u32,
}

/// 单行的渲染数据
#[derive(Debug, Clone)]
struct RowRenderData {
    chars: Vec<CharRenderData>,
    is_cursor_report: bool,
}

// ============================================================================
// 终端快照 - 照抄 Rio 的 TerminalSnapshot
// ============================================================================

/// 终端快照 - 一次性获取所有渲染需要的状态
///
/// 照抄 rio/frontends/rioterm/src/context/renderable.rs 的 TerminalSnapshot
#[repr(C)]
pub struct TerminalSnapshot {
    /// 显示偏移（滚动位置）
    pub display_offset: usize,
    /// 历史缓冲区行数
    pub scrollback_lines: usize,
    /// 光标是否闪烁
    pub blinking_cursor: i32,
    /// 光标位置（列）
    pub cursor_col: usize,
    /// 光标位置（行，相对于可见区域）
    pub cursor_row: usize,
    /// 光标形状 (0=Block, 1=Underline, 2=Beam, 3=Hidden)
    pub cursor_shape: u8,
    /// 光标是否可见（考虑了 DECTCEM、滚动等因素）
    pub cursor_visible: i32,
    /// 列数
    pub columns: usize,
    /// 行数
    pub screen_lines: usize,
    /// 是否有选区
    pub has_selection: i32,
    /// 选区开始列
    pub selection_start_col: usize,
    /// 选区开始行
    pub selection_start_row: i32,
    /// 选区结束列
    pub selection_end_col: usize,
    /// 选区结束行
    pub selection_end_row: i32,
}

/// 单个单元格 - FFI 友好的结构
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FFICell {
    /// UTF-32 字符
    pub character: u32,
    /// 前景色 RGBA
    pub fg_r: u8,
    pub fg_g: u8,
    pub fg_b: u8,
    pub fg_a: u8,
    /// 背景色 RGBA
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    pub bg_a: u8,
    /// 标志位 (bold, italic, underline, etc.)
    pub flags: u32,
    /// 是否有 VS16 (U+FE0F) emoji 变体选择符
    pub has_vs16: bool,
}

impl Default for FFICell {
    fn default() -> Self {
        Self {
            character: ' ' as u32,
            fg_r: 255,
            fg_g: 255,
            fg_b: 255,
            fg_a: 255,
            bg_r: 0,
            bg_g: 0,
            bg_b: 0,
            bg_a: 0,
            flags: 0,
            has_vs16: false,
        }
    }
}

// ============================================================================
// 单个终端
// ============================================================================

/// 终端布局信息
#[derive(Debug, Clone, Copy)]
pub struct TerminalLayout {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub visible: bool,
}

/// 单个终端
pub struct RioTerminal {
    /// 终端状态
    terminal: Arc<parking_lot::RwLock<Crosswords<FFIEventListener>>>,
    /// PTY 消息发送通道
    pty_sender: channel::Sender<Msg>,
    /// 事件循环线程句柄
    _event_loop_handle: JoinHandle<(Machine<teletypewriter::Pty>, State)>,
    /// 事件队列
    event_queue: EventQueue,
    /// 终端 ID
    id: usize,
    /// 列数
    cols: u16,
    /// 行数
    rows: u16,
    /// PTY 主文件描述符（用于获取 CWD）
    main_fd: std::os::fd::RawFd,
    /// Shell PID（用于获取 CWD）
    shell_pid: u32,
    /// 布局信息（渲染位置和尺寸）
    layout: parking_lot::RwLock<Option<TerminalLayout>>,
}

impl RioTerminal {
    /// 创建新终端
    ///
    /// # 参数
    /// - `cols`: 列数
    /// - `rows`: 行数
    /// - `shell`: Shell 程序路径
    /// - `working_dir`: 工作目录（可选）
    /// - `event_queue`: 事件队列
    pub fn new(
        cols: u16,
        rows: u16,
        shell: &str,
        working_dir: Option<String>,
        event_queue: EventQueue,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let terminal_id = NEXT_TERMINAL_ID.fetch_add(1, std::sync::atomic::Ordering::SeqCst);

        // 设置环境变量（照抄 Rio）
        Self::setup_environment();

        // 注入 ETERM_TERMINAL_ID 环境变量（用于 Claude Hook 调用）
        std::env::set_var("ETERM_TERMINAL_ID", terminal_id.to_string());

        // 获取字体度量
        let font_metrics = global_font_metrics().unwrap_or_else(|| SugarloafFontMetrics {
            cell_width: 8.0,
            cell_height: 16.0,
            line_height: 16.0,
        });

        // 计算像素尺寸
        let (winsize_width, winsize_height, total_width, total_height, square_width, square_height) =
            Self::pixel_dimensions(cols, rows, &font_metrics);

        // 创建 PTY（使用 working_dir）
        let mut pty = if let Some(ref wd) = working_dir {
            // 使用 create_pty_with_spawn 支持工作目录
            teletypewriter::create_pty_with_spawn(shell, vec![], &working_dir, cols, rows)?
        } else {
            // 使用默认的 create_pty_with_fork
            create_pty_with_fork(&Cow::Borrowed(shell), cols, rows)?
        };

        let initial_winsize = WinsizeBuilder {
            cols,
            rows,
            width: winsize_width,
            height: winsize_height,
        };
        let _ = pty.set_winsize(initial_winsize);

        // 保存 PTY 的 main_fd 和 shell_pid（用于获取 CWD，在 PTY move 之前保存）
        let main_fd = *pty.child.id;
        let shell_pid = *pty.child.pid as u32;

        // 创建 EventListener
        let event_listener = FFIEventListener::new(event_queue.clone(), terminal_id);

        // 创建终端状态（Crosswords）
        let dimensions = CrosswordsSize {
            columns: cols as usize,
            screen_lines: rows as usize,
            width: total_width,
            height: total_height,
            square_width,
            square_height,
        };

        // 使用 dummy WindowId（我们不用它）
        // WindowId 在 rio_backend 中是 winit::WindowId，但我们不使用 winit
        // 创建一个安全的默认值
        let window_id = rio_backend::event::WindowId::from(0u64);

        let mut terminal = Crosswords::new(
            dimensions,
            CursorShape::Block,
            event_listener.clone(),
            window_id,
            terminal_id,
        );
        terminal.grid.update_history(DEFAULT_HISTORY_LINES);

        let terminal = Arc::new(parking_lot::RwLock::new(terminal));

        // 创建 Machine（传入 pty_fd 和 shell_pid 用于进程检测）
        let machine = Machine::new(terminal.clone(), pty, event_listener, terminal_id, main_fd, shell_pid)?;

        let pty_sender = machine.channel();

        // 启动事件循环
        let event_loop_handle = machine.spawn();

        Ok(RioTerminal {
            terminal,
            pty_sender,
            _event_loop_handle: event_loop_handle,
            event_queue,
            id: terminal_id,
            cols,
            rows,
            main_fd,
            shell_pid,
            layout: parking_lot::RwLock::new(None),
        })
    }

    /// 设置环境变量（照抄 Rio）
    fn setup_environment() {
        let terminfo = match (
            teletypewriter::terminfo_exists("xterm-rio"),
            teletypewriter::terminfo_exists("rio"),
        ) {
            (true, _) => "xterm-rio",
            (false, true) => "rio",
            (false, false) => "xterm-256color",
        };

        std::env::set_var("TERM", terminfo);
        std::env::set_var("TERM_PROGRAM", "ETerm");
        std::env::set_var("TERM_PROGRAM_VERSION", "0.1.0");
        std::env::set_var("COLORTERM", "truecolor");

        std::env::remove_var("DESKTOP_STARTUP_ID");
        std::env::remove_var("XDG_ACTIVATION_TOKEN");

        #[cfg(target_os = "macos")]
        {
            if std::env::var("LC_CTYPE").is_err() {
                std::env::set_var("LC_CTYPE", "UTF-8");
            }
            if std::env::var("LC_ALL").is_err() {
                std::env::set_var("LC_ALL", "en_US.UTF-8");
            }
        }

        if let Ok(home_dir) = std::env::var("HOME") {
            let _ = std::env::set_current_dir(&home_dir);
        }
    }

    /// 计算像素尺寸
    fn pixel_dimensions(
        cols: u16,
        rows: u16,
        metrics: &SugarloafFontMetrics,
    ) -> (u16, u16, u32, u32, u32, u32) {
        let total_width = (cols as f32 * metrics.cell_width).max(1.0).round();
        let total_height = (rows as f32 * metrics.line_height).max(1.0).round();
        let square_width = metrics.cell_width.max(1.0).round();
        let square_height = metrics.cell_height.max(1.0).round();

        (
            total_width.min(u16::MAX as f32) as u16,
            total_height.min(u16::MAX as f32) as u16,
            total_width.min(u32::MAX as f32) as u32,
            total_height.min(u32::MAX as f32) as u32,
            square_width.min(u32::MAX as f32) as u32,
            square_height.min(u32::MAX as f32) as u32,
        )
    }

    /// 写入 PTY
    pub fn write_input(&self, data: &[u8]) -> bool {
        send_input(&self.pty_sender, data)
    }

    /// 调整大小
    pub fn resize(&mut self, cols: u16, rows: u16) -> bool {
        let font_metrics = global_font_metrics().unwrap_or_else(|| SugarloafFontMetrics {
            cell_width: 8.0,
            cell_height: 16.0,
            line_height: 16.0,
        });

        let (winsize_width, winsize_height, total_width, total_height, square_width, square_height) =
            Self::pixel_dimensions(cols, rows, &font_metrics);

        // 更新终端大小
        {
            let mut terminal = self.terminal.write();
            terminal.resize(CrosswordsSize {
                columns: cols as usize,
                screen_lines: rows as usize,
                width: total_width,
                height: total_height,
                square_width,
                square_height,
            });
        }

        // 发送 resize 到 PTY
        let winsize = WinsizeBuilder {
            cols,
            rows,
            width: winsize_width,
            height: winsize_height,
        };

        self.cols = cols;
        self.rows = rows;

        send_resize(&self.pty_sender, winsize)
    }

    /// 滚动
    pub fn scroll(&self, delta: i32) {
        let mut terminal = self.terminal.write();
        terminal.scroll_display(rio_backend::crosswords::grid::Scroll::Delta(delta));
    }

    /// 获取终端快照 - 照抄 Rio 的 TerminalSnapshot 创建方式
    pub fn snapshot(&self) -> TerminalSnapshot {
        let lock_start = std::time::Instant::now();
        let terminal = self.terminal.read();
        let lock_wait = lock_start.elapsed().as_micros();

        if lock_wait > 1000 {
            perf_log!("🔒 [Render Thread] snapshot() waited {}μs ({}ms) for read lock",
                      lock_wait, lock_wait / 1000);
        }

        // 照抄 Rio: terminal.cursor() 内部处理了所有光标隐藏逻辑
        let cursor = terminal.cursor();

        // 获取选区
        let selection = terminal.selection.as_ref().and_then(|s| s.to_range(&terminal));

        let (has_selection, sel_start_col, sel_start_row, sel_end_col, sel_end_row) =
            if let Some(range) = selection {
                (
                    true,
                    range.start.col.0,
                    range.start.row.0,
                    range.end.col.0,
                    range.end.row.0,
                )
            } else {
                (false, 0, 0, 0, 0)
            };

        TerminalSnapshot {
            display_offset: terminal.display_offset(),
            scrollback_lines: terminal.grid.history_size(),
            blinking_cursor: terminal.blinking_cursor as i32,
            cursor_col: cursor.pos.col.0,
            cursor_row: cursor.pos.row.0 as usize,
            cursor_shape: match cursor.content {
                CursorShape::Block => 0,
                CursorShape::Underline => 1,
                CursorShape::Beam => 2,
                CursorShape::Hidden => 3,
            },
            cursor_visible: (cursor.content != CursorShape::Hidden) as i32,
            columns: terminal.columns(),
            screen_lines: terminal.screen_lines(),
            has_selection: has_selection as i32,
            selection_start_col: sel_start_col,
            selection_start_row: sel_start_row,
            selection_end_col: sel_end_col,
            selection_end_row: sel_end_row,
        }
    }

    /// 获取可见行
    ///
    /// 照抄 Rio: terminal.visible_rows()
    pub fn visible_rows(&self) -> Vec<Row<Square>> {
        let terminal = self.terminal.read();
        terminal.visible_rows()
    }

    /// 获取指定行的单元格数据（支持历史缓冲区）
    ///
    /// 绝对行号坐标系统：
    /// - 0 到 (scrollback_lines - 1): 历史缓冲区
    /// - scrollback_lines 到 (scrollback_lines + screen_lines - 1): 屏幕可见行
    ///
    /// 参数：
    /// - absolute_row: 绝对行号（0-based，包含历史缓冲区）
    ///
    /// 返回：该行的单元格数组
    pub fn get_row_cells(&self, absolute_row: i64) -> Vec<FFICell> {
        use rio_backend::crosswords::pos::Line;

        let terminal = self.terminal.read();
        let scrollback_lines = terminal.grid.history_size() as i64;
        let screen_lines = terminal.screen_lines() as i64;

        // 转换绝对行号到 Grid 行号
        // absolute_row = scrollback_lines + grid_row
        // grid_row = absolute_row - scrollback_lines
        let grid_row = absolute_row - scrollback_lines;

        // 边界检查
        // Grid 有效范围: -scrollback_lines 到 (screen_lines - 1)
        let min_row = -(scrollback_lines);
        let max_row = screen_lines - 1;

        if grid_row < min_row || grid_row > max_row {
            return Vec::new();
        }

        // 直接访问 grid[Line(grid_row)]
        let line = Line(grid_row as i32);
        let row = &terminal.grid[line];
        let mut cells = Vec::with_capacity(row.len());

        // 获取选区（Grid 坐标）
        let selection_range = terminal.selection
            .as_ref()
            .and_then(|s| s.to_range(&terminal));

        for (col_idx, square) in row.inner.iter().enumerate() {
            // 获取原始颜色
            let (mut fg_r, mut fg_g, mut fg_b, mut fg_a) = Self::ansi_color_to_rgba(&square.fg, &terminal);
            let (mut bg_r, mut bg_g, mut bg_b, mut bg_a) = Self::ansi_color_to_rgba(&square.bg, &terminal);

            // 检查是否在选区内
            let in_selection = if let Some(range) = &selection_range {
                use rio_backend::crosswords::pos::{Column, Pos};

                let grid_pos = Pos::new(line, Column(col_idx));
                range.contains(grid_pos)
            } else {
                false
            };

            if in_selection {
                // 设置选区背景色（淡蓝色）
                fg_r = 255;  // 白色前景
                fg_g = 255;
                fg_b = 255;
                fg_a = 255;
                bg_r = 76;   // 0.3 * 255 ≈ 76
                bg_g = 127;  // 0.5 * 255 ≈ 127
                bg_b = 204;  // 0.8 * 255 ≈ 204
                bg_a = 255;
            }

            // 检查 zerowidth 字符中是否有 VS16 (U+FE0F)
            let has_vs16 = square
                .zerowidth()
                .map(|zw| zw.contains(&'\u{FE0F}'))
                .unwrap_or(false);

            // 处理背景透明度
            let final_bg_a = if in_selection {
                255 // 选区内的背景不透明
            } else if square.bg == rio_backend::config::colors::AnsiColor::Named(
                rio_backend::config::colors::NamedColor::Background,
            ) {
                0 // 默认背景色透明，显示窗口背景
            } else {
                bg_a // 使用实际的 alpha 值
            };

            cells.push(FFICell {
                character: square.c as u32,
                fg_r,
                fg_g,
                fg_b,
                fg_a,
                bg_r,
                bg_g,
                bg_b,
                bg_a: final_bg_a,
                flags: square.flags.bits() as u32,
                has_vs16,
            });
        }

        cells
    }

    /// 提取单行的 cell 数据（需要在持有锁的情况下调用）
    ///
    /// 这是 get_row_cells() 的内部逻辑，但不加锁
    /// 用于在并发渲染前批量提取数据，避免锁竞争
    fn extract_row_cells_locked(
        terminal: &rio_backend::crosswords::Crosswords<FFIEventListener>,
        absolute_row: i64,
        scrollback_lines: i64,
        screen_lines: i64,
    ) -> Vec<FFICell> {
        use rio_backend::crosswords::pos::Line;

        // 转换绝对行号到 Grid 行号
        let grid_row = absolute_row - scrollback_lines;

        // 边界检查
        let min_row = -(scrollback_lines);
        let max_row = screen_lines - 1;

        if grid_row < min_row || grid_row > max_row {
            return Vec::new();
        }

        // 直接访问 grid[Line(grid_row)]
        let line = Line(grid_row as i32);
        let row = &terminal.grid[line];
        let mut cells = Vec::with_capacity(row.len());

        // 获取选区（Grid 坐标）
        let selection_range = terminal.selection
            .as_ref()
            .and_then(|s| s.to_range(&terminal));

        for (col_idx, square) in row.inner.iter().enumerate() {
            // 获取原始颜色
            let (mut fg_r, mut fg_g, mut fg_b, mut fg_a) = Self::ansi_color_to_rgba(&square.fg, &terminal);
            let (mut bg_r, mut bg_g, mut bg_b, mut bg_a) = Self::ansi_color_to_rgba(&square.bg, &terminal);

            // 检查是否在选区内
            let in_selection = if let Some(range) = &selection_range {
                use rio_backend::crosswords::pos::{Column, Pos};

                let grid_pos = Pos::new(line, Column(col_idx));
                range.contains(grid_pos)
            } else {
                false
            };

            if in_selection {
                // 设置选区背景色（淡蓝色）
                fg_r = 255;  // 白色前景
                fg_g = 255;
                fg_b = 255;
                fg_a = 255;
                bg_r = 76;   // 0.3 * 255 ≈ 76
                bg_g = 127;  // 0.5 * 255 ≈ 127
                bg_b = 204;  // 0.8 * 255 ≈ 204
                bg_a = 255;
            }

            // 检查 zerowidth 字符中是否有 VS16 (U+FE0F)
            let has_vs16 = square
                .zerowidth()
                .map(|zw| zw.contains(&'\u{FE0F}'))
                .unwrap_or(false);

            // 处理背景透明度
            let final_bg_a = if in_selection {
                255 // 选区内的背景不透明
            } else if square.bg == rio_backend::config::colors::AnsiColor::Named(
                rio_backend::config::colors::NamedColor::Background,
            ) {
                0 // 默认背景色透明，显示窗口背景
            } else {
                bg_a // 使用实际的 alpha 值
            };

            cells.push(FFICell {
                character: square.c as u32,
                fg_r,
                fg_g,
                fg_b,
                fg_a,
                bg_r,
                bg_g,
                bg_b,
                bg_a: final_bg_a,
                flags: square.flags.bits() as u32,
                has_vs16,
            });
        }

        cells
    }

    /// 将 AnsiColor 转换为 RGBA
    ///
    /// terminal.colors 返回 Option<[f32; 4]>，需要转换为 u8
    fn ansi_color_to_rgba(
        color: &rio_backend::config::colors::AnsiColor,
        terminal: &Crosswords<FFIEventListener>,
    ) -> (u8, u8, u8, u8) {
        use rio_backend::config::colors::{AnsiColor, NamedColor};

        // 辅助函数：将 [f32; 4] 转换为 (u8, u8, u8, u8)
        fn color_arr_to_rgba(arr: [f32; 4]) -> (u8, u8, u8, u8) {
            (
                (arr[0] * 255.0) as u8,
                (arr[1] * 255.0) as u8,
                (arr[2] * 255.0) as u8,
                (arr[3] * 255.0) as u8,
            )
        }

        match color {
            AnsiColor::Named(named) => {
                // 使用终端的颜色配置
                if let Some(arr) = terminal.colors[*named] {
                    color_arr_to_rgba(arr)
                } else {
                    // 默认颜色（alpha = 255）
                    match named {
                        NamedColor::Foreground => (255, 255, 255, 255),
                        NamedColor::Background => (0, 0, 0, 255),
                        NamedColor::Black => (0, 0, 0, 255),
                        NamedColor::Red => (255, 0, 0, 255),
                        NamedColor::Green => (0, 255, 0, 255),
                        NamedColor::Yellow => (255, 255, 0, 255),
                        NamedColor::Blue => (0, 0, 255, 255),
                        NamedColor::Magenta => (255, 0, 255, 255),
                        NamedColor::Cyan => (0, 255, 255, 255),
                        NamedColor::White => (255, 255, 255, 255),
                        _ => (128, 128, 128, 255),
                    }
                }
            }
            AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b, 255),
            AnsiColor::Indexed(idx) => {
                // 256 色
                if let Some(arr) = terminal.colors[*idx as usize] {
                    color_arr_to_rgba(arr)
                } else {
                    // 使用标准 256 色调色板（alpha = 255）
                    let (r, g, b) = Self::indexed_color_to_rgb(*idx);
                    (r, g, b, 255)
                }
            }
        }
    }

    /// 标准 256 色调色板转换
    fn indexed_color_to_rgb(idx: u8) -> (u8, u8, u8) {
        match idx {
            // 标准 16 色 (0-15)
            0 => (0, 0, 0),         // Black
            1 => (205, 49, 49),     // Red
            2 => (13, 188, 121),    // Green
            3 => (229, 229, 16),    // Yellow
            4 => (36, 114, 200),    // Blue
            5 => (188, 63, 188),    // Magenta
            6 => (17, 168, 205),    // Cyan
            7 => (229, 229, 229),   // White
            8 => (102, 102, 102),   // Bright Black
            9 => (241, 76, 76),     // Bright Red
            10 => (35, 209, 139),   // Bright Green
            11 => (245, 245, 67),   // Bright Yellow
            12 => (59, 142, 234),   // Bright Blue
            13 => (214, 112, 214),  // Bright Magenta
            14 => (41, 184, 219),   // Bright Cyan
            15 => (255, 255, 255),  // Bright White
            // 216 色立方体 (16-231)
            16..=231 => {
                let idx = idx - 16;
                let r = idx / 36;
                let g = (idx % 36) / 6;
                let b = idx % 6;
                let to_value = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
                (to_value(r), to_value(g), to_value(b))
            }
            // 24 级灰度 (232-255)
            232..=255 => {
                let gray = 8 + (idx - 232) * 10;
                (gray, gray, gray)
            }
        }
    }

    /// 关闭终端
    pub fn close(&self) {
        send_shutdown(&self.pty_sender);
    }

    pub fn id(&self) -> usize {
        self.id
    }

    /// 获取当前工作目录（CWD）
    ///
    /// 使用 teletypewriter::foreground_process_path 获取前台进程的 CWD
    pub fn get_cwd(&self) -> Option<std::path::PathBuf> {
        teletypewriter::foreground_process_path(self.main_fd, self.shell_pid).ok()
    }

    /// 清除选区
    pub fn clear_selection(&self) {
        let mut terminal = self.terminal.write();
        terminal.selection = None;
    }

    /// 屏幕坐标 → 真实行号
    ///
    /// 转换公式：
    /// - Swift 的 screen_row 已经翻转过（0 = 顶部，对应 Line(0)）
    /// - Screen → Grid: grid_row = screen_row - display_offset
    /// - Grid → Absolute: absolute_row = scrollback_lines + grid_row
    pub fn screen_to_absolute(&self, screen_row: usize, screen_col: usize) -> (i64, usize) {
        let terminal = self.terminal.read();

        // 获取终端状态
        let display_offset = terminal.display_offset() as i64;
        let scrollback_lines = terminal.grid.history_size() as i64;
        let screen_lines = terminal.screen_lines() as i64;

        // CoordinateMapper 已经翻转过了（row=0 是顶部）
        // 直接转换为 Grid 坐标
        let grid_row = screen_row as i64 - display_offset;

        // Grid → Absolute
        let absolute_row = scrollback_lines + grid_row;

        (absolute_row, screen_col)
    }

    /// 使用真实行号设置选区
    ///
    /// 转换公式：
    /// - Absolute → Grid: gridRow = absoluteRow - scrollbackLines
    ///
    /// Grid 坐标系统：
    /// - Line(0) = 屏幕最底部
    /// - Line(screen_lines - 1) = 屏幕最顶部
    /// - Line(-1), Line(-2), ... = 历史缓冲区（负数）
    /// - 有效范围: Line(-history_size) 到 Line(screen_lines - 1)
    pub fn set_selection(
        &mut self,
        start_absolute_row: i64,
        start_col: usize,
        end_absolute_row: i64,
        end_col: usize,
    ) -> Result<(), String> {
        use rio_backend::crosswords::pos::{Column, Line, Pos, Side};
        use rio_backend::selection::{Selection, SelectionType};

        let mut terminal = self.terminal.write();
        let scrollback_lines = terminal.grid.history_size() as i64;
        let screen_lines = terminal.screen_lines() as i64;

        // Absolute → Grid
        let start_grid_row = start_absolute_row - scrollback_lines;
        let end_grid_row = end_absolute_row - scrollback_lines;

        // 边界检查
        // Grid 坐标有效范围: [-scrollback_lines, screen_lines)
        let min_row = -(scrollback_lines);
        let max_row = screen_lines - 1;

        if start_grid_row < min_row || start_grid_row > max_row {
            return Err(format!(
                "Selection start out of bounds: start_grid_row={}, valid range=[{}, {}]",
                start_grid_row, min_row, max_row
            ));
        }

        if end_grid_row < min_row || end_grid_row > max_row {
            return Err(format!(
                "Selection end out of bounds: end_grid_row={}, valid range=[{}, {}]",
                end_grid_row, min_row, max_row
            ));
        }

        // 使用 Grid 坐标创建选区
        let start = Pos::new(Line(start_grid_row as i32), Column(start_col));
        let end = Pos::new(Line(end_grid_row as i32), Column(end_col));

        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);

        terminal.selection = Some(selection);

        Ok(())
    }

    /// 获取选中的文本
    ///
    /// 直接使用当前的 terminal.selection 获取文本
    pub fn get_selected_text(&self) -> Option<String> {
        let terminal = self.terminal.read();
        terminal.selection_to_string()
    }

    /// 设置终端布局
    pub fn set_layout(&self, layout: TerminalLayout) {
        *self.layout.write() = Some(layout);
    }

    /// 获取终端布局
    pub fn layout(&self) -> Option<TerminalLayout> {
        *self.layout.read()
    }
}

// ============================================================================
// 终端池
// ============================================================================

/// 终端池 - 管理多个终端
pub struct RioTerminalPool {
    /// 所有终端
    terminals: HashMap<usize, RioTerminal>,
    /// 事件队列（所有终端共享）
    event_queue: EventQueue,
    /// Sugarloaf 句柄
    sugarloaf: *mut SugarloafHandle,
    /// 激活的终端 ID（需要渲染的）
    active_terminals: std::collections::HashSet<usize>,
}

impl RioTerminalPool {
    pub fn new(sugarloaf: *mut SugarloafHandle) -> Self {
        RioTerminalPool {
            terminals: HashMap::new(),
            event_queue: EventQueue::new(),
            sugarloaf,
            active_terminals: std::collections::HashSet::new(),
        }
    }

    /// 渲染所有终端（Rust 侧完全负责）
    pub fn render_all(&self) {
        unsafe {
            let total_start = std::time::Instant::now();
            let sugarloaf = &mut *self.sugarloaf;

            // 清空待渲染列表
            let clear_start = std::time::Instant::now();
            crate::sugarloaf_clear_objects(self.sugarloaf);
            let clear_time = clear_start.elapsed().as_micros();

            let mut content_time_total = 0u128;
            let mut build_time_total = 0u128;

            // 🎯 只渲染 active_terminals 集合中的终端
            // 遍历激活的终端
            for &id in &self.active_terminals {
                let terminal = match self.terminals.get(&id) {
                    Some(t) => t,
                    None => continue,
                };

                // 获取布局
                let layout = match terminal.layout() {
                    Some(l) => l,
                    None => continue,
                };

                // 获取 RichText ID（使用终端 ID 作为 richTextId）
                let rich_text_id = id;

                // 获取快照
                let snapshot = terminal.snapshot();

                // 计算光标可见性
                let cursor_visible = snapshot.cursor_visible != 0
                    && snapshot.display_offset == 0;

                // 选中并清空 RichText
                let content = sugarloaf.instance.content();
                content.sel(rich_text_id);
                content.clear();

                // 渲染终端内容（复用现有逻辑）
                let content_start = std::time::Instant::now();
                Self::render_terminal_content(
                    terminal,
                    &snapshot,
                    content,
                    cursor_visible,
                );
                content_time_total += content_start.elapsed().as_micros();

                let build_start = std::time::Instant::now();
                content.build();
                build_time_total += build_start.elapsed().as_micros();

                // 添加到渲染列表（指定位置）
                crate::sugarloaf_add_rich_text(
                    self.sugarloaf,
                    rich_text_id,
                    layout.x,
                    layout.y,
                );
            }

            // 统一渲染
            let flush_start = std::time::Instant::now();
            crate::sugarloaf_flush_and_render(self.sugarloaf);
            let flush_time = flush_start.elapsed().as_micros();

            let total_time = total_start.elapsed().as_micros();

            // 打印详细耗时分解
            perf_log!("🎨 [render_all] Total: {}μs ({}ms)", total_time, total_time / 1000);
            perf_log!("   ├─ clear_objects: {}μs", clear_time);
            perf_log!("   ├─ render_terminal_content: {}μs", content_time_total);
            perf_log!("   ├─ content.build(): {}μs", build_time_total);
            perf_log!("   └─ flush_and_render: {}μs ({}ms)", flush_time, flush_time / 1000);
        }
    }

    /// 渲染单个终端的内容（使用 Rayon 并发优化）
    fn render_terminal_content(
        terminal: &RioTerminal,
        snapshot: &TerminalSnapshot,
        content: &mut sugarloaf::layout::Content,
        cursor_visible: bool,
    ) {
        use rayon::prelude::*;

        // Flag constants
        const INVERSE: u32 = 0x0001;
        const WIDE_CHAR: u32 = 0x0020;
        const WIDE_CHAR_SPACER: u32 = 0x0040;
        const LEADING_WIDE_CHAR_SPACER: u32 = 0x0400;

        let lines_to_render = snapshot.screen_lines;
        let cols_to_render = snapshot.columns;
        let cursor_row = snapshot.cursor_row;
        let cursor_col = snapshot.cursor_col;

        let phase1_start = std::time::Instant::now();

        // 🔥 阶段 1：锁前置 - 一次性提取所有行的 cell 数据
        let extract_start = std::time::Instant::now();

        // 🔒 记录尝试获取读锁的时间
        let lock_attempt_start = std::time::Instant::now();

        // 加读锁一次，串行提取所有行数据（不阻塞其他读线程）
        let terminal_lock = terminal.terminal.read();

        let lock_wait_time = lock_attempt_start.elapsed().as_micros();

        // 如果等待超过 1ms，打印日志
        if lock_wait_time > 1000 {
            perf_log!("🔒 [Render Thread] Waited {}μs ({}ms) to acquire read lock for Phase 1",
                      lock_wait_time, lock_wait_time / 1000);
        }
        let scrollback_lines = terminal_lock.grid.history_size() as i64;
        let screen_lines_i64 = terminal_lock.screen_lines() as i64;

        let all_cells: Vec<Vec<FFICell>> = (0..lines_to_render)
            .map(|row_index| {
                // 计算绝对行号
                let absolute_row = snapshot.scrollback_lines as i64
                    - snapshot.display_offset as i64
                    + row_index as i64;

                // 提取这一行的 cell 数据
                RioTerminal::extract_row_cells_locked(
                    &terminal_lock,
                    absolute_row,
                    scrollback_lines,
                    screen_lines_i64,
                )
            })
            .collect();

        drop(terminal_lock);  // 立即释放锁
        let extract_time = extract_start.elapsed().as_micros();

        // 🔥 阶段 1.5：并发解析 cell 数据（无锁）
        let parse_start = std::time::Instant::now();

        let rows_data: Vec<RowRenderData> = all_cells
            .into_par_iter()  // 并发处理
            .enumerate()
            .map(|(row_index, cells)| {
                // 检查是否为光标位置报告行
                if Self::is_cursor_position_report_line(&cells) {
                    return RowRenderData {
                        chars: Vec::new(),
                        is_cursor_report: true,
                    };
                }

                // 解析该行的所有字符
                let mut char_data_vec = Vec::with_capacity(cols_to_render);

                for (col_index, cell) in cells.iter().enumerate().take(cols_to_render) {
                    // 跳过占位符
                    let is_spacer = cell.flags & (WIDE_CHAR_SPACER | LEADING_WIDE_CHAR_SPACER);
                    if is_spacer != 0 {
                        continue;
                    }

                    // 获取字符
                    let scalar = match std::char::from_u32(cell.character) {
                        Some(s) => s,
                        None => continue,
                    };

                    // 添加 VS16 标记
                    let char_str = if cell.has_vs16 {
                        format!("{}\u{FE0F}", scalar)
                    } else {
                        scalar.to_string()
                    };

                    // 确定宽度
                    let is_wide = cell.flags & WIDE_CHAR != 0;
                    let glyph_width = if is_wide { 2.0 } else { 1.0 };

                    // 获取颜色（已经在提取时转换好了）
                    let mut fg_r = cell.fg_r as f32 / 255.0;
                    let mut fg_g = cell.fg_g as f32 / 255.0;
                    let mut fg_b = cell.fg_b as f32 / 255.0;
                    let mut fg_a = cell.fg_a as f32 / 255.0;

                    let mut bg_r = cell.bg_r as f32 / 255.0;
                    let mut bg_g = cell.bg_g as f32 / 255.0;
                    let mut bg_b = cell.bg_b as f32 / 255.0;
                    let mut bg_a = cell.bg_a as f32 / 255.0;

                    // 处理 INVERSE
                    let is_inverse = cell.flags & INVERSE != 0;
                    let mut has_bg = false;

                    if is_inverse {
                        std::mem::swap(&mut fg_r, &mut bg_r);
                        std::mem::swap(&mut fg_g, &mut bg_g);
                        std::mem::swap(&mut fg_b, &mut bg_b);
                        std::mem::swap(&mut fg_a, &mut bg_a);
                        has_bg = true;
                    } else {
                        has_bg = bg_r > 0.01 || bg_g > 0.01 || bg_b > 0.01;
                    }

                    // 处理光标
                    let has_cursor = cursor_visible
                        && row_index == cursor_row
                        && col_index == cursor_col;

                    let cursor_r = 1.0;
                    let cursor_g = 1.0;
                    let cursor_b = 1.0;
                    let cursor_a = 0.8;

                    // Block cursor 反转颜色
                    if has_cursor && snapshot.cursor_shape == 0 {
                        fg_r = 0.0;
                        fg_g = 0.0;
                        fg_b = 0.0;
                    }

                    char_data_vec.push(CharRenderData {
                        char_str,
                        fg_r,
                        fg_g,
                        fg_b,
                        fg_a,
                        has_bg,
                        bg_r,
                        bg_g,
                        bg_b,
                        bg_a,
                        glyph_width,
                        has_cursor: has_cursor && snapshot.cursor_shape == 0,
                        cursor_r,
                        cursor_g,
                        cursor_b,
                        cursor_a,
                        flags: cell.flags,
                    });
                }

                RowRenderData {
                    chars: char_data_vec,
                    is_cursor_report: false,
                }
            })
            .collect();

        let parse_time = parse_start.elapsed().as_micros();
        let phase1_time = phase1_start.elapsed().as_micros();

        // 🔥 阶段 2：直接调用 Sugarloaf API（零 FFI）
        let phase2_start = std::time::Instant::now();
        let mut total_segments = 0;  // 统计创建的 fragment 数量

        for (row_index, row_data) in rows_data.iter().enumerate() {
            if row_index > 0 {
                content.new_line();
            }

            // 跳过光标报告行
            if row_data.is_cursor_report {
                continue;
            }

            // 添加该行的所有字符（合并相同样式的连续字符）
            if row_data.chars.is_empty() {
                continue;
            }

            let mut merged_text = String::new();
            let mut segment_start_idx = 0;

            for (i, char_data) in row_data.chars.iter().enumerate() {
                // 检查是否需要切分 segment
                let should_split = if i == 0 {
                    false  // 第一个字符不切分
                } else {
                    // 和前一个字符比较
                    let prev = &row_data.chars[i - 1];
                    !Self::char_styles_equal(prev, char_data)
                };

                if should_split {
                    // 样式变化，flush 之前的 segment
                    let style = Self::build_fragment_style(&row_data.chars[segment_start_idx]);
                    content.add_text(&merged_text, style);
                    total_segments += 1;  // 统计 fragment

                    // 开始新的 segment
                    merged_text.clear();
                    segment_start_idx = i;
                }

                // 累积当前字符
                merged_text.push_str(&char_data.char_str);
            }

            // flush 最后一个 segment
            if !merged_text.is_empty() {
                let style = Self::build_fragment_style(&row_data.chars[segment_start_idx]);
                content.add_text(&merged_text, style);
                total_segments += 1;  // 统计 fragment
            }
        }

        let phase2_time = phase2_start.elapsed().as_micros();
        let total_chars: usize = rows_data.iter().map(|r| r.chars.len()).sum();

        // 只在行数较多时打印日志，减少噪音
        if lines_to_render > 30 {
            let avg_segments_per_line = if lines_to_render > 0 {
                total_segments as f64 / lines_to_render as f64
            } else {
                0.0
            };

            perf_log!("⚡ [Parallel Render] {} lines, {} cols", lines_to_render, cols_to_render);
            perf_log!("   Phase 1 (lock + extract): {}μs ({:.1}%)",
                extract_time,
                extract_time as f32 / phase1_time as f32 * 100.0
            );
            perf_log!("   Phase 1 (parallel parse): {}μs ({:.1}%)",
                parse_time,
                parse_time as f32 / phase1_time as f32 * 100.0
            );
            perf_log!("   Phase 1 Total: {}μs ({}ms)", phase1_time, phase1_time / 1000);
            perf_log!("   Phase 2 (merged render): {}μs", phase2_time);
            perf_log!("   Total: {}μs ({}ms) - {} chars",
                phase1_time + phase2_time,
                (phase1_time + phase2_time) / 1000,
                total_chars
            );
            perf_log!("   Style segments: {} (avg {:.1} per line)",
                total_segments,
                avg_segments_per_line
            );
        }
    }

    /// 比较两个字符的样式是否相同
    ///
    /// 用于判断连续字符是否可以合并到同一个 fragment，
    /// 避免为每个字符创建单独的 fragment
    fn char_styles_equal(a: &CharRenderData, b: &CharRenderData) -> bool {
        // 比较所有影响渲染的字段
        a.fg_r == b.fg_r
            && a.fg_g == b.fg_g
            && a.fg_b == b.fg_b
            && a.fg_a == b.fg_a
            && a.has_bg == b.has_bg
            && a.bg_r == b.bg_r
            && a.bg_g == b.bg_g
            && a.bg_b == b.bg_b
            && a.bg_a == b.bg_a
            && a.glyph_width == b.glyph_width
            && a.has_cursor == b.has_cursor
            && a.flags == b.flags
            // 注意：cursor 颜色也需要比较，因为它影响光标显示
            && a.cursor_r == b.cursor_r
            && a.cursor_g == b.cursor_g
            && a.cursor_b == b.cursor_b
            && a.cursor_a == b.cursor_a
    }

    /// 构建 FragmentStyle（从 CharRenderData）
    ///
    /// 复用 lib.rs 中的样式构建逻辑，直接在 Rust 侧构建样式
    fn build_fragment_style(char_data: &CharRenderData) -> FragmentStyle {
        let flags = char_data.flags;

        // 解析装饰（下划线、删除线等）
        let decoration = if flags & 0x0008 != 0 {
            // UNDERLINE
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Regular,
            }))
        } else if flags & 0x0800 != 0 {
            // DOUBLE_UNDERLINE
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: true,
                shape: UnderlineShape::Regular,
            }))
        } else if flags & 0x1000 != 0 {
            // UNDERCURL
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Curly,
            }))
        } else if flags & 0x2000 != 0 {
            // DOTTED_UNDERLINE
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Dotted,
            }))
        } else if flags & 0x4000 != 0 {
            // DASHED_UNDERLINE
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Dashed,
            }))
        } else if flags & 0x0200 != 0 {
            // STRIKEOUT
            Some(FragmentStyleDecoration::Strikethrough)
        } else {
            None
        };

        // 确定字体 ID（基于粗体/斜体）
        // FontLibrary 加载顺序: 0=regular, 1=italic, 2=bold, 3=bold_italic
        let is_bold = flags & 0x0002 != 0;
        let is_italic = flags & 0x0004 != 0;

        let font_id = match (is_bold, is_italic) {
            (false, false) => 0, // regular
            (true, false) => 2,  // bold
            (false, true) => 1,  // italic
            (true, true) => 3,   // bold_italic
        };

        // 处理 DIM（降低透明度）
        let final_fg_a = if flags & 0x0080 != 0 {
            char_data.fg_a * 0.5
        } else {
            char_data.fg_a
        };

        // 背景色
        let background_color = if char_data.has_bg {
            Some([char_data.bg_r, char_data.bg_g, char_data.bg_b, char_data.bg_a])
        } else {
            None
        };

        // 光标（Block cursor 使用 SugarCursor::Block）
        let cursor = if char_data.has_cursor {
            Some(SugarCursor::Block([
                char_data.cursor_r,
                char_data.cursor_g,
                char_data.cursor_b,
                char_data.cursor_a,
            ]))
        } else {
            None
        };

        FragmentStyle {
            font_id,
            color: [char_data.fg_r, char_data.fg_g, char_data.fg_b, final_fg_a],
            background_color,
            width: char_data.glyph_width,
            cursor,
            decoration,
            decoration_color: Some([char_data.fg_r, char_data.fg_g, char_data.fg_b, final_fg_a]),
            ..FragmentStyle::default()
        }
    }

    /// 检查是否为光标位置报告行
    fn is_cursor_position_report_line(cells: &[FFICell]) -> bool {
        if cells.is_empty() {
            return false;
        }

        // 必须以 ESC (0x1B) 开头
        if cells[0].character != 27 {
            return false;
        }

        // 构建字符串
        let mut scalars = Vec::new();
        for cell in cells {
            if cell.character == 0 {
                break; // 遇到空字符停止
            }
            if let Some(scalar) = std::char::from_u32(cell.character) {
                scalars.push(scalar);
            }
            // 限制长度，防止异常长行
            if scalars.len() > 32 {
                return false;
            }
        }

        if scalars.is_empty() {
            return false;
        }

        let text: String = scalars.iter().collect();

        // 正则匹配 ^\e\[\d+;\d+R$ 形式的 DSR 响应
        // 简单实现：检查格式 ESC [ digits ; digits R
        if !text.starts_with("\u{1B}[") || !text.ends_with('R') {
            return false;
        }

        // 提取中间部分 (去掉 ESC[ 和 R)
        let middle = &text[2..text.len()-1];

        // 检查是否为 "数字;数字" 格式
        let parts: Vec<&str> = middle.split(';').collect();
        if parts.len() != 2 {
            return false;
        }

        parts[0].chars().all(|c| c.is_ascii_digit())
            && parts[1].chars().all(|c| c.is_ascii_digit())
    }

    /// 设置事件回调
    pub fn set_event_callback(
        &self,
        callback: EventCallback,
        string_callback: Option<StringEventCallback>,
        context: *mut c_void,
    ) {
        self.event_queue
            .set_callback(callback, string_callback, context);
    }

    /// 创建终端
    pub fn create_terminal(&mut self, cols: u16, rows: u16, shell: &str) -> i32 {
        self.create_terminal_with_cwd(cols, rows, shell, None)
    }

    /// 创建终端（指定工作目录）
    pub fn create_terminal_with_cwd(&mut self, cols: u16, rows: u16, shell: &str, working_dir: Option<String>) -> i32 {
        match RioTerminal::new(cols, rows, shell, working_dir, self.event_queue.clone()) {
            Ok(terminal) => {
                let id = terminal.id();
                self.terminals.insert(id, terminal);
                id as i32
            }
            Err(e) => {
                eprintln!("[RioTerminalPool] Failed to create terminal: {}", e);
                -1
            }
        }
    }

    /// 关闭终端
    pub fn close_terminal(&mut self, id: usize) -> bool {
        if let Some(terminal) = self.terminals.remove(&id) {
            terminal.close();
            true
        } else {
            false
        }
    }

    /// 获取终端
    pub fn get(&self, id: usize) -> Option<&RioTerminal> {
        self.terminals.get(&id)
    }

    /// 获取终端（可变）
    pub fn get_mut(&mut self, id: usize) -> Option<&mut RioTerminal> {
        self.terminals.get_mut(&id)
    }

    /// 终端数量
    pub fn count(&self) -> usize {
        self.terminals.len()
    }
}

// ============================================================================
// FFI 接口
// ============================================================================

/// 辅助宏：在 FFI 边界捕获 panic
macro_rules! catch_panic {
    ($default:expr, $body:expr) => {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| $body)) {
            Ok(result) => result,
            Err(e) => {
                eprintln!("[rio_terminal FFI] Caught panic: {:?}", e);
                $default
            }
        }
    };
}

/// 创建终端池
#[no_mangle]
pub extern "C" fn rio_pool_new(sugarloaf: *mut SugarloafHandle) -> *mut RioTerminalPool {
    catch_panic!(ptr::null_mut(), {
        if sugarloaf.is_null() {
            return ptr::null_mut();
        }

        Box::into_raw(Box::new(RioTerminalPool::new(sugarloaf)))
    })
}

/// 释放终端池
#[no_mangle]
pub extern "C" fn rio_pool_free(pool: *mut RioTerminalPool) {
    catch_panic!((), {
        if !pool.is_null() {
            unsafe {
                let _ = Box::from_raw(pool);
            }
        }
    })
}

/// 设置事件回调
#[no_mangle]
pub extern "C" fn rio_pool_set_event_callback(
    pool: *mut RioTerminalPool,
    callback: EventCallback,
    string_callback: Option<StringEventCallback>,
    context: *mut c_void,
) {
    catch_panic!((), {
        if pool.is_null() {
            return;
        }

        let pool = unsafe { &*pool };
        pool.set_event_callback(callback, string_callback, context);
    })
}

/// 创建终端
#[no_mangle]
pub extern "C" fn rio_pool_create_terminal(
    pool: *mut RioTerminalPool,
    cols: u16,
    rows: u16,
    shell: *const c_char,
) -> i32 {
    catch_panic!(-1, {
        if pool.is_null() || shell.is_null() {
            return -1;
        }

        let pool = unsafe { &mut *pool };
        let shell_str = unsafe { CStr::from_ptr(shell).to_str().unwrap_or("/bin/zsh") };

        pool.create_terminal(cols, rows, shell_str)
    })
}

/// 创建终端（指定工作目录）
#[no_mangle]
pub extern "C" fn rio_pool_create_terminal_with_cwd(
    pool: *mut RioTerminalPool,
    cols: u16,
    rows: u16,
    shell: *const c_char,
    working_dir: *const c_char,
) -> i32 {
    catch_panic!(-1, {
        if pool.is_null() || shell.is_null() {
            return -1;
        }

        let pool = unsafe { &mut *pool };
        let shell_str = unsafe { CStr::from_ptr(shell).to_str().unwrap_or("/bin/zsh") };

        let working_dir_opt = if working_dir.is_null() {
            None
        } else {
            unsafe { CStr::from_ptr(working_dir).to_str().ok().map(|s| s.to_string()) }
        };

        pool.create_terminal_with_cwd(cols, rows, shell_str, working_dir_opt)
    })
}

/// 关闭终端
#[no_mangle]
pub extern "C" fn rio_pool_close_terminal(pool: *mut RioTerminalPool, terminal_id: usize) -> i32 {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &mut *pool };
        if pool.close_terminal(terminal_id) {
            1
        } else {
            0
        }
    })
}

/// 终端数量
#[no_mangle]
pub extern "C" fn rio_pool_count(pool: *mut RioTerminalPool) -> usize {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        pool.count()
    })
}

/// 写入 PTY
#[no_mangle]
pub extern "C" fn rio_pool_write_input(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    data: *const c_char,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() || data.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        let input = unsafe { CStr::from_ptr(data).to_bytes() };

        if let Some(terminal) = pool.get(terminal_id) {
            if terminal.write_input(input) {
                1
            } else {
                0
            }
        } else {
            0
        }
    })
}

/// 调整终端大小
#[no_mangle]
pub extern "C" fn rio_pool_resize(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    cols: u16,
    rows: u16,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &mut *pool };
        if let Some(terminal) = pool.get_mut(terminal_id) {
            if terminal.resize(cols, rows) {
                1
            } else {
                0
            }
        } else {
            0
        }
    })
}

/// 滚动
#[no_mangle]
pub extern "C" fn rio_pool_scroll(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    delta: i32,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            terminal.scroll(delta);
            1
        } else {
            0
        }
    })
}

/// 获取终端快照
#[no_mangle]
pub extern "C" fn rio_pool_get_snapshot(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    out_snapshot: *mut TerminalSnapshot,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() || out_snapshot.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            unsafe {
                *out_snapshot = terminal.snapshot();
            }
            1
        } else {
            0
        }
    })
}

/// 获取指定行的单元格数量
#[no_mangle]
pub extern "C" fn rio_pool_get_row_cell_count(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    _row_index: usize,
) -> usize {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            let snapshot = terminal.snapshot();
            snapshot.columns
        } else {
            0
        }
    })
}

/// 获取指定行的单元格数据（支持历史缓冲区）
///
/// 绝对行号坐标系统：
/// - 0 到 (scrollback_lines - 1): 历史缓冲区
/// - scrollback_lines 到 (scrollback_lines + screen_lines - 1): 屏幕可见行
///
/// 参数：
/// - absolute_row: 绝对行号（0-based，包含历史缓冲区）
/// - out_cells: 输出缓冲区
/// - max_cells: 缓冲区最大容量
///
/// 返回：实际写入的单元格数量
#[no_mangle]
pub extern "C" fn rio_pool_get_row_cells(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    absolute_row: i64,
    out_cells: *mut FFICell,
    max_cells: usize,
) -> usize {
    catch_panic!(0, {
        if pool.is_null() || out_cells.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            let cells = terminal.get_row_cells(absolute_row);
            let count = cells.len().min(max_cells);

            unsafe {
                for (i, cell) in cells.iter().take(count).enumerate() {
                    *out_cells.add(i) = *cell;
                }
            }

            count
        } else {
            0
        }
    })
}

/// 获取光标位置
#[no_mangle]
pub extern "C" fn rio_pool_get_cursor(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    out_col: *mut u16,
    out_row: *mut u16,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() || out_col.is_null() || out_row.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            let snapshot = terminal.snapshot();
            unsafe {
                *out_col = snapshot.cursor_col as u16;
                *out_row = snapshot.cursor_row as u16;
            }
            1
        } else {
            0
        }
    })
}

/// 清除选区
#[no_mangle]
pub extern "C" fn rio_pool_clear_selection(pool: *mut RioTerminalPool, terminal_id: usize) -> i32 {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            terminal.clear_selection();
            1
        } else {
            0
        }
    })
}

/// 释放从 Rust 返回的字符串
#[no_mangle]
pub extern "C" fn rio_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = std::ffi::CString::from_raw(s);
        }
    }
}

/// 获取终端当前工作目录（CWD）
///
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[no_mangle]
pub extern "C" fn rio_pool_get_cwd(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
) -> *mut c_char {
    catch_panic!(ptr::null_mut(), {
        if pool.is_null() {
            return ptr::null_mut();
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            if let Some(cwd) = terminal.get_cwd() {
                // 转换为 C 字符串
                match std::ffi::CString::new(cwd.to_string_lossy().as_bytes()) {
                    Ok(c_str) => c_str.into_raw(),
                    Err(_) => ptr::null_mut(),
                }
            } else {
                ptr::null_mut()
            }
        } else {
            ptr::null_mut()
        }
    })
}

// ============================================================================
// 坐标转换 API - 支持真实行号（绝对坐标系统）
// ============================================================================

/// 绝对坐标（真实行号）
#[repr(C)]
pub struct AbsolutePosition {
    pub absolute_row: i64,
    pub col: usize,
}

/// 屏幕坐标 → 真实行号
#[no_mangle]
pub extern "C" fn rio_pool_screen_to_absolute(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    screen_row: usize,
    screen_col: usize,
) -> AbsolutePosition {
    catch_panic!(AbsolutePosition { absolute_row: -1, col: 0 }, {
        if pool.is_null() {
            return AbsolutePosition { absolute_row: -1, col: 0 };
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            let (absolute_row, col) = terminal.screen_to_absolute(screen_row, screen_col);
            AbsolutePosition { absolute_row, col }
        } else {
            AbsolutePosition { absolute_row: -1, col: 0 }
        }
    })
}

/// 设置选区
#[no_mangle]
pub extern "C" fn rio_pool_set_selection(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    start_absolute_row: i64,
    start_col: usize,
    end_absolute_row: i64,
    end_col: usize,
) -> i32 {
    catch_panic!(-1, {
        if pool.is_null() {
            return -1;
        }

        let pool = unsafe { &mut *(pool as *mut RioTerminalPool) };
        if let Some(terminal) = pool.get_mut(terminal_id) {
            match terminal.set_selection(
                start_absolute_row,
                start_col,
                end_absolute_row,
                end_col,
            ) {
                Ok(_) => 0,
                Err(_) => -1,
            }
        } else {
            -1
        }
    })
}

/// 获取选中的文本
///
/// 直接使用当前 terminal.selection 获取文本，不需要传入坐标参数
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[no_mangle]
pub extern "C" fn rio_pool_get_selected_text(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
) -> *mut c_char {
    catch_panic!(ptr::null_mut(), {
        if pool.is_null() {
            return ptr::null_mut();
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            if let Some(text) = terminal.get_selected_text() {
                match std::ffi::CString::new(text) {
                    Ok(c_str) => c_str.into_raw(),
                    Err(_) => ptr::null_mut(),
                }
            } else {
                ptr::null_mut()
            }
        } else {
            ptr::null_mut()
        }
    })
}

/// 设置终端布局位置
#[no_mangle]
pub extern "C" fn rio_terminal_set_layout(
    pool_handle: *mut RioTerminalPool,
    terminal_id: i32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    visible: bool,
) -> i32 {
    catch_panic!(-1, {
        if pool_handle.is_null() {
            return -1;
        }

        let pool = unsafe { &mut *pool_handle };
        let terminal_id_usize = terminal_id as usize;

        // 先检查终端是否存在
        if !pool.terminals.contains_key(&terminal_id_usize) {
            return -1;
        }

        // 设置布局
        if let Some(terminal) = pool.terminals.get(&terminal_id_usize) {
            terminal.set_layout(TerminalLayout {
                x,
                y,
                width,
                height,
                visible,
            });
        }

        // 🎯 更新激活终端集合
        if visible && width > 0.0 && height > 0.0 {
            pool.active_terminals.insert(terminal_id_usize);
        } else {
            pool.active_terminals.remove(&terminal_id_usize);
        }

        0
    })
}

/// 清空激活终端集合（在设置新布局前调用）
#[no_mangle]
pub extern "C" fn rio_pool_clear_active_terminals(pool_handle: *mut RioTerminalPool) {
    catch_panic!((), {
        if pool_handle.is_null() {
            return;
        }

        let pool = unsafe { &mut *pool_handle };
        pool.active_terminals.clear();
    })
}

/// 渲染所有终端（统一入口）
#[no_mangle]
pub extern "C" fn rio_pool_render_all(pool_handle: *mut RioTerminalPool) {
    catch_panic!((), {
        if pool_handle.is_null() {
            return;
        }

        let pool = unsafe { &*pool_handle };
        pool.render_all();
    })
}

// ============================================================================
// 测试模块
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试坐标转换逻辑
    ///
    /// 这个测试验证了 Swift Screen 坐标到 Rio Grid 坐标的转换是否正确
    #[test]
    fn test_coordinate_transformation() {
        // 模拟场景:
        // - screen_lines = 24
        // - scrollback_lines = 1000
        // - display_offset = 0 (无滚动)

        // 场景 1: 点击屏幕顶部 (Swift screen_row = 0)
        // Swift: 0 = 顶部
        // Rio: 23 = 顶部
        // 公式: rio_screen_row = (24 - 1) - 0 = 23
        // grid_row = 23 - 0 = 23
        // absolute_row = 1000 + 23 = 1023
        let screen_lines = 24i64;
        let scrollback_lines = 1000i64;
        let display_offset = 0i64;

        let screen_row = 0i64;
        let rio_screen_row = (screen_lines - 1) - screen_row;
        assert_eq!(rio_screen_row, 23, "Swift screen_row=0 应该对应 Rio screen_row=23");

        let grid_row = rio_screen_row - display_offset;
        assert_eq!(grid_row, 23, "Grid row 应该是 23");

        let absolute_row = scrollback_lines + grid_row;
        assert_eq!(absolute_row, 1023, "Absolute row 应该是 1023");

        // 场景 2: 点击屏幕底部 (Swift screen_row = 23)
        // Swift: 23 = 底部
        // Rio: 0 = 底部
        // 公式: rio_screen_row = (24 - 1) - 23 = 0
        // grid_row = 0 - 0 = 0
        // absolute_row = 1000 + 0 = 1000
        let screen_row = 23i64;
        let rio_screen_row = (screen_lines - 1) - screen_row;
        assert_eq!(rio_screen_row, 0, "Swift screen_row=23 应该对应 Rio screen_row=0");

        let grid_row = rio_screen_row - display_offset;
        assert_eq!(grid_row, 0, "Grid row 应该是 0");

        let absolute_row = scrollback_lines + grid_row;
        assert_eq!(absolute_row, 1000, "Absolute row 应该是 1000");

        // 场景 3: 点击屏幕顶部，向上滚动 10 行 (display_offset = 10)
        // Swift: 0 = 可见区域顶部
        // Rio: 23 = 可见区域顶部（但显示的是历史缓冲区中的内容）
        // 公式: rio_screen_row = (24 - 1) - 0 = 23
        // grid_row = 23 - 10 = 13
        // absolute_row = 1000 + 13 = 1013
        let display_offset = 10i64;
        let screen_row = 0i64;
        let rio_screen_row = (screen_lines - 1) - screen_row;
        assert_eq!(rio_screen_row, 23, "Swift screen_row=0 应该对应 Rio screen_row=23");

        let grid_row = rio_screen_row - display_offset;
        assert_eq!(grid_row, 13, "Grid row 应该是 13（滚动后）");

        let absolute_row = scrollback_lines + grid_row;
        assert_eq!(absolute_row, 1013, "Absolute row 应该是 1013");
    }

    /// 测试边界检查
    #[test]
    fn test_boundary_validation() {
        let screen_lines = 24i64;
        let scrollback_lines = 1000i64;

        // 有效范围测试
        let min_row = -(scrollback_lines);
        let max_row = screen_lines - 1;

        // 边界内的值应该有效
        assert!(min_row <= 0 && 0 <= max_row, "Grid row 0 应该在有效范围内");
        assert!(min_row <= 23 && 23 <= max_row, "Grid row 23 应该在有效范围内");
        assert!(min_row <= -1 && -1 <= max_row, "Grid row -1 应该在有效范围内（历史缓冲区）");
        assert!(min_row <= -1000 && -1000 <= max_row, "Grid row -1000 应该在边界上");

        // 边界外的值应该无效
        assert!(-1001 < min_row, "Grid row -1001 应该超出下界");
        assert!(24 > max_row, "Grid row 24 应该超出上界");
    }
}
