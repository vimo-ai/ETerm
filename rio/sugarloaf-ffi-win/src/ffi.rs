use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::ffi::{c_char, c_void, CString};
use std::hash::{Hash, Hasher};
use std::num::NonZeroIsize;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use corcovado::channel;
use parking_lot::RwLock;
use raw_window_handle::{RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle};
use rio_backend::ansi::CursorShape;
use rio_backend::crosswords::grid::Dimensions;
use rio_backend::crosswords::pos::{Column, Line, Pos, Side};
use rio_backend::crosswords::square::Flags;
use rio_backend::crosswords::{Crosswords, CrosswordsSize};
use rio_backend::selection::{Selection, SelectionType};
use rio_backend::event::Msg;
use sugarloaf::context::GpuContext;
use sugarloaf::SugarCursor;
use sugarloaf::font::FontLibrary;
use sugarloaf::layout::RootStyle;
use sugarloaf::{Sugarloaf, SugarloafRenderer, SugarloafWindow, SugarloafWindowSize};
use teletypewriter::windows::{create_pty, Pty};
use teletypewriter::WinsizeBuilder;

use crate::event::WinEventListener;
use crate::machine::{Machine, State as MachineState};

const FFI_OK: i32 = 0;
const FFI_ERR_NULL_HANDLE: i32 = -1;
const FFI_ERR_NOT_FOUND: i32 = -2;
const FFI_ERR_IO: i32 = -3;
const FFI_ERR_NULL_DATA: i32 = -4;
const FFI_ERR_RENDER: i32 = -5;
const FFI_ERR_PANIC: i32 = -99;

#[repr(C)]
pub struct SugarloafWinHandle {
    _private: [u8; 0],
}

struct Terminal {
    crosswords: Arc<RwLock<Crosswords<WinEventListener>>>,
    pty_tx: channel::Sender<Msg>,
    #[allow(dead_code)]
    machine_handle: JoinHandle<(Machine<Pty>, MachineState)>,
    dirty: Arc<AtomicBool>,
    title: String,
    cols: u16,
    rows: u16,
}

struct WinEngine {
    terminals: HashMap<i32, Terminal>,
    next_id: i32,
    sugarloaf: Option<Sugarloaf>,
    font_library: FontLibrary,
    rich_text_id: Option<usize>,
    hwnd: Option<NonZeroIsize>,
    scale: f32,
}

impl WinEngine {
    fn new() -> Self {
        Self {
            terminals: HashMap::new(),
            next_id: 1,
            sugarloaf: None,
            font_library: FontLibrary::default(),
            rich_text_id: None,
            hwnd: None,
            scale: 1.0,
        }
    }
}

unsafe fn engine_ref<'a>(handle: *mut SugarloafWinHandle) -> &'a mut WinEngine {
    &mut *(handle as *mut WinEngine)
}

#[inline]
fn ffi_boundary<T, F>(default: T, f: F) -> T
where
    F: FnOnce() -> T,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(panic_info) => {
            let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic".to_string()
            };
            eprintln!("[sugarloaf-ffi-win panic] {}", msg);
            default
        }
    }
}

// ============================================================================
// Grid extraction: Crosswords → Sugarloaf Content
// ============================================================================

fn cursor_to_sugar(shape: CursorShape, color: [f32; 4]) -> Option<SugarCursor> {
    match shape {
        CursorShape::Block => Some(SugarCursor::Block(color)),
        CursorShape::Underline => Some(SugarCursor::Underline(color)),
        CursorShape::Beam => Some(SugarCursor::Caret(color)),
        CursorShape::Hidden => None,
    }
}

fn extract_grid_to_sugarloaf(
    sugarloaf: &mut Sugarloaf,
    crosswords: &Crosswords<WinEventListener>,
    rich_text_id: &usize,
) {
    use rio_backend::config::colors::{AnsiColor, NamedColor};
    use sugarloaf::layout::{BuilderLine, FragmentData};

    let grid = &crosswords.grid;
    let total_lines = grid.screen_lines();
    let total_cols = grid.columns();
    let display_offset = grid.display_offset() as i32;

    let cursor_state = crosswords.cursor();
    let cursor_pos = cursor_state.pos;
    let cursor_shape = cursor_state.content;
    let cursor_color = [1.0f32, 1.0, 1.0, 1.0];

    let selection_range = crosswords
        .selection
        .as_ref()
        .and_then(|s| s.to_range(crosswords));

    let content = sugarloaf.content();

    let builder_state = match content.get_state_mut(rich_text_id) {
        Some(bs) => bs,
        None => return,
    };

    builder_state.lines.clear();

    for line_idx in 0..total_lines {
        let mut fragments = Vec::new();
        let mut current_text = String::new();
        let mut current_fg: [f32; 4] = [1.0, 1.0, 1.0, 1.0];
        let mut current_bg: Option<[f32; 4]> = None;
        let mut current_bold = false;
        let mut current_italic = false;
        let mut current_cursor: Option<SugarCursor> = None;

        let visual_line = Line(line_idx as i32 - display_offset);

        for col_idx in 0..total_cols {
            let cell = &grid[visual_line][Column(col_idx)];

            if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
                continue;
            }

            let fg = ansi_to_rgba(&cell.fg);
            let bg = match &cell.bg {
                AnsiColor::Named(NamedColor::Background) => None,
                other => Some(ansi_to_rgba(other)),
            };

            let bold = cell.flags.contains(Flags::BOLD);
            let italic = cell.flags.contains(Flags::ITALIC);
            let inverse = cell.flags.contains(Flags::INVERSE);

            let is_cursor = cursor_pos.row == visual_line
                && cursor_pos.col.0 == col_idx;
            let cell_cursor = if is_cursor {
                cursor_to_sugar(cursor_shape, cursor_color)
            } else {
                None
            };

            let (mut actual_fg, mut actual_bg) = if inverse {
                let bg_color = bg.unwrap_or([0.0, 0.0, 0.0, 1.0]);
                (bg_color, Some(fg))
            } else {
                (fg, bg)
            };

            if let Some(ref range) = selection_range {
                let cell_pos = Pos::new(visual_line, Column(col_idx));
                if range.contains(cell_pos) {
                    let tmp = actual_fg;
                    actual_fg = actual_bg.unwrap_or([0.0, 0.0, 0.0, 1.0]);
                    actual_bg = Some(tmp);
                }
            }

            let style_changed = actual_fg != current_fg
                || actual_bg != current_bg
                || bold != current_bold
                || italic != current_italic
                || cell_cursor != current_cursor;

            if style_changed && !current_text.is_empty() {
                fragments.push(FragmentData {
                    content: std::mem::take(&mut current_text),
                    style: make_fragment_style(
                        current_fg,
                        current_bg,
                        current_bold,
                        current_italic,
                        current_cursor,
                        1.0,
                    ),
                });
            }

            current_fg = actual_fg;
            current_bg = actual_bg;
            current_bold = bold;
            current_italic = italic;
            current_cursor = cell_cursor;

            let is_wide = cell.flags.contains(Flags::WIDE_CHAR);

            if is_wide && !current_text.is_empty() {
                fragments.push(FragmentData {
                    content: std::mem::take(&mut current_text),
                    style: make_fragment_style(
                        current_fg,
                        current_bg,
                        current_bold,
                        current_italic,
                        current_cursor,
                        1.0,
                    ),
                });
            }

            current_text.push(cell.c);

            if let Some(zw) = cell.zerowidth() {
                for &ch in zw {
                    current_text.push(ch);
                }
            }

            if is_wide {
                fragments.push(FragmentData {
                    content: std::mem::take(&mut current_text),
                    style: make_fragment_style(
                        current_fg,
                        current_bg,
                        current_bold,
                        current_italic,
                        current_cursor,
                        2.0,
                    ),
                });
            }
        }

        if !current_text.is_empty() {
            fragments.push(FragmentData {
                content: current_text,
                style: make_fragment_style(
                    current_fg,
                    current_bg,
                    current_bold,
                    current_italic,
                    current_cursor,
                    1.0,
                ),
            });
        }

        let mut hasher = DefaultHasher::new();
        line_idx.hash(&mut hasher);
        for frag in &fragments {
            frag.content.hash(&mut hasher);
        }

        builder_state.lines.push(BuilderLine {
            content_hash: hasher.finish(),
            fragments,
            ..Default::default()
        });
    }

    static EXTRACT_COUNT: std::sync::atomic::AtomicU32 =
        std::sync::atomic::AtomicU32::new(0);
    let ec = EXTRACT_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    if ec < 5 {
        let total_frags: usize = builder_state
            .lines
            .iter()
            .map(|l| l.fragments.len())
            .sum();
        let sample = builder_state
            .lines
            .first()
            .and_then(|l| l.fragments.first())
            .map(|f| f.content.chars().take(30).collect::<String>())
            .unwrap_or_default();
        eprintln!(
            "[extract #{}] pushed {} lines, {} total frags, first_line_sample={:?}",
            ec,
            builder_state.lines.len(),
            total_frags,
            sample
        );
    }

    builder_state.mark_dirty();
}

fn ansi_to_rgba(color: &rio_backend::config::colors::AnsiColor) -> [f32; 4] {
    use rio_backend::config::colors::{AnsiColor, NamedColor};

    match color {
        AnsiColor::Named(named) => match named {
            NamedColor::Foreground | NamedColor::LightWhite => [1.0, 1.0, 1.0, 1.0],
            NamedColor::Background | NamedColor::Black => [0.0, 0.0, 0.0, 1.0],
            NamedColor::Red => [0.8, 0.0, 0.0, 1.0],
            NamedColor::Green => [0.0, 0.8, 0.0, 1.0],
            NamedColor::Yellow => [0.8, 0.8, 0.0, 1.0],
            NamedColor::Blue => [0.0, 0.0, 0.8, 1.0],
            NamedColor::Magenta => [0.8, 0.0, 0.8, 1.0],
            NamedColor::Cyan => [0.0, 0.8, 0.8, 1.0],
            NamedColor::White => [0.75, 0.75, 0.75, 1.0],
            NamedColor::LightBlack => [0.5, 0.5, 0.5, 1.0],
            NamedColor::LightRed => [1.0, 0.33, 0.33, 1.0],
            NamedColor::LightGreen => [0.33, 1.0, 0.33, 1.0],
            NamedColor::LightYellow => [1.0, 1.0, 0.33, 1.0],
            NamedColor::LightBlue => [0.33, 0.33, 1.0, 1.0],
            NamedColor::LightMagenta => [1.0, 0.33, 1.0, 1.0],
            NamedColor::LightCyan => [0.33, 1.0, 1.0, 1.0],
            _ => [1.0, 1.0, 1.0, 1.0],
        },
        AnsiColor::Spec(rgb) => [
            rgb.r as f32 / 255.0,
            rgb.g as f32 / 255.0,
            rgb.b as f32 / 255.0,
            1.0,
        ],
        AnsiColor::Indexed(idx) => {
            match idx {
                0 => [0.0, 0.0, 0.0, 1.0],
                1 => [0.8, 0.0, 0.0, 1.0],
                2 => [0.0, 0.8, 0.0, 1.0],
                3 => [0.8, 0.8, 0.0, 1.0],
                4 => [0.0, 0.0, 0.8, 1.0],
                5 => [0.8, 0.0, 0.8, 1.0],
                6 => [0.0, 0.8, 0.8, 1.0],
                7 => [0.75, 0.75, 0.75, 1.0],
                8 => [0.5, 0.5, 0.5, 1.0],
                9 => [1.0, 0.33, 0.33, 1.0],
                10 => [0.33, 1.0, 0.33, 1.0],
                11 => [1.0, 1.0, 0.33, 1.0],
                12 => [0.33, 0.33, 1.0, 1.0],
                13 => [1.0, 0.33, 1.0, 1.0],
                14 => [0.33, 1.0, 1.0, 1.0],
                15 => [1.0, 1.0, 1.0, 1.0],
                16..=231 => {
                    let i = idx - 16;
                    let r = i / 36;
                    let g = (i % 36) / 6;
                    let b = i % 6;
                    let to_f = |v: u8| {
                        if v == 0 {
                            0.0
                        } else {
                            (55.0 + v as f32 * 40.0) / 255.0
                        }
                    };
                    [to_f(r), to_f(g), to_f(b), 1.0]
                }
                _ => {
                    let gray = (8.0 + (idx - 232) as f32 * 10.0) / 255.0;
                    [gray, gray, gray, 1.0]
                }
            }
        }
    }
}

fn make_fragment_style(
    fg: [f32; 4],
    bg: Option<[f32; 4]>,
    bold: bool,
    italic: bool,
    cursor: Option<SugarCursor>,
    width: f32,
) -> sugarloaf::FragmentStyle {
    use sugarloaf::font_introspector::{Attributes, Stretch, Style, Weight};

    let font_attrs = Attributes::new(
        Stretch::NORMAL,
        if bold { Weight::BOLD } else { Weight::NORMAL },
        if italic { Style::Italic } else { Style::Normal },
    );

    sugarloaf::FragmentStyle {
        font_id: 0,
        width,
        font_attrs,
        color: fg,
        background_color: bg,
        font_vars: 0,
        decoration: None,
        decoration_color: None,
        cursor,
        media: None,
        drawable_char: None,
    }
}

// ============================================================================
// FFI exports
// ============================================================================

#[no_mangle]
pub extern "C" fn sugarloaf_win_init() -> *mut SugarloafWinHandle {
    ffi_boundary(std::ptr::null_mut(), || {
        let engine = Box::new(WinEngine::new());
        Box::into_raw(engine) as *mut SugarloafWinHandle
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_destroy(handle: *mut SugarloafWinHandle) {
    if handle.is_null() {
        return;
    }
    ffi_boundary((), || unsafe {
        let engine = Box::from_raw(handle as *mut WinEngine);
        // Shutdown all terminal Machine threads
        for (_, terminal) in engine.terminals.iter() {
            let _ = terminal.pty_tx.send(Msg::Shutdown);
        }
        drop(engine);
    });
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_init_renderer(
    handle: *mut SugarloafWinHandle,
    hwnd: *mut c_void,
    width: f32,
    height: f32,
    scale: f32,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }
    if hwnd.is_null() {
        return FFI_ERR_NULL_DATA;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };

        let wh = Win32WindowHandle::new(
            NonZeroIsize::new(hwnd as isize).expect("HWND must be non-zero"),
        );
        let win = SugarloafWindow {
            handle: RawWindowHandle::Win32(wh),
            display: RawDisplayHandle::Windows(WindowsDisplayHandle::new()),
            size: SugarloafWindowSize { width, height },
            scale,
        };

        let renderer = SugarloafRenderer::default();
        let layout = RootStyle::default();

        match Sugarloaf::new(win, renderer, &engine.font_library, layout) {
            Ok(mut sugarloaf) => {
                let rt_id = sugarloaf.create_rich_text();

                sugarloaf.set_objects(vec![sugarloaf::Object::RichText(sugarloaf::RichText {
                    id: rt_id,
                    position: [0.0, 0.0],
                    lines: None,
                })]);

                engine.rich_text_id = Some(rt_id);
                engine.hwnd = NonZeroIsize::new(hwnd as isize);
                engine.scale = scale;
                engine.sugarloaf = Some(sugarloaf);
                eprintln!(
                    "[ffi] Renderer initialized: {}x{} @ {:.1}x, rt_id={}",
                    width, height, scale, rt_id
                );
                FFI_OK
            }
            Err(e) => {
                eprintln!("[sugarloaf-ffi-win] init_renderer failed: {:?}", e);
                FFI_ERR_RENDER
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_create_terminal(
    handle: *mut SugarloafWinHandle,
    cols: u16,
    rows: u16,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };
        let id = engine.next_id;
        engine.next_id += 1;

        let pty = match create_pty("powershell.exe", vec![], &None, cols, rows) {
            Ok(pty) => pty,
            Err(e) => {
                eprintln!("[sugarloaf-ffi-win] create_terminal failed: {:?}", e);
                return FFI_ERR_IO;
            }
        };

        let dirty = Arc::new(AtomicBool::new(true));
        let event_listener = WinEventListener::new(dirty.clone(), id as usize);

        let size = CrosswordsSize::new(cols as usize, rows as usize);
        let mut crosswords = Crosswords::new(
            size,
            CursorShape::Block,
            event_listener.clone(),
            rio_backend::event::WindowId::from(0),
            id as usize,
        );
        crosswords.grid.update_history(10_000);
        let crosswords = Arc::new(RwLock::new(crosswords));

        let machine = match Machine::new(
            crosswords.clone(),
            pty,
            event_listener,
            id as usize,
        ) {
            Ok(m) => m,
            Err(e) => {
                eprintln!(
                    "[sugarloaf-ffi-win] create machine failed: {:?}",
                    e
                );
                return FFI_ERR_IO;
            }
        };

        let pty_tx = machine.channel();
        let machine_handle = machine.spawn();

        engine.terminals.insert(
            id,
            Terminal {
                crosswords,
                pty_tx,
                machine_handle,
                dirty,
                title: format!("Terminal {}", id),
                cols,
                rows,
            },
        );

        id
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_close_terminal(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.remove(&terminal_id) {
            Some(terminal) => {
                let _ = terminal.pty_tx.send(Msg::Shutdown);
                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_write(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
    data: *const u8,
    len: u32,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }
    if data.is_null() {
        return FFI_ERR_NULL_DATA;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };
        let bytes = unsafe { slice::from_raw_parts(data, len as usize) };

        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                use std::borrow::Cow;
                let _ = terminal
                    .pty_tx
                    .send(Msg::Input(Cow::Owned(bytes.to_vec())));
                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_resize(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
    cols: u16,
    rows: u16,
    width: u16,
    height: u16,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };

        match engine.terminals.get_mut(&terminal_id) {
            Some(terminal) => {
                terminal.cols = cols;
                terminal.rows = rows;

                // Resize crosswords grid
                {
                    let mut cw = terminal.crosswords.write();
                    let size = CrosswordsSize::new(cols as usize, rows as usize);
                    cw.resize::<CrosswordsSize>(size);
                }

                // Notify PTY of size change
                let winsize = WinsizeBuilder {
                    rows,
                    cols,
                    width,
                    height,
                };
                let _ = terminal.pty_tx.send(Msg::Resize(winsize));
                terminal.dirty.store(true, Ordering::Release);

                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_render(handle: *mut SugarloafWinHandle) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };

        let sugarloaf = match engine.sugarloaf.as_mut() {
            Some(s) => s,
            None => return FFI_ERR_RENDER,
        };

        let rt_id = match engine.rich_text_id {
            Some(id) => id,
            None => return FFI_ERR_RENDER,
        };

        static DIAG_COUNTER: std::sync::atomic::AtomicU32 =
            std::sync::atomic::AtomicU32::new(0);

        let mut needs_render = false;

        if let Some((_, terminal)) = engine.terminals.iter().next() {
            if terminal.dirty.swap(false, Ordering::AcqRel) {
                let cw = terminal.crosswords.read();

                let n = DIAG_COUNTER.fetch_add(1, Ordering::Relaxed);
                if n < 10 || n % 120 == 0 {
                    let grid = &cw.grid;
                    let lines = grid.screen_lines();
                    let cols = grid.columns();
                    let mut non_empty = 0usize;
                    for li in 0..lines {
                        for ci in 0..cols {
                            let c = grid[Line(li as i32)][Column(ci)].c;
                            if c != ' ' && c != '\0' {
                                non_empty += 1;
                            }
                        }
                    }
                    eprintln!(
                        "[diag #{}] grid={}x{}, non_empty={}, rt_id={}, cursor={:?}",
                        n, cols, lines, non_empty, rt_id, cw.cursor()
                    );
                }

                extract_grid_to_sugarloaf(sugarloaf, &cw, &rt_id);
                needs_render = true;
            }
        }

        sugarloaf.render();
        FFI_OK
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_resize_renderer(
    handle: *mut SugarloafWinHandle,
    width: f32,
    height: f32,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };

        let hwnd_nz = match engine.hwnd {
            Some(h) => h,
            None => return FFI_ERR_RENDER,
        };

        // Drop old Sugarloaf to fully release all D3D12 resources
        engine.sugarloaf.take();
        engine.rich_text_id = None;

        let wh = Win32WindowHandle::new(hwnd_nz);
        let win = SugarloafWindow {
            handle: RawWindowHandle::Win32(wh),
            display: RawDisplayHandle::Windows(WindowsDisplayHandle::new()),
            size: SugarloafWindowSize { width, height },
            scale: engine.scale,
        };

        let renderer = SugarloafRenderer::default();
        let layout = RootStyle::default();

        match Sugarloaf::new(win, renderer, &engine.font_library, layout) {
            Ok(mut sugarloaf) => {
                let rt_id = sugarloaf.create_rich_text();
                sugarloaf.set_objects(vec![sugarloaf::Object::RichText(
                    sugarloaf::RichText {
                        id: rt_id,
                        position: [0.0, 0.0],
                        lines: None,
                    },
                )]);
                engine.rich_text_id = Some(rt_id);
                engine.sugarloaf = Some(sugarloaf);

                // Force a dirty re-extract on next render
                for (_, terminal) in engine.terminals.iter() {
                    terminal.dirty.store(true, Ordering::Release);
                }
                FFI_OK
            }
            Err(e) => {
                eprintln!("[ffi] resize: recreate failed: {:?}", e);
                FFI_ERR_RENDER
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_get_title(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    ffi_boundary(std::ptr::null_mut(), || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                let cw = terminal.crosswords.read();
                let title = if cw.title.is_empty() {
                    &terminal.title
                } else {
                    &cw.title
                };
                CString::new(title.as_str())
                    .map(|cs| cs.into_raw())
                    .unwrap_or(std::ptr::null_mut())
            }
            None => std::ptr::null_mut(),
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_scroll(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
    delta: i32,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                use rio_backend::crosswords::grid::Scroll;
                let scroll = match delta {
                    i32::MAX => Scroll::Bottom,
                    i32::MIN => Scroll::Top,
                    d => Scroll::Delta(d),
                };
                terminal.crosswords.write().scroll_display(scroll);
                terminal.dirty.store(true, Ordering::Release);
                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct FontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub line_height: f32,
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_get_font_metrics(
    handle: *mut SugarloafWinHandle,
    out: *mut FontMetrics,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }
    if out.is_null() {
        return FFI_ERR_NULL_DATA;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };

        let sugarloaf = match engine.sugarloaf.as_ref() {
            Some(s) => s,
            None => return FFI_ERR_RENDER,
        };

        let (cell_width, cell_height, line_height) = sugarloaf.get_font_metrics_skia();

        unsafe {
            *out = FontMetrics {
                cell_width,
                cell_height,
                line_height,
            };
        }

        FFI_OK
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_is_bracketed_paste_enabled(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    ffi_boundary(false, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                use rio_backend::crosswords::Mode;
                let cw = terminal.crosswords.read();
                cw.mode().contains(Mode::BRACKETED_PASTE)
            }
            None => false,
        }
    })
}

#[repr(C)]
pub struct ScreenToAbsoluteResult {
    pub absolute_row: i64,
    pub col: usize,
    pub success: bool,
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_screen_to_absolute(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
    screen_row: usize,
    screen_col: usize,
) -> ScreenToAbsoluteResult {
    let fail = ScreenToAbsoluteResult {
        absolute_row: 0,
        col: 0,
        success: false,
    };

    if handle.is_null() {
        return fail;
    }

    ffi_boundary(fail, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                let cw = terminal.crosswords.read();
                let grid = &cw.grid;
                let history_size = grid.history_size();
                let display_offset = grid.display_offset();
                let absolute_row =
                    (history_size + screen_row).saturating_sub(display_offset) as i64;
                ScreenToAbsoluteResult {
                    absolute_row,
                    col: screen_col,
                    success: true,
                }
            }
            None => ScreenToAbsoluteResult {
                absolute_row: 0,
                col: 0,
                success: false,
            },
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_set_selection(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
    start_absolute_row: i64,
    start_col: usize,
    end_absolute_row: i64,
    end_col: usize,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                let mut cw = terminal.crosswords.write();
                let history_size = cw.grid.history_size() as i64;
                let display_offset = cw.grid.display_offset() as i64;

                let start_row =
                    Line((start_absolute_row - history_size + display_offset) as i32);
                let end_row =
                    Line((end_absolute_row - history_size + display_offset) as i32);

                let start_pos = Pos::new(start_row, Column(start_col));
                let end_pos = Pos::new(end_row, Column(end_col));

                let mut selection =
                    Selection::new(SelectionType::Simple, start_pos, Side::Left);
                selection.update(end_pos, Side::Right);
                cw.selection = Some(selection);

                terminal.dirty.store(true, Ordering::Release);
                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_clear_selection(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> i32 {
    if handle.is_null() {
        return FFI_ERR_NULL_HANDLE;
    }

    ffi_boundary(FFI_ERR_PANIC, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                terminal.crosswords.write().selection = None;
                terminal.dirty.store(true, Ordering::Release);
                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

#[repr(C)]
pub struct SelectionTextResult {
    pub text: *mut c_char,
    pub text_len: usize,
    pub success: bool,
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_get_selection_text(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> SelectionTextResult {
    let fail = SelectionTextResult {
        text: std::ptr::null_mut(),
        text_len: 0,
        success: false,
    };

    if handle.is_null() {
        return fail;
    }

    ffi_boundary(fail, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                let cw = terminal.crosswords.read();
                match cw.selection_to_string() {
                    Some(text) => {
                        let text_len = text.len();
                        let c_string = CString::new(text).unwrap_or_default();
                        SelectionTextResult {
                            text: c_string.into_raw(),
                            text_len,
                            success: true,
                        }
                    }
                    None => SelectionTextResult {
                        text: std::ptr::null_mut(),
                        text_len: 0,
                        success: false,
                    },
                }
            }
            None => SelectionTextResult {
                text: std::ptr::null_mut(),
                text_len: 0,
                success: false,
            },
        }
    })
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_finalize_selection(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> SelectionTextResult {
    let fail = SelectionTextResult {
        text: std::ptr::null_mut(),
        text_len: 0,
        success: false,
    };

    if handle.is_null() {
        return fail;
    }

    ffi_boundary(fail, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                let mut cw = terminal.crosswords.write();
                match cw.selection_to_string() {
                    Some(text) if !text.trim().is_empty() => {
                        let text_len = text.len();
                        let c_string = CString::new(text).unwrap_or_default();
                        SelectionTextResult {
                            text: c_string.into_raw(),
                            text_len,
                            success: true,
                        }
                    }
                    _ => {
                        cw.selection = None;
                        terminal.dirty.store(true, Ordering::Release);
                        SelectionTextResult {
                            text: std::ptr::null_mut(),
                            text_len: 0,
                            success: false,
                        }
                    }
                }
            }
            None => SelectionTextResult {
                text: std::ptr::null_mut(),
                text_len: 0,
                success: false,
            },
        }
    })
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CursorPosition {
    pub row: i32,
    pub col: i32,
}

#[no_mangle]
pub extern "C" fn sugarloaf_win_get_cursor_pos(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> CursorPosition {
    let fail = CursorPosition { row: 0, col: 0 };
    if handle.is_null() {
        return fail;
    }

    ffi_boundary(fail, || {
        let engine = unsafe { engine_ref(handle) };
        match engine.terminals.get(&terminal_id) {
            Some(terminal) => {
                let cw = terminal.crosswords.read();
                let cursor = cw.cursor();
                CursorPosition {
                    row: cursor.pos.row.0,
                    col: cursor.pos.col.0 as i32,
                }
            }
            None => fail,
        }
    })
}
