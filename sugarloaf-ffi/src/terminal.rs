use std::ffi::{c_char, CStr};
use std::io::Read;
use std::ptr;
use std::sync::Arc;
use parking_lot::Mutex;

use rio_backend::ansi::CursorShape;
use rio_backend::crosswords::{Crosswords, CrosswordsSize};
use rio_backend::event::{EventListener, WindowId};
use rio_backend::performer::handler::Processor;
use rio_backend::config::colors::{AnsiColor, NamedColor, ColorRgb};
use teletypewriter::{create_pty_with_fork, WinsizeBuilder, ProcessReadWrite};

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

/// 终端句柄
pub struct TerminalHandle {
    pty: Arc<Mutex<teletypewriter::Pty>>,
    terminal: Arc<Mutex<Crosswords<VoidListener>>>,
    parser: Arc<Mutex<Processor>>,
    cols: u16,
    rows: u16,
}

/// 简单的事件监听器实现 (不发送任何事件)
#[derive(Clone)]
struct VoidListener;

impl EventListener for VoidListener {
    fn event(&self) -> (Option<rio_backend::event::RioEvent>, bool) {
        (None, false)
    }
}

/// 创建终端
#[no_mangle]
pub extern "C" fn terminal_create(
    cols: u16,
    rows: u16,
    shell_program: *const c_char,
) -> *mut TerminalHandle {
    if shell_program.is_null() {
        eprintln!("[Terminal FFI] Error: shell_program is null");
        return ptr::null_mut();
    }

    let shell = unsafe { CStr::from_ptr(shell_program).to_str().unwrap_or("/bin/zsh") };

    eprintln!("[Terminal FFI] Creating terminal:");
    eprintln!("  - cols: {}, rows: {}", cols, rows);
    eprintln!("  - shell: {}", shell);

    // 创建 PTY
    let pty = match create_pty_with_fork(
        &std::borrow::Cow::Borrowed(shell),
        cols,
        rows,
    ) {
        Ok(pty) => {
            eprintln!("[Terminal FFI] ✅ PTY created successfully");
            pty
        }
        Err(e) => {
            eprintln!("[Terminal FFI] ❌ Failed to create PTY: {:?}", e);
            return ptr::null_mut();
        }
    };

    // 创建终端状态（Crosswords）
    let listener = VoidListener;

    // CrosswordsSize 需要所有字段 (u32 类型)
    let dimensions = CrosswordsSize {
        columns: cols as usize,
        screen_lines: rows as usize,
        width: (cols as u32) * 8,  // 假设每个字符8像素宽
        height: (rows as u32) * 16,  // 假设每个字符16像素高
        square_width: 8,
        square_height: 16,
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

    // 创建 ANSI 解析器
    let parser = Processor::default();

    eprintln!("[Terminal FFI] ✅ Terminal created successfully");

    let handle = Box::new(TerminalHandle {
        pty: Arc::new(Mutex::new(pty)),
        terminal: Arc::new(Mutex::new(terminal)),
        parser: Arc::new(Mutex::new(parser)),
        cols,
        rows,
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
            // EOF - 进程可能已退出
            eprintln!("[Terminal FFI] EOF from PTY");
            false
        }
        Ok(n) => {
            // 有数据
            let data = &buf[..n];
            eprintln!("[Terminal FFI] Read {} bytes from PTY", n);

            // 释放 PTY 锁
            drop(pty);

            // 使用 Processor 解析数据并更新终端状态
            let mut terminal = handle.terminal.lock();
            let mut parser = handle.parser.lock();

            // Processor::advance 会自动解析 ANSI 序列并更新 terminal
            parser.advance(&mut *terminal, data);

            eprintln!("[Terminal FFI] Parsed and applied {} bytes", n);

            true
        }
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
            // 没有数据可读（非阻塞模式）
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

    eprintln!("[Terminal FFI] Writing {} bytes to PTY: {:?}", input.len(),
              String::from_utf8_lossy(input));

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

    eprintln!("[Terminal FFI] Resizing to {}x{}", cols, rows);

    // 调整 PTY 大小
    let mut pty = handle.pty.lock();
    let winsize = WinsizeBuilder {
        cols,
        rows,
        width: cols * 8,
        height: rows * 16,
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
        width: (cols as u32) * 8,
        height: (rows as u32) * 16,
        square_width: 8,
        square_height: 16,
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
        eprintln!("[Terminal FFI] Terminal freed");
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
