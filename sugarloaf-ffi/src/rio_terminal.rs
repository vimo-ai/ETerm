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
use rio_backend::crosswords::square::Square;
use rio_backend::crosswords::{Crosswords, CrosswordsSize};
use rio_backend::event::Msg;
use teletypewriter::{create_pty_with_fork, WinsizeBuilder};

use crate::rio_event::{EventCallback, EventQueue, FFIEventListener, StringEventCallback};
use crate::rio_machine::{send_input, send_resize, send_shutdown, Machine, State};
use crate::sync::FairMutex;
use crate::{global_font_metrics, SugarloafFontMetrics, SugarloafHandle};

/// 历史行数
const DEFAULT_HISTORY_LINES: usize = 1_000;

/// 全局终端 ID 计数器
static NEXT_TERMINAL_ID: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(1);

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

/// 单个终端
pub struct RioTerminal {
    /// 终端状态
    terminal: Arc<FairMutex<Crosswords<FFIEventListener>>>,
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

        let terminal = Arc::new(FairMutex::new(terminal));

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
            let mut terminal = self.terminal.lock();
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
        let mut terminal = self.terminal.lock();
        terminal.scroll_display(rio_backend::crosswords::grid::Scroll::Delta(delta));
    }

    /// 获取终端快照 - 照抄 Rio 的 TerminalSnapshot 创建方式
    pub fn snapshot(&self) -> TerminalSnapshot {
        let terminal = self.terminal.lock();

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
        let terminal = self.terminal.lock();
        terminal.visible_rows()
    }

    /// 获取指定行的单元格数据
    pub fn get_row_cells(&self, row_index: usize) -> Vec<FFICell> {
        let terminal = self.terminal.lock();
        let visible_rows = terminal.visible_rows();

        if row_index >= visible_rows.len() {
            return Vec::new();
        }

        let row = &visible_rows[row_index];
        let mut cells = Vec::with_capacity(row.len());

        for square in row.inner.iter() {
            let (fg_r, fg_g, fg_b) = Self::ansi_color_to_rgb(&square.fg, &terminal);
            let (bg_r, bg_g, bg_b) = Self::ansi_color_to_rgb(&square.bg, &terminal);

            // 检查 zerowidth 字符中是否有 VS16 (U+FE0F)
            let has_vs16 = square
                .zerowidth()
                .map(|zw| zw.contains(&'\u{FE0F}'))
                .unwrap_or(false);

            cells.push(FFICell {
                character: square.c as u32,
                fg_r,
                fg_g,
                fg_b,
                fg_a: 255,
                bg_r,
                bg_g,
                bg_b,
                bg_a: if square.bg == rio_backend::config::colors::AnsiColor::Named(
                    rio_backend::config::colors::NamedColor::Background,
                ) {
                    0
                } else {
                    255
                },
                flags: square.flags.bits() as u32,
                has_vs16,
            });
        }

        cells
    }

    /// 将 AnsiColor 转换为 RGB
    ///
    /// terminal.colors 返回 Option<[f32; 4]>，需要转换为 u8
    fn ansi_color_to_rgb(
        color: &rio_backend::config::colors::AnsiColor,
        terminal: &Crosswords<FFIEventListener>,
    ) -> (u8, u8, u8) {
        use rio_backend::config::colors::{AnsiColor, NamedColor};

        // 辅助函数：将 [f32; 4] 转换为 (u8, u8, u8)
        fn color_arr_to_rgb(arr: [f32; 4]) -> (u8, u8, u8) {
            (
                (arr[0] * 255.0) as u8,
                (arr[1] * 255.0) as u8,
                (arr[2] * 255.0) as u8,
            )
        }

        match color {
            AnsiColor::Named(named) => {
                // 使用终端的颜色配置
                if let Some(arr) = terminal.colors[*named] {
                    color_arr_to_rgb(arr)
                } else {
                    // 默认颜色
                    match named {
                        NamedColor::Foreground => (255, 255, 255),
                        NamedColor::Background => (0, 0, 0),
                        NamedColor::Black => (0, 0, 0),
                        NamedColor::Red => (255, 0, 0),
                        NamedColor::Green => (0, 255, 0),
                        NamedColor::Yellow => (255, 255, 0),
                        NamedColor::Blue => (0, 0, 255),
                        NamedColor::Magenta => (255, 0, 255),
                        NamedColor::Cyan => (0, 255, 255),
                        NamedColor::White => (255, 255, 255),
                        _ => (128, 128, 128),
                    }
                }
            }
            AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b),
            AnsiColor::Indexed(idx) => {
                // 256 色
                if let Some(arr) = terminal.colors[*idx as usize] {
                    color_arr_to_rgb(arr)
                } else {
                    // 使用标准 256 色调色板
                    Self::indexed_color_to_rgb(*idx)
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

    /// 设置选区
    ///
    /// 参数使用屏幕坐标（0-indexed），start 和 end 可以是任意顺序
    /// 内部会根据 display_offset 转换为实际的 grid 坐标
    pub fn set_selection(&self, start_col: usize, start_row: i32, end_col: usize, end_row: i32) {
        use rio_backend::crosswords::pos::{Column, Line, Pos, Side};
        use rio_backend::selection::{Selection, SelectionType};

        let mut terminal = self.terminal.lock();

        // 获取滚动偏移量，将屏幕坐标转换为 grid 坐标
        // display_offset > 0 表示向上滚动查看历史，此时屏幕行号需要减去偏移量
        let display_offset = terminal.display_offset() as i32;
        let actual_start_row = start_row - display_offset;
        let actual_end_row = end_row - display_offset;

        // 创建选区起点和终点
        let start = Pos::new(Line(actual_start_row), Column(start_col));
        let end = Pos::new(Line(actual_end_row), Column(end_col));

        // 创建选区（Simple 类型，支持任意方向）
        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);

        terminal.selection = Some(selection);
    }

    /// 清除选区
    pub fn clear_selection(&self) {
        let mut terminal = self.terminal.lock();
        terminal.selection = None;
    }

    /// 获取选中的文本
    ///
    /// 参数使用屏幕坐标（0-indexed）
    /// 内部会根据 display_offset 转换为实际的 grid 坐标
    pub fn get_selected_text(&self, start_col: usize, start_row: i32, end_col: usize, end_row: i32) -> Option<String> {
        use rio_backend::crosswords::pos::{Column, Line, Pos, Side};
        use rio_backend::selection::{Selection, SelectionType};

        let mut terminal = self.terminal.lock();

        // 获取滚动偏移量，将屏幕坐标转换为 grid 坐标
        // display_offset > 0 表示向上滚动查看历史，此时屏幕行号需要减去偏移量
        let display_offset = terminal.display_offset() as i32;
        let actual_start_row = start_row - display_offset;
        let actual_end_row = end_row - display_offset;

        // 创建临时选区来获取文本范围
        let start = Pos::new(Line(actual_start_row), Column(start_col));
        let end = Pos::new(Line(actual_end_row), Column(end_col));

        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);

        // 临时设置选区
        let old_selection = terminal.selection.take();
        terminal.selection = Some(selection);

        // 获取选中的文本
        let text = terminal.selection_to_string();

        // 恢复原来的选区
        terminal.selection = old_selection;

        text
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
}

impl RioTerminalPool {
    pub fn new(sugarloaf: *mut SugarloafHandle) -> Self {
        RioTerminalPool {
            terminals: HashMap::new(),
            event_queue: EventQueue::new(),
            sugarloaf,
        }
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

/// 获取指定行的单元格数据
#[no_mangle]
pub extern "C" fn rio_pool_get_row_cells(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    row_index: usize,
    out_cells: *mut FFICell,
    max_cells: usize,
) -> usize {
    catch_panic!(0, {
        if pool.is_null() || out_cells.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            let cells = terminal.get_row_cells(row_index);
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

/// 设置选区
#[no_mangle]
pub extern "C" fn rio_pool_set_selection(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    start_col: usize,
    start_row: i32,
    end_col: usize,
    end_row: i32,
) -> i32 {
    catch_panic!(0, {
        if pool.is_null() {
            return 0;
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            terminal.set_selection(start_col, start_row, end_col, end_row);
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

/// 获取选中的文本
///
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[no_mangle]
pub extern "C" fn rio_pool_get_selected_text(
    pool: *mut RioTerminalPool,
    terminal_id: usize,
    start_col: usize,
    start_row: i32,
    end_col: usize,
    end_row: i32,
) -> *mut c_char {
    catch_panic!(ptr::null_mut(), {
        if pool.is_null() {
            return ptr::null_mut();
        }

        let pool = unsafe { &*pool };
        if let Some(terminal) = pool.get(terminal_id) {
            if let Some(text) = terminal.get_selected_text(start_col, start_row, end_col, end_row) {
                // 转换为 C 字符串
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
