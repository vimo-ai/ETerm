use std::ffi::{c_char, c_void, CStr};
use std::io::Read;
use std::ptr;
use std::sync::Arc;
use parking_lot::Mutex;

use rio_backend::ansi::CursorShape;
use rio_backend::crosswords::{Crosswords, CrosswordsSize};
use rio_backend::crosswords::grid::Scroll;
use rio_backend::event::{EventListener, WindowId};
use rio_backend::performer::handler::Processor;
use rio_backend::config::colors::{AnsiColor, NamedColor};
use teletypewriter::{create_pty_with_fork, WinsizeBuilder, ProcessReadWrite};

use crate::{global_font_metrics, SugarloafFontMetrics, SugarloafHandle};

/// 单个终端单元格的数据（用于 FFI）
#[repr(C)]
pub struct TerminalCell {
    pub c: u32,  // UTF-32 字符
    pub fg_r: u8,
    pub fg_g: u8,
    pub fg_b: u8,
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
}

/// 简单的选区范围
#[derive(Debug, Clone, Copy)]
pub struct SelectionRange {
    pub start_col: u16,
    pub start_row: u16,
    pub end_col: u16,
    pub end_row: u16,
}

impl SelectionRange {
    /// 检查某个位置是否在选区内
    pub fn contains(&self, col: u16, row: i32) -> bool {
        let row = row as u16;

        // 归一化起点和终点（确保 start <= end）
        let (start_row, start_col, end_row, end_col) = if self.start_row < self.end_row
            || (self.start_row == self.end_row && self.start_col <= self.end_col)
        {
            (self.start_row, self.start_col, self.end_row, self.end_col)
        } else {
            (self.end_row, self.end_col, self.start_row, self.start_col)
        };

        // 检查是否在范围内
        if row < start_row || row > end_row {
            return false;
        }

        if row == start_row && row == end_row {
            // 同一行
            col >= start_col && col <= end_col
        } else if row == start_row {
            // 起始行
            col >= start_col
        } else if row == end_row {
            // 结束行
            col <= end_col
        } else {
            // 中间行
            true
        }
    }
}

/// 终端句柄
pub struct TerminalHandle {
    pty: Arc<Mutex<teletypewriter::Pty>>,
    terminal: Arc<Mutex<Crosswords<VoidListener>>>,
    parser: Arc<Mutex<Processor>>,
    cols: u16,
    rows: u16,
    font_metrics: SugarloafFontMetrics,
    selection: Arc<Mutex<Option<SelectionRange>>>,  // 🎯 添加选区状态
}

/// 简单的事件监听器实现 (不发送任何事件)
#[derive(Clone)]
struct VoidListener;

impl EventListener for VoidListener {
    fn event(&self) -> (Option<rio_backend::event::RioEvent>, bool) {
        (None, false)
    }
}

const DEFAULT_HISTORY_LINES: usize = 1_000;

fn default_font_metrics() -> SugarloafFontMetrics {
    SugarloafFontMetrics {
        cell_width: 8.0,
        cell_height: 16.0,
        line_height: 16.0,
    }
}

fn resolve_font_metrics() -> SugarloafFontMetrics {
    global_font_metrics().unwrap_or_else(default_font_metrics)
}

fn pixel_dimensions(
    cols: u16,
    rows: u16,
    metrics: &SugarloafFontMetrics,
) -> (u16, u16, u32, u32, u32, u32) {
    let total_width = (cols as f32 * metrics.cell_width).max(1.0).round();
    // ⚠️ 关键修复：使用 line_height 而不是 cell_height 来计算总高度
    let total_height = (rows as f32 * metrics.line_height).max(1.0).round();
    let square_width = metrics.cell_width.max(1.0).round();
    // square_height 保持用 cell_height（字符本身的高度）
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

/// 创建终端
#[no_mangle]
pub extern "C" fn terminal_create(
    cols: u16,
    rows: u16,
    shell_program: *const c_char,
) -> *mut TerminalHandle {
    if shell_program.is_null() {
        return ptr::null_mut();
    }

    let shell = unsafe { CStr::from_ptr(shell_program).to_str().unwrap_or("/bin/zsh") };

    // ⭐ 关键修复: 使用 Rio 的环境变量设置方式
    // 检测 terminfo
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

    // 移除可能干扰的环境变量
    std::env::remove_var("DESKTOP_STARTUP_ID");
    std::env::remove_var("XDG_ACTIVATION_TOKEN");

    // macOS 特定设置
    #[cfg(target_os = "macos")]
    {
        if std::env::var("LC_CTYPE").is_err() {
            std::env::set_var("LC_CTYPE", "UTF-8");
        }
        if std::env::var("LC_ALL").is_err() {
            std::env::set_var("LC_ALL", "en_US.UTF-8");
        }
    }

    // 默认切到用户主目录，避免 shell-init getcwd 错误
    if let Ok(home_dir) = std::env::var("HOME") {
        let _ = std::env::set_current_dir(&home_dir);
    }

    let font_metrics = resolve_font_metrics();
    let (winsize_width, winsize_height, total_width, total_height, square_width, square_height) =
        pixel_dimensions(cols, rows, &font_metrics);

    // 创建 PTY
    let mut pty = match create_pty_with_fork(
        &std::borrow::Cow::Borrowed(shell),
        cols,
        rows,
    ) {
        Ok(pty) => pty,
        Err(_) => return ptr::null_mut(),
    };

    let initial_winsize = WinsizeBuilder {
        cols,
        rows,
        width: winsize_width,
        height: winsize_height,
    };

    let _ = pty.set_winsize(initial_winsize);

    // 创建终端状态（Crosswords）
    let listener = VoidListener;

    // CrosswordsSize 需要所有字段 (u32 类型)
    let dimensions = CrosswordsSize {
        columns: cols as usize,
        screen_lines: rows as usize,
        width: total_width,
        height: total_height,
        square_width,
        square_height,
    };

    // 使用一个dummy WindowId 和 route_id
    let window_id = unsafe { std::mem::zeroed::<WindowId>() };
    let route_id = 0;

    let terminal = Crosswords::new(
        dimensions,
        CursorShape::Block,
        listener,
        window_id,
        route_id,
    );
    let mut terminal = terminal;
    terminal.grid.update_history(DEFAULT_HISTORY_LINES);

    // 创建 ANSI 解析器
    let parser = Processor::default();

    let handle = Box::new(TerminalHandle {
        pty: Arc::new(Mutex::new(pty)),
        terminal: Arc::new(Mutex::new(terminal)),
        parser: Arc::new(Mutex::new(parser)),
        cols,
        rows,
        font_metrics,
        selection: Arc::new(Mutex::new(None)),  // 🎯 初始化选区为空
    });

    Box::into_raw(handle)
}

/// 从 PTY 读取输出（非阻塞）
#[no_mangle]
pub extern "C" fn terminal_read_output(handle: *mut TerminalHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };

    // 读取 PTY 输出
    let mut buf = [0u8; 4096];
    let mut pty = handle.pty.lock();

    // 使用 ProcessReadWrite trait 的 reader() 方法
    match pty.reader().read(&mut buf) {
        Ok(0) => {
            false
        }
        Ok(n) => {
            let data = &buf[..n];

            drop(pty);

            let mut terminal = handle.terminal.lock();
            let mut parser = handle.parser.lock();
            parser.advance(&mut *terminal, data);

            true
        }
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
            false
        }
        Err(e) => {
            eprintln!("[Terminal FFI] Error reading from PTY: {:?}", e);
            false
        }
    }
}

/// 向 PTY 写入数据（键盘输入）
#[no_mangle]
pub extern "C" fn terminal_write_input(
    handle: *mut TerminalHandle,
    data: *const c_char,
) -> bool {
    if handle.is_null() || data.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };
    let input = unsafe { CStr::from_ptr(data).to_bytes() };

    let mut pty = handle.pty.lock();
    match std::io::Write::write_all(pty.writer(), input) {
        Ok(_) => true,
        Err(e) => {
            eprintln!("[Terminal FFI] Error writing to PTY: {:?}", e);
            false
        }
    }
}

/// 获取终端网格中的文本内容（用于渲染）
/// 返回格式化的字符串，每行用换行符分隔
#[no_mangle]
pub extern "C" fn terminal_get_content(
    handle: *mut TerminalHandle,
    buffer: *mut c_char,
    buffer_size: usize,
) -> usize {
    if handle.is_null() || buffer.is_null() || buffer_size == 0 {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let terminal = handle.terminal.lock();

    // 构建内容字符串
    let mut content = String::new();

    // 获取可见区域的内容
    // grid 是公开字段，实现了 Index<Pos> trait
    use rio_backend::crosswords::pos::{Pos, Line, Column};

    // 先找到最后一行有内容的位置
    let mut last_non_empty_row = -1i32;
    for row in 0..handle.rows as i32 {
        for col in 0..handle.cols as usize {
            let pos = Pos {
                row: Line(row),
                col: Column(col),
            };
            let cell = &terminal.grid[pos];
            if cell.c != ' ' && cell.c != '\0' {
                last_non_empty_row = row;
                break;
            }
        }
    }

    // 只渲染到最后一行有内容的位置（至少渲染第一行）
    let max_row = (last_non_empty_row + 1).max(1);

    for row in 0..max_row {
        let mut line = String::new();
        for col in 0..handle.cols as usize {
            let pos = Pos {
                row: Line(row),
                col: Column(col),
            };
            // 使用索引访问 grid (Grid 实现了 Index<Pos>)
            let cell = &terminal.grid[pos];
            line.push(cell.c);
        }
        // 移除行尾空格
        let trimmed = line.trim_end();
        content.push_str(trimmed);
        if row < max_row - 1 {
            content.push('\n');
        }
    }

    // 复制到缓冲区
    let bytes = content.as_bytes();
    let copy_len = bytes.len().min(buffer_size - 1);

    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, copy_len);
        *buffer.add(copy_len) = 0; // null terminator
    }

    copy_len
}

/// 获取光标位置
#[no_mangle]
pub extern "C" fn terminal_get_cursor(
    handle: *mut TerminalHandle,
    out_row: *mut u16,
    out_col: *mut u16,
) -> bool {
    if handle.is_null() || out_row.is_null() || out_col.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };
    let terminal = handle.terminal.lock();
    let cursor = terminal.cursor();

    unsafe {
        // Line 和 Column 是 newtype，访问内部值用 .0
        *out_row = cursor.pos.row.0 as u16;
        *out_col = cursor.pos.col.0 as u16;
    }

    true
}

/// 调整终端大小
#[no_mangle]
pub extern "C" fn terminal_resize(
    handle: *mut TerminalHandle,
    cols: u16,
    rows: u16,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };

    // 调整 PTY 大小
    let mut pty = handle.pty.lock();
    let metrics = handle.font_metrics;
    let (winsize_width, winsize_height, total_width, total_height, square_width, square_height) =
        pixel_dimensions(cols, rows, &metrics);
    let winsize = WinsizeBuilder {
        cols,
        rows,
        width: winsize_width,
        height: winsize_height,
    };

    if let Err(e) = pty.set_winsize(winsize) {
        eprintln!("[Terminal FFI] Failed to resize PTY: {:?}", e);
        return false;
    }

    drop(pty);

    // 调整终端网格大小
    let mut terminal = handle.terminal.lock();
    let new_size = CrosswordsSize {
        columns: cols as usize,
        screen_lines: rows as usize,
        width: total_width,
        height: total_height,
        square_width,
        square_height,
    };
    terminal.resize(new_size);

    handle.cols = cols;
    handle.rows = rows;

    true
}

/// 释放终端
#[no_mangle]
pub extern "C" fn terminal_free(handle: *mut TerminalHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
}
}

/// 将 AnsiColor 转换为 RGB
fn ansi_color_to_rgb(color: &AnsiColor) -> (u8, u8, u8) {
    match color {
        AnsiColor::Named(named) => named_color_to_rgb(*named),
        AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b),
        AnsiColor::Indexed(idx) => indexed_color_to_rgb(*idx),
    }
}

/// 将命名颜色转换为 RGB（使用默认终端配色方案）
fn named_color_to_rgb(color: NamedColor) -> (u8, u8, u8) {
    match color {
        NamedColor::Black => (0, 0, 0),
        NamedColor::Red => (205, 49, 49),
        NamedColor::Green => (13, 188, 121),
        NamedColor::Yellow => (229, 229, 16),
        NamedColor::Blue => (36, 114, 200),
        NamedColor::Magenta => (188, 63, 188),
        NamedColor::Cyan => (17, 168, 205),
        NamedColor::White => (229, 229, 229),
        NamedColor::LightBlack => (102, 102, 102),
        NamedColor::LightRed => (241, 76, 76),
        NamedColor::LightGreen => (35, 209, 139),
        NamedColor::LightYellow => (245, 245, 67),
        NamedColor::LightBlue => (59, 142, 234),
        NamedColor::LightMagenta => (214, 112, 214),
        NamedColor::LightCyan => (41, 184, 219),
        NamedColor::LightWhite => (255, 255, 255),
        NamedColor::Foreground => (229, 229, 229),
        NamedColor::Background => (0, 0, 0),
        _ => (229, 229, 229), // 默认白色
    }
}

/// 将索引颜色转换为 RGB（256 色调色板）
fn indexed_color_to_rgb(idx: u8) -> (u8, u8, u8) {
    match idx {
        // 0-15: 标准 16 色
        0 => (0, 0, 0),
        1 => (205, 49, 49),
        2 => (13, 188, 121),
        3 => (229, 229, 16),
        4 => (36, 114, 200),
        5 => (188, 63, 188),
        6 => (17, 168, 205),
        7 => (229, 229, 229),
        8 => (102, 102, 102),
        9 => (241, 76, 76),
        10 => (35, 209, 139),
        11 => (245, 245, 67),
        12 => (59, 142, 234),
        13 => (214, 112, 214),
        14 => (41, 184, 219),
        15 => (255, 255, 255),

        // 16-231: 216 色立方体
        16..=231 => {
            let idx = idx - 16;
            let r = (idx / 36) % 6;
            let g = (idx / 6) % 6;
            let b = idx % 6;
            let value = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
            (value(r), value(g), value(b))
        }

        // 232-255: 灰度
        232..=255 => {
            let gray = 8 + (idx - 232) * 10;
            (gray, gray, gray)
        }
    }
}

/// 获取历史行数（scrollback buffer 大小）
#[no_mangle]
pub extern "C" fn terminal_get_history_size(handle: *mut TerminalHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let terminal = handle.terminal.lock();
    terminal.history_size()
}

/// 获取指定位置的单元格数据（包含颜色）
/// row 可以是负数，表示历史记录中的行（-1 是历史的最后一行）
#[no_mangle]
pub extern "C" fn terminal_get_cell(
    handle: *mut TerminalHandle,
    row: u16,
    col: u16,
    out_cell: *mut TerminalCell,
) -> bool {
    if handle.is_null() || out_cell.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };

    if row >= handle.rows || col >= handle.cols {
        return false;
    }

    let terminal = handle.terminal.lock();

    use rio_backend::crosswords::pos::{Pos, Line, Column};
    let pos = Pos {
        row: Line(row as i32),
        col: Column(col as usize),
    };

    let cell = &terminal.grid[pos];
    let (fg_r, fg_g, fg_b) = ansi_color_to_rgb(&cell.fg);
    let (bg_r, bg_g, bg_b) = ansi_color_to_rgb(&cell.bg);

    unsafe {
        (*out_cell).c = cell.c as u32;
        (*out_cell).fg_r = fg_r;
        (*out_cell).fg_g = fg_g;
        (*out_cell).fg_b = fg_b;
        (*out_cell).bg_r = bg_r;
        (*out_cell).bg_g = bg_g;
        (*out_cell).bg_b = bg_b;
    }

    true
}

/// 获取指定位置的单元格（支持负数行号访问历史）
#[no_mangle]
pub extern "C" fn terminal_get_cell_with_scroll(
    handle: *mut TerminalHandle,
    row: i32,  // 可以是负数
    col: u16,
    out_cell: *mut TerminalCell,
) -> bool {
    if handle.is_null() || out_cell.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };

    if col >= handle.cols {
        return false;
    }

    let terminal = handle.terminal.lock();

    use rio_backend::crosswords::pos::{Pos, Line, Column};
    let pos = Pos {
        row: Line(row),
        col: Column(col as usize),
    };

    let cell = &terminal.grid[pos];
    let (fg_r, fg_g, fg_b) = ansi_color_to_rgb(&cell.fg);
    let (bg_r, bg_g, bg_b) = ansi_color_to_rgb(&cell.bg);

    unsafe {
        (*out_cell).c = cell.c as u32;
        (*out_cell).fg_r = fg_r;
        (*out_cell).fg_g = fg_g;
        (*out_cell).fg_b = fg_b;
        (*out_cell).bg_r = bg_r;
        (*out_cell).bg_g = bg_g;
        (*out_cell).bg_b = bg_b;
    }

    true
}

/// 滚动终端视图
#[no_mangle]
pub extern "C" fn terminal_scroll(
    handle: *mut TerminalHandle,
    delta_lines: i32,  // 正数向上滚动（查看历史），负数向下滚动
) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };
    let mut terminal = handle.terminal.lock();

    if delta_lines > 0 {
        // 向上滚动（查看历史）
        terminal.scroll_display(Scroll::Delta(delta_lines));
    } else if delta_lines < 0 {
        // 向下滚动（回到底部）
        terminal.scroll_display(Scroll::Delta(delta_lines));
    }

    true
}

/// 渲染终端内容到 Sugarloaf RichText
/// 注意: 此函数只负责填充 RichText 内容,不设置 Objects 和触发渲染
/// Objects 设置和渲染由调用者统一处理
#[no_mangle]
pub extern "C" fn terminal_render_to_sugarloaf(
    handle: *mut TerminalHandle,
    sugarloaf: *mut SugarloafHandle,
    rich_text_id: usize,
) -> bool {
    if handle.is_null() || sugarloaf.is_null() {
        return false;
    }

    let handle_ref = unsafe { &mut *handle };
    let sugarloaf_ref = unsafe { &mut *sugarloaf };
    let terminal = handle_ref.terminal.lock();

    let rows = terminal.visible_rows();
    let _debug_overlay = false;
    let cursor = terminal.cursor();
    let cursor_row = cursor.pos.row.0 as usize;
    let cursor_col = cursor.pos.col.0 as usize;

    // 🔍 调试日志：诊断光标位置问题
    use rio_backend::crosswords::Mode;
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    let ms = ts.as_millis() % 100000; // 只显示后5位毫秒
    let is_alt_screen = terminal.mode().contains(Mode::ALT_SCREEN);
    let display_offset = terminal.display_offset();
    // 使用 handle 指针地址作为 terminal_id 来区分不同终端
    let terminal_id = handle as usize;
    println!(
        "[CURSOR DEBUG] cursor=({},{}) @{}ms",
        cursor_row, cursor_col, ms
    );

    // 🎯 获取选区范围（用于高亮）
    let selection_range = handle_ref.selection.lock().clone();

    // 🔍 调试日志：渲染时的选区状态（只在有选区时打印一次）
    if let Some(ref range) = selection_range {
        println!(
            "🎨 [RENDER SELECTION] terminal={:x} selection=({},{}) -> ({},{}) terminal_size={}x{}",
            terminal_id,
            range.start_row, range.start_col,
            range.end_row, range.end_col,
            handle_ref.cols, handle_ref.rows
        );
    }

    // 获取 content builder - 使用链式调用
    let content = sugarloaf_ref.instance.content();
    content.sel(rich_text_id).clear();

    use sugarloaf::{FragmentStyle, SugarCursor};

    // 🎯 使用终端的实际列数，而不是 grid 行的长度
    let terminal_cols = handle_ref.cols as usize;
    let terminal_rows = handle_ref.rows as usize;

    // 渲染所有可见行（限制为 terminal_rows）
    for (row_idx, row) in rows.iter().enumerate().take(terminal_rows) {
        // 🎯 关键修复：第一行之后才调用 new_line()
        if row_idx > 0 {
            content.new_line();
        }

        // 🎯 使用 terminal_cols 限制渲染列数，而不是 row.len()
        let cols = row.len().min(terminal_cols);
        // 🎯 关键：row_idx 是可见行的索引（0, 1, 2...）
        // 对于选区判断，我们使用相对于可见区域的行号
        let row_num = row_idx as i32;

        // 跟踪当前颜色和选区状态，以便批量渲染相同样式的字符
        let mut current_line = String::new();
        // (fg_color, glyph_width, is_selected, is_cursor)
        let mut current_style: Option<((u8, u8, u8), f32, bool, bool)> = None;

        for col in 0..cols {
            let cell = &row.inner[col];

            use rio_backend::crosswords::square::Flags;
            if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
                continue;
            }

            let fg_color = ansi_color_to_rgb(&cell.fg);
            let glyph_width = if cell.flags.contains(Flags::WIDE_CHAR) {
                2.0
            } else {
                1.0
            };

            // 🎯 检查当前 cell 是否在选区内
            // row_num 是相对于可见区域的行号（从 0 开始）
            let is_selected = selection_range
                .as_ref()
                .map(|range| range.contains(col as u16, row_num))
                .unwrap_or(false);

            // 🎯 检查当前位置是否是光标位置
            let is_cursor = row_idx == cursor_row && col == cursor_col;

            // 🎯 关键修复：在添加当前字符前,检查样式是否改变
            // 如果改变了,先 flush 之前累积的文本
            let style_changed = if let Some((prev_fg, prev_width, prev_selected, prev_cursor)) = current_style {
                prev_fg != fg_color
                    || (prev_width - glyph_width).abs() > f32::EPSILON
                    || prev_selected != is_selected  // 选区状态改变
                    || prev_cursor != is_cursor      // 光标状态改变
            } else {
                false
            };

            if style_changed && !current_line.is_empty() {
                // Flush 之前的文本（使用之前的样式）
                if let Some((prev_fg, prev_width, prev_selected, prev_cursor)) = current_style {
                    let (r, g, b) = prev_fg;
                    let mut style = FragmentStyle {
                        color: [
                            r as f32 / 255.0,
                            g as f32 / 255.0,
                            b as f32 / 255.0,
                            1.0,
                        ],
                        width: prev_width,
                        ..FragmentStyle::default()
                    };

                    // 🎨 应用选区高亮
                    if prev_selected {
                        style.background_color = Some([0.3, 0.5, 0.8, 0.6]);  // 蓝色半透明背景
                    }

                    // 🎯 应用光标样式
                    if prev_cursor {
                        style.cursor = Some(SugarCursor::Block([1.0, 1.0, 1.0, 1.0])); // 白色方块光标
                    }

                    content.add_text(&current_line, style);
                    current_line.clear();
                }
            }

            current_line.push(cell.c);
            current_style = Some((fg_color, glyph_width, is_selected, is_cursor));  // 🎯 保存选区和光标状态
        }

        if !current_line.is_empty() {
            if let Some(((r, g, b), width, is_selected, is_cursor)) = current_style {
                let mut style = FragmentStyle {
                    color: [
                        r as f32 / 255.0,
                        g as f32 / 255.0,
                        b as f32 / 255.0,
                        1.0,
                    ],
                    width,
                    ..FragmentStyle::default()
                };

                // 🎨 应用选区高亮
                if is_selected {
                    style.background_color = Some([0.3, 0.5, 0.8, 0.6]);  // 蓝色半透明背景
                }

                // 🎯 应用光标样式
                if is_cursor {
                    style.cursor = Some(SugarCursor::Block([1.0, 1.0, 1.0, 1.0])); // 白色方块光标
                }

                content.add_text(&current_line, style);
            }
        } else {
            let style = FragmentStyle::default();
            content.add_text(" ", style);
        }

    }

    // 构建内容(不调用 set_objects 和 render,由调用者处理)
    content.build();

    true
}

// ============================================================================
// Tab Manager - 多终端会话管理
// ============================================================================

use std::collections::HashMap;
use crate::context_grid::{ContextGrid, Delta};

/// Tab 信息（现在包含 ContextGrid 以支持 Split）
pub struct TabInfo {
    grid: ContextGrid,  // Split 布局管理
    title: String,
}

/// 渲染回调函数类型
pub type RenderCallback = extern "C" fn(*mut c_void);

/// Tab 管理器
pub struct TabManager {
    tabs: HashMap<usize, TabInfo>,
    active_tab_id: Option<usize>,
    next_tab_id: usize,
    sugarloaf_handle: *mut SugarloafHandle,
    cols: u16,
    rows: u16,
    shell: String,
    // 渲染回调
    render_callback: Option<RenderCallback>,
    callback_context: *mut c_void,
}

impl TabManager {
    fn new(
        sugarloaf_handle: *mut SugarloafHandle,
        cols: u16,
        rows: u16,
        shell: String,
    ) -> Self {
        Self {
            tabs: HashMap::new(),
            active_tab_id: None,
            next_tab_id: 1,
            sugarloaf_handle,
            cols,
            rows,
            shell,
            render_callback: None,
            callback_context: ptr::null_mut(),
        }
    }

    /// 设置渲染回调函数
    fn set_render_callback(&mut self, callback: RenderCallback, context: *mut c_void) {
        self.render_callback = Some(callback);
        self.callback_context = context;
    }

    fn create_tab(&mut self) -> Option<usize> {
        if self.sugarloaf_handle.is_null() {
            return None;
        }

        let tab_id = self.next_tab_id;
        self.next_tab_id += 1;

        // 创建终端
        let shell_cstr = std::ffi::CString::new(self.shell.as_str()).ok()?;
        let terminal_ptr = terminal_create(self.cols, self.rows, shell_cstr.as_ptr());
        if terminal_ptr.is_null() {
            return None;
        }

        let terminal = unsafe { Box::from_raw(terminal_ptr) };

        // 创建 RichText
        let rich_text_id = crate::sugarloaf_create_rich_text(self.sugarloaf_handle);

        // 计算初始尺寸（基于 cols 和 rows）
        // 注意：fallback 使用 scaled_font_size=28 (font_size=14 × scale=2.0)
        let font_metrics = crate::global_font_metrics().unwrap_or_else(|| {
            crate::SugarloafFontMetrics::fallback(28.0)
        });

        let width = (self.cols as f32) * font_metrics.cell_width;
        let height = (self.rows as f32) * font_metrics.line_height;

        // 创建 ContextGrid（初始只有一个 pane）
        let initial_pane_id = 1;
        let margin = Delta { x: 0.0, top_y: 0.0, bottom_y: 0.0 };
        let border_color = [0.3, 0.3, 0.3, 1.0];  // 灰色边框
        let scale = 2.0;  // TODO: 从 window scale 获取

        let grid = ContextGrid::new(
            initial_pane_id,
            terminal,
            rich_text_id,
            width,
            height,
            scale,
            margin,
            border_color,
            self.cols,
            self.rows,
        );

        let tab_info = TabInfo {
            grid,
            title: format!("Tab {}", tab_id),
        };

        self.tabs.insert(tab_id, tab_info);

        // 如果是第一个 tab，自动激活
        if self.active_tab_id.is_none() {
            self.active_tab_id = Some(tab_id);
        }

        Some(tab_id)
    }

    fn switch_tab(&mut self, tab_id: usize) -> bool {
        if self.tabs.contains_key(&tab_id) {
            self.active_tab_id = Some(tab_id);
            true
        } else {
            false
        }
    }

    fn close_tab(&mut self, tab_id: usize) -> bool {
        if let Some(_tab) = self.tabs.remove(&tab_id) {
            // tab 会自动 drop，释放资源

            // 如果关闭的是当前激活的 tab，切换到第一个可用的 tab
            if self.active_tab_id == Some(tab_id) {
                self.active_tab_id = self.tabs.keys().next().copied();
            }

            true
        } else {
            false
        }
    }

    fn get_active_tab(&self) -> Option<usize> {
        self.active_tab_id
    }

    fn get_active_tab_mut(&mut self) -> Option<&mut TabInfo> {
        if let Some(tab_id) = self.active_tab_id {
            self.tabs.get_mut(&tab_id)
        } else {
            None
        }
    }

    fn read_all_tabs(&mut self) -> bool {
        let mut has_updates = false;
        for tab_info in self.tabs.values_mut() {
            // 读取该 Tab 中所有 pane 的输出
            for pane in tab_info.grid.get_all_panes_mut() {
                let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
                if terminal_read_output(terminal_ptr) {
                    has_updates = true;
                }
            }
        }

        // 如果有更新,调用渲染回调通知 Swift
        if has_updates {
            if let Some(callback) = self.render_callback {
                callback(self.callback_context);
            }
        }

        has_updates
    }

    fn render_active_tab(&mut self) -> bool {
        // 先获取 sugarloaf_handle，避免借用冲突
        let sugarloaf_handle = self.sugarloaf_handle;

        if let Some(tab_info) = self.get_active_tab_mut() {
            // 渲染该 Tab 的所有 panes
            for (_i, pane) in tab_info.grid.get_all_panes_mut().enumerate() {
                let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
                terminal_render_to_sugarloaf(
                    terminal_ptr,
                    sugarloaf_handle,
                    pane.rich_text_id,
                );
            }

            // 设置所有 pane 的 RichText Objects 到 Sugarloaf
            let objects = tab_info.grid.objects();
            unsafe {
                if let Some(sugarloaf) = sugarloaf_handle.as_mut() {
                    sugarloaf.set_objects(objects);
                    // 🎯 关键修复：调用 render() 触发实际的 GPU 渲染
                    sugarloaf.render();
                }
            }

            true
        } else {
            false
        }
    }

    fn write_input_to_active(&mut self, data: &[u8]) -> bool {
        if let Some(tab_info) = self.get_active_tab_mut() {
            // 写入到当前激活的 pane
            if let Some(pane) = tab_info.grid.get_current_mut() {
                let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
                let cstring = match std::ffi::CString::new(data) {
                    Ok(s) => s,
                    Err(_) => return false,
                };
                terminal_write_input(terminal_ptr, cstring.as_ptr())
            } else {
                false
            }
        } else {
            false
        }
    }

    fn scroll_active_tab(&mut self, delta_lines: i32) -> bool {
        if let Some(tab_info) = self.get_active_tab_mut() {
            // 滚动当前激活的 pane
            if let Some(pane) = tab_info.grid.get_current_mut() {
                let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
                terminal_scroll(terminal_ptr, delta_lines)
            } else {
                false
            }
        } else {
            false
        }
    }

    fn resize_all_tabs(&mut self, cols: u16, rows: u16) -> bool {
        self.cols = cols;
        self.rows = rows;

        let mut all_success = true;
        for tab_info in self.tabs.values_mut() {
            // Resize 所有 panes
            for pane in tab_info.grid.get_all_panes_mut() {
                let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
                if !terminal_resize(terminal_ptr, cols, rows) {
                    all_success = false;
                }
            }

            // ❌ 删除：不再调用 resize（Swift 负责布局）
            // let font_metrics = crate::global_font_metrics().unwrap_or_else(|| {
            //     crate::SugarloafFontMetrics::fallback(14.0)
            // });
            // let width = (cols as f32) * font_metrics.cell_width;
            // let height = (rows as f32) * font_metrics.line_height;
            // tab_info.grid.resize(width, height);
        }
        all_success
    }

    fn get_tab_list(&self) -> Vec<(usize, String)> {
        self.tabs
            .iter()
            .map(|(id, info)| (*id, info.title.clone()))
            .collect()
    }

    fn set_tab_title(&mut self, tab_id: usize, title: String) -> bool {
        if let Some(tab_info) = self.tabs.get_mut(&tab_id) {
            tab_info.title = title;
            true
        } else {
            false
        }
    }

    /// 切换激活的 pane
    fn set_active_pane(&mut self, pane_id: usize) -> bool {
        if let Some(tab_info) = self.get_active_tab_mut() {
            tab_info.grid.set_current(pane_id)
        } else {
            false
        }
    }

    /// 获取当前 Tab 的 pane 数量
    fn get_pane_count(&self) -> usize {
        if let Some(tab_id) = self.active_tab_id {
            if let Some(tab_info) = self.tabs.get(&tab_id) {
                return tab_info.grid.len();
            }
        }
        0
    }

    /// 🧪 测试函数：在四个角创建测试 pane
    /// 用于验证坐标系和渲染位置
    pub fn test_corner_panes(&mut self, container_width: f32, container_height: f32) {
        eprintln!("[TabManager] 🧪 Testing corner panes: container {}x{}", container_width, container_height);

        // 定义四个角的位置（物理像素，Rust 坐标系）
        let corners = [
            (100, 0.0, 0.0, "TL"),           // 左上角
            (101, container_width - 100.0, 0.0, "TR"),  // 右上角
            (102, 0.0, container_height - 100.0, "BL"), // 左下角
            (103, container_width - 100.0, container_height - 100.0, "BR"), // 右下角
        ];

        let sugarloaf_handle = self.sugarloaf_handle;

        for (pane_id, x, y, label) in corners.iter() {
            eprintln!("[TabManager] Creating test pane {} at ({}, {}) - {}", pane_id, x, y, label);

            // 创建终端
            let shell_cstr = std::ffi::CString::new("/bin/zsh").unwrap();
            let terminal_ptr = crate::terminal_create(10, 3, shell_cstr.as_ptr());
            if terminal_ptr.is_null() {
                eprintln!("[TabManager] ❌ Failed to create terminal for test pane {}", pane_id);
                continue;
            }
            let terminal = unsafe { Box::from_raw(terminal_ptr) };

            // 写入标记文本
            let marker = format!("[[{}]]\n", label);
            crate::terminal_write_input(terminal_ptr, marker.as_ptr() as *const i8);

            // 创建 RichText
            let rich_text_id = crate::sugarloaf_create_rich_text(sugarloaf_handle);

            // 添加 pane
            if let Some(tab_info) = self.get_active_tab_mut() {
                tab_info.grid.add_pane(*pane_id, terminal, rich_text_id, 10, 3);
                tab_info.grid.set_pane_position(*pane_id, *x, *y);
            }
        }

        eprintln!("[TabManager] 🧪 Test panes created successfully");
    }

    /// 更新 Panel 的渲染配置（由 Swift 调用）
    /// Swift 负责布局计算，Rust 只负责接收位置和尺寸
    pub fn update_panel_config(
        &mut self,
        panel_id: usize,
        x: f32,           // Swift 传来的位置（物理像素，Rust 坐标系）
        y: f32,
        _width: f32,      // 暂时不使用 width/height（通过 cols/rows 计算）
        _height: f32,
        cols: u16,
        rows: u16,
    ) -> bool {
        // 先检查是否需要创建 pane
        let needs_creation = if let Some(tab_id) = self.active_tab_id {
            if let Some(tab_info) = self.tabs.get(&tab_id) {
                !tab_info.grid.has_pane(panel_id)
            } else {
                return false;
            }
        } else {
            return false;
        };

        // 如果需要创建，先创建终端和 RichText
        if needs_creation {
            // 创建新终端
            let shell_cstr = std::ffi::CString::new(self.shell.as_str()).unwrap();
            let terminal_ptr = crate::terminal_create(cols, rows, shell_cstr.as_ptr());
            if terminal_ptr.is_null() {
                return false;
            }
            let terminal = unsafe { Box::from_raw(terminal_ptr) };

            // 创建 RichText
            let rich_text_id = crate::sugarloaf_create_rich_text(self.sugarloaf_handle);

            // 添加到 ContextGrid
            if let Some(tab_info) = self.get_active_tab_mut() {
                tab_info.grid.add_pane(panel_id, terminal, rich_text_id, cols, rows);
            }
        }

        // 设置位置和尺寸
        if let Some(tab_info) = self.get_active_tab_mut() {
            tab_info.grid.set_pane_position(panel_id, x, y);
            tab_info.grid.set_pane_size(panel_id, cols, rows);
            true
        } else {
            false
        }
    }
}

// ============================================================================
// Tab Manager FFI
// ============================================================================

/// 创建 Tab 管理器
#[no_mangle]
pub extern "C" fn tab_manager_new(
    sugarloaf: *mut SugarloafHandle,
    cols: u16,
    rows: u16,
    shell_program: *const c_char,
) -> *mut TabManager {
    if sugarloaf.is_null() || shell_program.is_null() {
        return ptr::null_mut();
    }

    let shell = unsafe {
        CStr::from_ptr(shell_program)
            .to_str()
            .unwrap_or("/bin/zsh")
            .to_string()
    };

    let manager = Box::new(TabManager::new(sugarloaf, cols, rows, shell));
    Box::into_raw(manager)
}

/// 设置渲染回调
#[no_mangle]
pub extern "C" fn tab_manager_set_render_callback(
    manager: *mut TabManager,
    callback: RenderCallback,
    context: *mut c_void,
) {
    if manager.is_null() {
        return;
    }

    let manager = unsafe { &mut *manager };
    manager.set_render_callback(callback, context);
}

/// 创建新 Tab
#[no_mangle]
pub extern "C" fn tab_manager_create_tab(manager: *mut TabManager) -> i32 {
    if manager.is_null() {
        return -1;
    }

    let manager = unsafe { &mut *manager };
    manager.create_tab().map(|id| id as i32).unwrap_or(-1)
}

/// 切换到指定 Tab
#[no_mangle]
pub extern "C" fn tab_manager_switch_tab(manager: *mut TabManager, tab_id: usize) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.switch_tab(tab_id)
}

/// 关闭指定 Tab
#[no_mangle]
pub extern "C" fn tab_manager_close_tab(manager: *mut TabManager, tab_id: usize) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.close_tab(tab_id)
}

/// 获取当前激活的 Tab ID
#[no_mangle]
pub extern "C" fn tab_manager_get_active_tab(manager: *mut TabManager) -> i32 {
    if manager.is_null() {
        return -1;
    }

    let manager = unsafe { &mut *manager };
    manager.get_active_tab().map(|id| id as i32).unwrap_or(-1)
}

/// 读取所有 Tab 的输出（更新所有终端状态）
#[no_mangle]
pub extern "C" fn tab_manager_read_all_tabs(manager: *mut TabManager) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.read_all_tabs()
}

/// 渲染当前激活的 Tab
#[no_mangle]
pub extern "C" fn tab_manager_render_active_tab(manager: *mut TabManager) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.render_active_tab()
}

/// 向当前激活的 Tab 写入输入
#[no_mangle]
pub extern "C" fn tab_manager_write_input(
    manager: *mut TabManager,
    data: *const c_char,
) -> bool {
    if manager.is_null() || data.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    let input = unsafe { CStr::from_ptr(data).to_bytes() };
    manager.write_input_to_active(input)
}

/// 滚动当前激活的 Tab
#[no_mangle]
pub extern "C" fn tab_manager_scroll_active_tab(
    manager: *mut TabManager,
    delta_lines: i32,
) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.scroll_active_tab(delta_lines)
}

/// 滚动指定 pane（不改变焦点）- 用于鼠标位置滚动
#[no_mangle]
pub extern "C" fn tab_manager_scroll_pane(
    manager: *mut TabManager,
    pane_id: usize,
    delta_lines: i32,
) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    if let Some(tab_info) = manager.get_active_tab_mut() {
        // 直接操作指定 pane，不通过 grid.current
        if let Some(pane) = tab_info.grid.get_mut(pane_id) {
            let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
            terminal_scroll(terminal_ptr, delta_lines)
        } else {
            false
        }
    } else {
        false
    }
}

/// 调整所有 Tab 的大小
#[no_mangle]
pub extern "C" fn tab_manager_resize_all_tabs(
    manager: *mut TabManager,
    cols: u16,
    rows: u16,
) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.resize_all_tabs(cols, rows)
}

/// 获取 Tab 数量
#[no_mangle]
pub extern "C" fn tab_manager_get_tab_count(manager: *mut TabManager) -> usize {
    if manager.is_null() {
        return 0;
    }

    let manager = unsafe { &*manager };
    manager.tabs.len()
}

/// 获取所有 Tab ID（需要传入足够大的数组）
#[no_mangle]
pub extern "C" fn tab_manager_get_tab_ids(
    manager: *mut TabManager,
    out_ids: *mut usize,
    max_count: usize,
) -> usize {
    if manager.is_null() || out_ids.is_null() {
        return 0;
    }

    let manager = unsafe { &*manager };
    let tab_list = manager.get_tab_list();
    let count = tab_list.len().min(max_count);

    for (i, (id, _title)) in tab_list.iter().take(count).enumerate() {
        unsafe {
            *out_ids.add(i) = *id;
        }
    }

    count
}

/// 设置 Tab 标题
#[no_mangle]
pub extern "C" fn tab_manager_set_tab_title(
    manager: *mut TabManager,
    tab_id: usize,
    title: *const c_char,
) -> bool {
    if manager.is_null() || title.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    let title_str = unsafe {
        CStr::from_ptr(title)
            .to_str()
            .unwrap_or("Untitled")
            .to_string()
    };

    manager.set_tab_title(tab_id, title_str)
}

/// 获取 Tab 标题（需要传入足够大的缓冲区）
#[no_mangle]
pub extern "C" fn tab_manager_get_tab_title(
    manager: *mut TabManager,
    tab_id: usize,
    buffer: *mut c_char,
    buffer_size: usize,
) -> bool {
    if manager.is_null() || buffer.is_null() || buffer_size == 0 {
        return false;
    }

    let manager = unsafe { &*manager };
    if let Some(tab_info) = manager.tabs.get(&tab_id) {
        let title_bytes = tab_info.title.as_bytes();
        let copy_len = title_bytes.len().min(buffer_size - 1);

        unsafe {
            ptr::copy_nonoverlapping(title_bytes.as_ptr(), buffer as *mut u8, copy_len);
            *buffer.add(copy_len) = 0; // null terminator
        }

        true
    } else {
        false
    }
}

/// 释放 Tab 管理器
#[no_mangle]
pub extern "C" fn tab_manager_free(manager: *mut TabManager) {
    if !manager.is_null() {
        unsafe {
            let _ = Box::from_raw(manager);
        }
    }
}

/// 切换激活的 pane
#[no_mangle]
pub extern "C" fn tab_manager_set_active_pane(manager: *mut TabManager, pane_id: usize) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };
    manager.set_active_pane(pane_id)
}

/// 获取当前 Tab 的 pane 数量
#[no_mangle]
pub extern "C" fn tab_manager_get_pane_count(manager: *mut TabManager) -> usize {
    if manager.is_null() {
        return 0;
    }

    let manager = unsafe { &*manager };
    manager.get_pane_count()
}

// ============================================================================
// Text Selection API
// ============================================================================

/// Selection type (matching C enum)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub enum SelectionTypeFFI {
    Simple = 0,
    Semantic = 1,
    Lines = 2,
}

/// Start text selection in the active pane
#[no_mangle]
pub extern "C" fn tab_manager_start_selection(
    manager: *mut TabManager,
    col: u16,
    row: u16,
    selection_type: SelectionTypeFFI,
) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };

    if let Some(tab_info) = manager.get_active_tab_mut() {
        if let Some(pane) = tab_info.grid.get_current_mut() {
            let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
            return terminal_start_selection(terminal_ptr, col, row, selection_type);
        }
    }
    false
}

/// Update selection end point in the active pane
#[no_mangle]
pub extern "C" fn tab_manager_update_selection(
    manager: *mut TabManager,
    col: u16,
    row: u16,
) -> bool {
    if manager.is_null() {
        return false;
    }

    let manager = unsafe { &mut *manager };

    if let Some(tab_info) = manager.get_active_tab_mut() {
        if let Some(pane) = tab_info.grid.get_current_mut() {
            let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
            return terminal_update_selection(terminal_ptr, col, row);
        }
    }
    false
}

/// Clear selection in the active pane
#[no_mangle]
pub extern "C" fn tab_manager_clear_selection(manager: *mut TabManager) {
    if manager.is_null() {
        return;
    }

    let manager = unsafe { &mut *manager };

    if let Some(tab_info) = manager.get_active_tab_mut() {
        if let Some(pane) = tab_info.grid.get_current_mut() {
            let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
            terminal_clear_selection(terminal_ptr);
        }
    }
}

/// Get selected text from the active pane
#[no_mangle]
pub extern "C" fn tab_manager_get_selected_text(
    manager: *mut TabManager,
    buffer: *mut c_char,
    buffer_size: usize,
) -> usize {
    if manager.is_null() || buffer.is_null() || buffer_size == 0 {
        return 0;
    }

    let manager = unsafe { &mut *manager };

    if let Some(tab_info) = manager.get_active_tab_mut() {
        if let Some(pane) = tab_info.grid.get_current_mut() {
            let terminal_ptr = &mut *pane.terminal as *mut TerminalHandle;
            return terminal_get_selected_text(terminal_ptr, buffer, buffer_size);
        }
    }
    0
}

// ============================================================================
// Terminal-level Selection Functions
// ============================================================================

/// Start text selection in a terminal
#[no_mangle]
pub extern "C" fn terminal_start_selection(
    handle: *mut TerminalHandle,
    col: u16,
    row: u16,
    _selection_type: SelectionTypeFFI,  // 暂时不使用，未来可以实现 Semantic/Lines 模式
) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };

    // 创建新的选区（起点和终点相同）
    let range = SelectionRange {
        start_col: col,
        start_row: row,
        end_col: col,
        end_row: row,
    };

    *handle.selection.lock() = Some(range);

    true
}

/// Update selection end point
#[no_mangle]
pub extern "C" fn terminal_update_selection(
    handle: *mut TerminalHandle,
    col: u16,
    row: u16,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &mut *handle };
    let mut selection_lock = handle.selection.lock();

    if let Some(ref mut range) = *selection_lock {
        // 更新终点
        range.end_col = col;
        range.end_row = row;
        true
    } else {
        false
    }
}

/// Clear selection
#[no_mangle]
pub extern "C" fn terminal_clear_selection(handle: *mut TerminalHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    *handle.selection.lock() = None;
}

/// Get selected text
#[no_mangle]
pub extern "C" fn terminal_get_selected_text(
    handle: *mut TerminalHandle,
    buffer: *mut c_char,
    buffer_size: usize,
) -> usize {
    if handle.is_null() || buffer.is_null() || buffer_size == 0 {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let selection_lock = handle.selection.lock();
    let terminal = handle.terminal.lock();

    if let Some(range) = *selection_lock {
        // 归一化起点和终点
        let (start_row, start_col, end_row, end_col) = if range.start_row < range.end_row
            || (range.start_row == range.end_row && range.start_col <= range.end_col)
        {
            (range.start_row, range.start_col, range.end_row, range.end_col)
        } else {
            (range.end_row, range.end_col, range.start_row, range.start_col)
        };

        // 提取文本
        let mut text = String::new();
        use rio_backend::crosswords::pos::{Pos, Line, Column};

        for row in start_row..=end_row {
            let line_start_col = if row == start_row { start_col } else { 0 };
            let line_end_col = if row == end_row { end_col } else { handle.cols - 1 };

            for col in line_start_col..=line_end_col {
                let pos = Pos {
                    row: Line(row as i32),
                    col: Column(col as usize),
                };
                let cell = &terminal.grid[pos];
                text.push(cell.c);
            }

            if row < end_row {
                text.push('\n');
            }
        }

        let bytes = text.trim_end().as_bytes();
        let copy_len = bytes.len().min(buffer_size - 1);

        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, copy_len);
            *buffer.add(copy_len) = 0; // null terminator
        }

        return copy_len;
    }

    0
}

// ============================================================================
// 光标上下文 FFI 接口（Cursor Context API）
// ============================================================================

/// 获取指定范围的文本（支持多行、UTF-8、emoji）
/// 用于获取选中范围的文本内容
#[no_mangle]
pub extern "C" fn terminal_get_text_range(
    handle: *mut TerminalHandle,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    out_buffer: *mut c_char,
    buffer_size: usize,
) -> i32 {
    if handle.is_null() || out_buffer.is_null() || buffer_size == 0 {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let terminal = handle.terminal.lock();

    // 归一化起点和终点（确保 start <= end）
    let (start_row, start_col, end_row, end_col) = if start_row < end_row
        || (start_row == end_row && start_col <= end_col)
    {
        (start_row, start_col, end_row, end_col)
    } else {
        (end_row, end_col, start_row, start_col)
    };

    // 提取文本
    let mut text = String::new();
    use rio_backend::crosswords::pos::{Pos, Line, Column};

    for row in start_row..=end_row {
        let line_start_col = if row == start_row { start_col } else { 0 };
        let line_end_col = if row == end_row { end_col } else { handle.cols - 1 };

        for col in line_start_col..=line_end_col {
            let pos = Pos {
                row: Line(row as i32),
                col: Column(col as usize),
            };
            let cell = &terminal.grid[pos];
            text.push(cell.c);
        }

        if row < end_row {
            text.push('\n');
        }
    }

    let bytes = text.trim_end().as_bytes();
    let copy_len = bytes.len().min(buffer_size - 1);

    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), out_buffer as *mut u8, copy_len);
        *out_buffer.add(copy_len) = 0; // null terminator
    }

    1
}

/// 直接删除指定范围的文本（仅对当前输入行有效）
/// 用于"选中在输入行时，输入替换选中"的功能
#[no_mangle]
pub extern "C" fn terminal_delete_range(
    handle: *mut TerminalHandle,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
) -> i32 {
    if handle.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let terminal = handle.terminal.lock();

    // 获取当前光标行（假定是输入行）
    let cursor = terminal.cursor();
    let cursor_row = cursor.pos.row.0 as u16;

    // 归一化起点和终点
    let (start_row, start_col, end_row, end_col) = if start_row < end_row
        || (start_row == end_row && start_col <= end_col)
    {
        (start_row, start_col, end_row, end_col)
    } else {
        (end_row, end_col, start_row, start_col)
    };

    // 只允许删除当前输入行（安全检查）
    if start_row != cursor_row || end_row != cursor_row {
        eprintln!("[Terminal FFI] delete_range: 只能删除当前输入行 (cursor_row={})", cursor_row);
        return 0;
    }

    // 计算需要删除的字符数
    let delete_count = (end_col - start_col + 1) as usize;

    // 通过发送退格键来删除（简化实现）
    // TODO: 更优雅的方式是直接操作 grid，但需要深入 Rio 的 API
    drop(terminal); // 释放锁，避免死锁

    let backspace = b"\x7f"; // ASCII DEL
    let mut pty = handle.pty.lock();
    for _ in 0..delete_count {
        if std::io::Write::write_all(pty.writer(), backspace).is_err() {
            return 0;
        }
    }

    1
}

/// 获取当前输入行号
/// 返回 1 并填充 out_row，如果当前在输入模式
/// 返回 0 如果不在输入模式（如 vim/less）
#[no_mangle]
pub extern "C" fn terminal_get_input_row(
    handle: *mut TerminalHandle,
    out_row: *mut u16,
) -> i32 {
    if handle.is_null() || out_row.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let terminal = handle.terminal.lock();

    // 获取当前光标行（假定光标所在行即为输入行）
    let cursor = terminal.cursor();
    let cursor_row = cursor.pos.row.0;

    unsafe {
        *out_row = cursor_row as u16;
    }

    1
}

/// 设置选中范围（用于高亮渲染）
/// Swift 调用此函数告诉 Rust 当前的选中范围，Rust 负责渲染高亮背景
#[no_mangle]
pub extern "C" fn terminal_set_selection(
    handle: *mut TerminalHandle,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
) -> i32 {
    if handle.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };

    let range = SelectionRange {
        start_row,
        start_col,
        end_row,
        end_col,
    };

    // 🔍 调试日志：选区设置
    println!(
        "🎯 [SELECTION SET] start=({},{}) end=({},{})",
        start_row, start_col, end_row, end_col
    );

    *handle.selection.lock() = Some(range);

    1
}

/// 清除选中高亮
#[no_mangle]
pub extern "C" fn terminal_clear_selection_highlight(handle: *mut TerminalHandle) -> i32 {
    if handle.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    *handle.selection.lock() = None;

    1
}

// =============================================================================
// 新架构：TerminalPool - 简化的终端池
// =============================================================================

/// 终端池 - 只管理终端实例，不关心 Page/Panel/Tab 布局
pub struct TerminalPool {
    terminals: HashMap<usize, TerminalInfo>,
    next_id: usize,
    sugarloaf_handle: *mut SugarloafHandle,
    render_callback: Option<RenderCallback>,
    callback_context: *mut c_void,
    pending_objects: Vec<sugarloaf::Object>,  // 累积待提交的 objects
}

/// 单个终端的信息
struct TerminalInfo {
    terminal: Box<TerminalHandle>,
    rich_text_id: usize,
    rich_text_object: sugarloaf::Object,  // 用于设置渲染位置
}

impl TerminalPool {
    /// 创建新的终端池
    fn new(sugarloaf_handle: *mut SugarloafHandle) -> Self {
        Self {
            terminals: HashMap::new(),
            next_id: 1,
            sugarloaf_handle,
            render_callback: None,
            callback_context: ptr::null_mut(),
            pending_objects: Vec::new(),  // 初始化 pending_objects
        }
    }

    /// 设置渲染回调
    fn set_render_callback(&mut self, callback: RenderCallback, context: *mut c_void) {
        self.render_callback = Some(callback);
        self.callback_context = context;
    }

    /// 创建新终端
    fn create_terminal(&mut self, cols: u16, rows: u16, shell: &str) -> Option<usize> {
        if self.sugarloaf_handle.is_null() {
            return None;
        }

        let terminal_id = self.next_id;
        self.next_id += 1;

        // 创建终端
        let shell_cstr = std::ffi::CString::new(shell).ok()?;
        let terminal_ptr = terminal_create(cols, rows, shell_cstr.as_ptr());
        if terminal_ptr.is_null() {
            return None;
        }

        let terminal = unsafe { Box::from_raw(terminal_ptr) };

        // 创建 RichText
        let rich_text_id = crate::sugarloaf_create_rich_text(self.sugarloaf_handle);

        // 创建 RichText Object（初始位置为 [0, 0]）
        let rich_text_object = sugarloaf::Object::RichText(sugarloaf::RichText {
            id: rich_text_id,
            position: [0.0, 0.0],
            lines: None,
        });

        let info = TerminalInfo {
            terminal,
            rich_text_id,
            rich_text_object,
        };

        self.terminals.insert(terminal_id, info);

        Some(terminal_id)
    }

    /// 关闭终端
    fn close_terminal(&mut self, terminal_id: usize) -> bool {
        self.terminals.remove(&terminal_id).is_some()
    }

    /// 读取所有终端的 PTY 输出
    fn read_all(&mut self) -> bool {
        let mut has_updates = false;
        for info in self.terminals.values_mut() {
            let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
            if unsafe { terminal_read_output(terminal_ptr) } {
                has_updates = true;
            }
        }

        // 如果有更新，触发渲染回调
        if has_updates {
            if let Some(callback) = self.render_callback {
                callback(self.callback_context);
            }
        }

        has_updates
    }

    /// 渲染指定终端到指定位置
    fn render(
        &mut self,
        terminal_id: usize,
        x: f32,
        y: f32,
        width: f32,
        _height: f32,
        cols: u16,
        rows: u16,
    ) -> bool {
        if self.sugarloaf_handle.is_null() {
            return false;
        }

        let info = match self.terminals.get_mut(&terminal_id) {
            Some(info) => info,
            None => return false,
        };

        // 调整终端尺寸（如果需要）
        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe { terminal_resize(terminal_ptr, cols, rows) };

        // 渲染到 RichText
        if !unsafe {
            terminal_render_to_sugarloaf(
                terminal_ptr,
                self.sugarloaf_handle,
                info.rich_text_id,
            )
        } {
            return false;
        }

        // 🎯 关键：设置 RichText 的渲染位置
        if let sugarloaf::Object::RichText(ref mut rich_text) = info.rich_text_object {
            rich_text.position = [x, y];
        }

        // 累积 RichText objects
        self.pending_objects.push(info.rich_text_object.clone());

        // 🔬 调试：画行线和列线
        unsafe {
            if let Some(sugarloaf) = self.sugarloaf_handle.as_ref() {
                // font_metrics 是物理像素，除以 scale 得到逻辑像素
                let scale = sugarloaf.scale;
                let logical_line_height = sugarloaf.font_metrics.line_height / scale;
                let logical_cell_width = sugarloaf.font_metrics.cell_width / scale;
                let line_thickness = 1.0; // 1 逻辑像素粗的线

                eprintln!("🔬 [DrawGrid] cell_width(物理)={}, line_height(物理)={}, scale={}",
                    sugarloaf.font_metrics.cell_width, sugarloaf.font_metrics.line_height, scale);
                eprintln!("🔬 [DrawGrid] cell_width(逻辑)={}, line_height(逻辑)={}",
                    logical_cell_width, logical_line_height);

                // 画行线（水平红线）
                for row in 0..=rows {
                    let line_y = y + row as f32 * logical_line_height;
                    let line_quad = sugarloaf::components::quad::Quad {
                        color: [1.0, 0.0, 0.0, 0.5], // 半透明红色
                        position: [x, line_y],
                        size: [width, line_thickness],
                        border_color: [0.0, 0.0, 0.0, 0.0],
                        border_radius: [0.0, 0.0, 0.0, 0.0],
                        border_width: 0.0,
                        shadow_color: [0.0, 0.0, 0.0, 0.0],
                        shadow_offset: [0.0, 0.0],
                        shadow_blur_radius: 0.0,
                    };
                    self.pending_objects.push(sugarloaf::Object::Quad(line_quad));
                }

                // 画列线（垂直蓝线）
                let grid_height = rows as f32 * logical_line_height;
                for col in 0..=cols {
                    let line_x = x + col as f32 * logical_cell_width;
                    let col_quad = sugarloaf::components::quad::Quad {
                        color: [0.0, 0.0, 1.0, 0.5], // 半透明蓝色
                        position: [line_x, y],
                        size: [line_thickness, grid_height],
                        border_color: [0.0, 0.0, 0.0, 0.0],
                        border_radius: [0.0, 0.0, 0.0, 0.0],
                        border_width: 0.0,
                        shadow_color: [0.0, 0.0, 0.0, 0.0],
                        shadow_offset: [0.0, 0.0],
                        shadow_blur_radius: 0.0,
                    };
                    self.pending_objects.push(sugarloaf::Object::Quad(col_quad));
                }
            }
        }

        true
    }

    /// 写入输入到指定终端
    fn write_input(&mut self, terminal_id: usize, data: &str) -> bool {
        let info = match self.terminals.get_mut(&terminal_id) {
            Some(info) => info,
            None => return false,
        };

        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        let data_cstr = match std::ffi::CString::new(data) {
            Ok(s) => s,
            Err(_) => return false,
        };

        unsafe { terminal_write_input(terminal_ptr, data_cstr.as_ptr()) }
    }

    /// 滚动指定终端
    fn scroll(&mut self, terminal_id: usize, delta_lines: i32) -> bool {
        let info = match self.terminals.get_mut(&terminal_id) {
            Some(info) => info,
            None => return false,
        };

        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe { terminal_scroll(terminal_ptr, delta_lines) }
    }

    /// 调整指定终端尺寸
    fn resize(&mut self, terminal_id: usize, cols: u16, rows: u16) -> bool {
        let info = match self.terminals.get_mut(&terminal_id) {
            Some(info) => info,
            None => return false,
        };

        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe { terminal_resize(terminal_ptr, cols, rows) }
    }

    /// 获取终端数量
    fn count(&self) -> usize {
        self.terminals.len()
    }

    /// 获取所有终端 ID
    fn get_all_ids(&self) -> Vec<usize> {
        self.terminals.keys().copied().collect()
    }

    /// 统一提交所有累积的 objects 并清空缓冲区
    fn flush(&mut self) {
        unsafe {
            if let Some(sugarloaf) = self.sugarloaf_handle.as_mut() {
                // 提交所有累积的 objects
                sugarloaf.set_objects(self.pending_objects.clone());
                // 🎯 关键：触发实际的 GPU 渲染
                sugarloaf.render();
            }
        }
        // 清空缓冲区
        self.pending_objects.clear();
    }

    /// 调整所有终端的字体大小
    /// operation: 0 = Reset, 1 = Decrease, 2 = Increase
    fn change_all_font_sizes(&mut self, operation: u8) {
        unsafe {
            if let Some(sugarloaf) = self.sugarloaf_handle.as_mut() {
                // 遍历所有终端，调整每个的字体大小
                for info in self.terminals.values() {
                    sugarloaf.instance.set_rich_text_font_size_based_on_action(
                        &info.rich_text_id,
                        operation,
                    );
                }

                // 更新追踪的字体大小
                match operation {
                    0 => sugarloaf.current_font_size = 12.0, // Reset 到默认值
                    1 => sugarloaf.current_font_size = (sugarloaf.current_font_size - 1.0).max(6.0),
                    2 => sugarloaf.current_font_size = (sugarloaf.current_font_size + 1.0).min(100.0),
                    _ => {}
                }

                // 🎯 从 Sugarloaf 获取实际渲染使用的 dimensions
                // 使用任意一个终端的 rich_text_id（字体是全局的，所有终端共享）
                if let Some(first_info) = self.terminals.values().next() {
                    sugarloaf.update_font_metrics_from_dimensions(first_info.rich_text_id);
                }

                eprintln!(
                    "[TerminalPool] 🔤 Font size changed to {}, metrics updated",
                    sugarloaf.current_font_size
                );
            }
        }
    }
}

// FFI 导出函数

/// 创建终端池
#[no_mangle]
pub extern "C" fn terminal_pool_new(sugarloaf: *mut SugarloafHandle) -> *mut TerminalPool {
    if sugarloaf.is_null() {
        return ptr::null_mut();
    }

    let pool = Box::new(TerminalPool::new(sugarloaf));
    Box::into_raw(pool)
}

/// 设置渲染回调
#[no_mangle]
pub extern "C" fn terminal_pool_set_render_callback(
    pool: *mut TerminalPool,
    callback: RenderCallback,
    context: *mut c_void,
) {
    if pool.is_null() {
        return;
    }

    let pool = unsafe { &mut *pool };
    pool.set_render_callback(callback, context);
}

/// 创建终端
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal(
    pool: *mut TerminalPool,
    cols: u16,
    rows: u16,
    shell: *const c_char,
) -> isize {
    if pool.is_null() || shell.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *pool };
    let shell_str = match unsafe { CStr::from_ptr(shell) }.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    match pool.create_terminal(cols, rows, shell_str) {
        Some(id) => id as isize,
        None => -1,
    }
}

/// 关闭终端
#[no_mangle]
pub extern "C" fn terminal_pool_close_terminal(
    pool: *mut TerminalPool,
    terminal_id: usize,
) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };
    if pool.close_terminal(terminal_id) {
        1
    } else {
        0
    }
}

/// 读取所有终端的 PTY 输出
#[no_mangle]
pub extern "C" fn terminal_pool_read_all(pool: *mut TerminalPool) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };
    if pool.read_all() {
        1
    } else {
        0
    }
}

/// 渲染指定终端
#[no_mangle]
pub extern "C" fn terminal_pool_render(
    pool: *mut TerminalPool,
    terminal_id: usize,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    cols: u16,
    rows: u16,
) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };
    if pool.render(terminal_id, x, y, width, height, cols, rows) {
        1
    } else {
        0
    }
}

/// 写入输入
#[no_mangle]
pub extern "C" fn terminal_pool_write_input(
    pool: *mut TerminalPool,
    terminal_id: usize,
    data: *const c_char,
) -> i32 {
    if pool.is_null() || data.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };
    let data_str = match unsafe { CStr::from_ptr(data) }.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };

    if pool.write_input(terminal_id, data_str) {
        1
    } else {
        0
    }
}

/// 滚动终端
#[no_mangle]
pub extern "C" fn terminal_pool_scroll(
    pool: *mut TerminalPool,
    terminal_id: usize,
    delta_lines: i32,
) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };
    if pool.scroll(terminal_id, delta_lines) {
        1
    } else {
        0
    }
}

/// 调整终端尺寸
#[no_mangle]
pub extern "C" fn terminal_pool_resize(
    pool: *mut TerminalPool,
    terminal_id: usize,
    cols: u16,
    rows: u16,
) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };
    if pool.resize(terminal_id, cols, rows) {
        1
    } else {
        0
    }
}

/// 获取终端数量
#[no_mangle]
pub extern "C" fn terminal_pool_count(pool: *mut TerminalPool) -> usize {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &*pool };
    pool.count()
}

/// 统一提交所有累积的 objects
#[no_mangle]
pub extern "C" fn terminal_pool_flush(pool: *mut TerminalPool) {
    if pool.is_null() {
        return;
    }

    let pool = unsafe { &mut *pool };
    pool.flush();
}

/// 释放终端池
#[no_mangle]
pub extern "C" fn terminal_pool_free(pool: *mut TerminalPool) {
    if !pool.is_null() {
        unsafe {
            let _ = Box::from_raw(pool);
        }
    }
}

// =============================================================================
// TerminalPool 光标上下文 API (Cursor Context API for Pool)
// =============================================================================

/// 设置指定终端的选中范围（用于高亮渲染）
#[no_mangle]
pub extern "C" fn terminal_pool_set_selection(
    pool: *mut TerminalPool,
    terminal_id: usize,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };

    if let Some(info) = pool.terminals.get_mut(&terminal_id) {
        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe {
            terminal_set_selection(terminal_ptr, start_row, start_col, end_row, end_col)
        }
    } else {
        0
    }
}

/// 清除指定终端的选中高亮
#[no_mangle]
pub extern "C" fn terminal_pool_clear_selection(
    pool: *mut TerminalPool,
    terminal_id: usize,
) -> i32 {
    if pool.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };

    if let Some(info) = pool.terminals.get_mut(&terminal_id) {
        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe {
            terminal_clear_selection_highlight(terminal_ptr)
        }
    } else {
        0
    }
}

/// 获取指定终端的选中文本
#[no_mangle]
pub extern "C" fn terminal_pool_get_text_range(
    pool: *mut TerminalPool,
    terminal_id: usize,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    out_buffer: *mut c_char,
    buffer_size: usize,
) -> i32 {
    if pool.is_null() || out_buffer.is_null() || buffer_size == 0 {
        return 0;
    }

    let pool = unsafe { &mut *pool };

    if let Some(info) = pool.terminals.get_mut(&terminal_id) {
        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe {
            terminal_get_text_range(
                terminal_ptr,
                start_row,
                start_col,
                end_row,
                end_col,
                out_buffer,
                buffer_size,
            )
        }
    } else {
        0
    }
}

/// 获取指定终端的当前输入行号
#[no_mangle]
pub extern "C" fn terminal_pool_get_input_row(
    pool: *mut TerminalPool,
    terminal_id: usize,
    out_row: *mut u16,
) -> i32 {
    if pool.is_null() || out_row.is_null() {
        return 0;
    }

    let pool = unsafe { &mut *pool };

    if let Some(info) = pool.terminals.get_mut(&terminal_id) {
        let terminal_ptr = &mut *info.terminal as *mut TerminalHandle;
        unsafe {
            terminal_get_input_row(terminal_ptr, out_row)
        }
    } else {
        0
    }
}

/// 调整所有终端的字体大小
/// operation: 0 = Reset, 1 = Decrease, 2 = Increase
#[no_mangle]
pub extern "C" fn terminal_pool_change_font_size(
    pool: *mut TerminalPool,
    operation: u8,
) {
    if pool.is_null() {
        return;
    }

    let pool = unsafe { &mut *pool };
    pool.change_all_font_sizes(operation);
}
