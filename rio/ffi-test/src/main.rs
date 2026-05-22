use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicI32, AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock};

use libloading::{Library, Symbol};
use windows::Win32::Foundation::{HANDLE, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::UI::Input::Ime::{
    CFS_POINT, COMPOSITIONFORM, ImmGetContext, ImmReleaseContext, ImmSetCompositionWindow,
};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

type InitFn = unsafe extern "C" fn() -> *mut c_void;
type DestroyFn = unsafe extern "C" fn(*mut c_void);
type InitRendererFn = unsafe extern "C" fn(*mut c_void, *mut c_void, f32, f32, f32) -> i32;
type RenderFn = unsafe extern "C" fn(*mut c_void) -> i32;
type CreateTerminalFn = unsafe extern "C" fn(*mut c_void, u16, u16) -> i32;
type CloseTerminalFn = unsafe extern "C" fn(*mut c_void, i32) -> i32;
type WriteFn = unsafe extern "C" fn(*mut c_void, i32, *const u8, u32) -> i32;
type ResizeFn = unsafe extern "C" fn(*mut c_void, i32, u16, u16, u16, u16) -> i32;
type ResizeRendererFn = unsafe extern "C" fn(*mut c_void, f32, f32) -> i32;
type GetFontMetricsFn = unsafe extern "C" fn(*mut c_void, *mut FontMetrics) -> i32;
type ScreenToAbsFn =
    unsafe extern "C" fn(*mut c_void, i32, usize, usize) -> ScreenToAbsoluteResult;
type SetSelectionFn = unsafe extern "C" fn(*mut c_void, i32, i64, usize, i64, usize) -> i32;
type ClearSelectionFn = unsafe extern "C" fn(*mut c_void, i32) -> i32;
type GetSelectionTextFn = unsafe extern "C" fn(*mut c_void, i32) -> SelectionTextResult;
type FinalizeSelectionFn = unsafe extern "C" fn(*mut c_void, i32) -> SelectionTextResult;
type IsBracketedPasteFn = unsafe extern "C" fn(*mut c_void, i32) -> bool;
type FreeStringFn = unsafe extern "C" fn(*mut c_char);
type ScrollFn = unsafe extern "C" fn(*mut c_void, i32, i32) -> i32;
type GetCursorPosFn = unsafe extern "C" fn(*mut c_void, i32) -> CursorPosition;

const CF_UNICODETEXT_ID: u32 = 13;
const TIMER_RENDER: usize = 1;

#[repr(C)]
#[derive(Clone, Copy)]
struct FontMetrics {
    cell_width: f32,
    cell_height: f32,
    line_height: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct ScreenToAbsoluteResult {
    absolute_row: i64,
    col: usize,
    success: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CursorPosition {
    row: i32,
    col: i32,
}

#[repr(C)]
struct SelectionTextResult {
    text: *mut c_char,
    text_len: usize,
    success: bool,
}

#[derive(Debug)]
struct EngineState {
    handle: *mut c_void,
    terminal_id: i32,
    lib: Library,
}

unsafe impl Send for EngineState {}
unsafe impl Sync for EngineState {}

struct MouseState {
    selecting: bool,
    start_abs_row: i64,
    start_col: usize,
}

static ENGINE: OnceLock<EngineState> = OnceLock::new();
static CELL_W: AtomicU32 = AtomicU32::new(0);
static CELL_H: AtomicU32 = AtomicU32::new(0);
static WHEEL_ACCUM: AtomicI32 = AtomicI32::new(0);
static MOUSE: Mutex<MouseState> = Mutex::new(MouseState {
    selecting: false,
    start_abs_row: 0,
    start_col: 0,
});

// ── PTY write ──

fn write_to_pty(data: &[u8]) {
    let Some(state) = ENGINE.get() else { return };
    unsafe {
        let write: Symbol<WriteFn> = state.lib.get(b"sugarloaf_win_write").unwrap();
        write(
            state.handle,
            state.terminal_id,
            data.as_ptr(),
            data.len() as u32,
        );
    }
}

// ── Coordinate helpers ──

fn cell_w() -> f32 {
    f32::from_bits(CELL_W.load(Ordering::Relaxed))
}

fn cell_h() -> f32 {
    f32::from_bits(CELL_H.load(Ordering::Relaxed))
}

fn update_font_metrics(state: &EngineState) {
    unsafe {
        let mut metrics = FontMetrics {
            cell_width: 0.0,
            cell_height: 0.0,
            line_height: 0.0,
        };
        let get_metrics: Symbol<GetFontMetricsFn> =
            state.lib.get(b"sugarloaf_win_get_font_metrics").unwrap();
        let rc = get_metrics(state.handle, &mut metrics);
        if rc == 0 {
            CELL_W.store(metrics.cell_width.to_bits(), Ordering::Relaxed);
            CELL_H.store(metrics.line_height.to_bits(), Ordering::Relaxed);
        }
    }
}

fn pixel_to_cell(x: i32, y: i32) -> (usize, usize) {
    let col = (x.max(0) as f32 / cell_w()) as usize;
    let row = (y.max(0) as f32 / cell_h()) as usize;
    (col, row)
}

fn screen_to_abs(state: &EngineState, row: usize, col: usize) -> Option<(i64, usize)> {
    unsafe {
        let func: Symbol<ScreenToAbsFn> = state
            .lib
            .get(b"sugarloaf_win_screen_to_absolute")
            .unwrap();
        let r = func(state.handle, state.terminal_id, row, col);
        r.success.then_some((r.absolute_row, r.col))
    }
}

// ── Selection ──

fn start_selection(hwnd: HWND, x: i32, y: i32) {
    let Some(state) = ENGINE.get() else { return };
    unsafe {
        let clear: Symbol<ClearSelectionFn> = state
            .lib
            .get(b"sugarloaf_win_clear_selection")
            .unwrap();
        clear(state.handle, state.terminal_id);
    }
    let (col, row) = pixel_to_cell(x, y);
    if let Some((abs_row, abs_col)) = screen_to_abs(state, row, col) {
        let mut m = MOUSE.lock().unwrap();
        m.selecting = true;
        m.start_abs_row = abs_row;
        m.start_col = abs_col;
    }
    unsafe {
        SetCapture(hwnd);
    }
}

fn update_selection(x: i32, y: i32) {
    let Some(state) = ENGINE.get() else { return };
    let m = MOUSE.lock().unwrap();
    if !m.selecting {
        return;
    }
    let (col, row) = pixel_to_cell(x, y);
    if let Some((abs_row, abs_col)) = screen_to_abs(state, row, col) {
        unsafe {
            let set: Symbol<SetSelectionFn> = state
                .lib
                .get(b"sugarloaf_win_set_selection")
                .unwrap();
            set(
                state.handle,
                state.terminal_id,
                m.start_abs_row,
                m.start_col,
                abs_row,
                abs_col,
            );
        }
    }
}

fn end_selection() {
    let Some(state) = ENGINE.get() else { return };
    {
        let mut m = MOUSE.lock().unwrap();
        if !m.selecting {
            return;
        }
        m.selecting = false;
    }
    unsafe {
        let fin: Symbol<FinalizeSelectionFn> = state
            .lib
            .get(b"sugarloaf_win_finalize_selection")
            .unwrap();
        let r = fin(state.handle, state.terminal_id);
        if r.success && !r.text.is_null() {
            let free: Symbol<FreeStringFn> =
                state.lib.get(b"sugarloaf_win_free_string").unwrap();
            free(r.text);
        }
        let _ = ReleaseCapture();
    }
}

fn try_copy_selection() -> bool {
    let Some(state) = ENGINE.get() else {
        return false;
    };
    unsafe {
        let get: Symbol<GetSelectionTextFn> = state
            .lib
            .get(b"sugarloaf_win_get_selection_text")
            .unwrap();
        let r = get(state.handle, state.terminal_id);
        if r.success && !r.text.is_null() {
            let c_str = std::ffi::CStr::from_ptr(r.text);
            if let Ok(s) = c_str.to_str() {
                clipboard_set(s);
            }
            let free: Symbol<FreeStringFn> =
                state.lib.get(b"sugarloaf_win_free_string").unwrap();
            free(r.text);
            let clear: Symbol<ClearSelectionFn> = state
                .lib
                .get(b"sugarloaf_win_clear_selection")
                .unwrap();
            clear(state.handle, state.terminal_id);
            return true;
        }
    }
    false
}

// ── Clipboard ──

fn clipboard_set(text: &str) {
    unsafe {
        if OpenClipboard(None).is_err() {
            return;
        }
        let _ = EmptyClipboard();
        let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
        let bytes = wide.len() * 2;
        if let Ok(hmem) = GlobalAlloc(GMEM_MOVEABLE, bytes) {
            let ptr = GlobalLock(hmem);
            if !ptr.is_null() {
                std::ptr::copy_nonoverlapping(
                    wide.as_ptr() as *const u8,
                    ptr as *mut u8,
                    bytes,
                );
                let _ = GlobalUnlock(hmem);
                let _ = SetClipboardData(
                    CF_UNICODETEXT_ID,
                    Some(HANDLE(hmem.0 as *mut c_void)),
                );
            }
        }
        let _ = CloseClipboard();
    }
}

fn clipboard_get() -> Option<String> {
    unsafe {
        if OpenClipboard(None).is_err() {
            return None;
        }
        let result = GetClipboardData(CF_UNICODETEXT_ID).ok().and_then(|h| {
            let hmem = HGLOBAL(h.0 as *mut c_void);
            let ptr = GlobalLock(hmem) as *const u16;
            if ptr.is_null() {
                return None;
            }
            let mut len = 0;
            while *ptr.add(len) != 0 {
                len += 1;
            }
            let s = String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len));
            let _ = GlobalUnlock(hmem);
            Some(s)
        });
        let _ = CloseClipboard();
        result
    }
}

// ── Paste ──

fn paste_from_clipboard() {
    let Some(state) = ENGINE.get() else { return };
    let Some(text) = clipboard_get() else { return };
    if text.is_empty() {
        return;
    }
    let normalized = text.replace("\r\n", "\r");
    unsafe {
        let check: Symbol<IsBracketedPasteFn> = state
            .lib
            .get(b"sugarloaf_win_is_bracketed_paste_enabled")
            .unwrap();
        if check(state.handle, state.terminal_id) {
            write_to_pty(b"\x1b[200~");
            write_to_pty(normalized.as_bytes());
            write_to_pty(b"\x1b[201~");
        } else {
            write_to_pty(normalized.as_bytes());
        }
    }
}

// ── Scroll ──

fn scroll_terminal(delta: i32) {
    let Some(state) = ENGINE.get() else { return };
    unsafe {
        let scroll: Symbol<ScrollFn> = state.lib.get(b"sugarloaf_win_scroll").unwrap();
        scroll(state.handle, state.terminal_id, delta);
    }
}

// ── Keyboard ──

fn handle_vk(vk: u16, shift: bool, ctrl: bool, alt: bool) -> bool {
    if ctrl {
        let byte = match vk {
            0x41..=0x5A => Some(vk as u8 - 0x40),
            0xBE => Some(0x1C),
            0xDB => Some(0x1B),
            0xDD => Some(0x1D),
            _ => None,
        };
        if let Some(b) = byte {
            write_to_pty(&[b]);
            return true;
        }
    }

    let seq: Option<&[u8]> = match vk {
        k if k == VK_UP.0 => Some(if alt { b"\x1b[1;3A" } else if ctrl { b"\x1b[1;5A" } else if shift { b"\x1b[1;2A" } else { b"\x1b[A" }),
        k if k == VK_DOWN.0 => Some(if alt { b"\x1b[1;3B" } else if ctrl { b"\x1b[1;5B" } else if shift { b"\x1b[1;2B" } else { b"\x1b[B" }),
        k if k == VK_RIGHT.0 => Some(if alt { b"\x1b[1;3C" } else if ctrl { b"\x1b[1;5C" } else if shift { b"\x1b[1;2C" } else { b"\x1b[C" }),
        k if k == VK_LEFT.0 => Some(if alt { b"\x1b[1;3D" } else if ctrl { b"\x1b[1;5D" } else if shift { b"\x1b[1;2D" } else { b"\x1b[D" }),
        k if k == VK_HOME.0 => Some(if ctrl { b"\x1b[1;5H" } else { b"\x1b[H" }),
        k if k == VK_END.0 => Some(if ctrl { b"\x1b[1;5F" } else { b"\x1b[F" }),
        k if k == VK_INSERT.0 => Some(b"\x1b[2~"),
        k if k == VK_DELETE.0 => Some(b"\x1b[3~"),
        k if k == VK_PRIOR.0 => Some(b"\x1b[5~"),
        k if k == VK_NEXT.0 => Some(b"\x1b[6~"),
        k if k == VK_F1.0 => Some(b"\x1bOP"),
        k if k == VK_F2.0 => Some(b"\x1bOQ"),
        k if k == VK_F3.0 => Some(b"\x1bOR"),
        k if k == VK_F4.0 => Some(b"\x1bOS"),
        k if k == VK_F5.0 => Some(b"\x1b[15~"),
        k if k == VK_F6.0 => Some(b"\x1b[17~"),
        k if k == VK_F7.0 => Some(b"\x1b[18~"),
        k if k == VK_F8.0 => Some(b"\x1b[19~"),
        k if k == VK_F9.0 => Some(b"\x1b[20~"),
        k if k == VK_F10.0 => Some(b"\x1b[21~"),
        k if k == VK_F11.0 => Some(b"\x1b[23~"),
        k if k == VK_F12.0 => Some(b"\x1b[24~"),
        k if k == VK_BACK.0 => Some(if alt { b"\x1b\x7f" } else { b"\x7f" }),
        k if k == VK_TAB.0 => Some(if shift { b"\x1b[Z" } else { b"\t" }),
        k if k == VK_RETURN.0 => Some(b"\r"),
        k if k == VK_ESCAPE.0 => Some(b"\x1b"),
        _ => None,
    };

    if let Some(s) = seq {
        write_to_pty(s);
        true
    } else {
        false
    }
}

// ── Window procedure ──

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CHAR => {
            if let Some(c) = char::from_u32(wparam.0 as u32) {
                if c as u32 >= 0x20 {
                    let mut buf = [0u8; 4];
                    let s = c.encode_utf8(&mut buf);
                    write_to_pty(s.as_bytes());
                }
            }
            LRESULT(0)
        }
        WM_KEYDOWN | WM_SYSKEYDOWN => {
            let vk = (wparam.0 & 0xFFFF) as u16;
            let ctrl = unsafe { GetKeyState(VK_CONTROL.0 as i32) } < 0;
            let shift = unsafe { GetKeyState(VK_SHIFT.0 as i32) } < 0;
            let alt =
                msg == WM_SYSKEYDOWN || unsafe { GetKeyState(VK_MENU.0 as i32) } < 0;

            if ctrl && !shift && !alt && vk == 0x43 {
                if try_copy_selection() {
                    return LRESULT(0);
                }
            }

            if ctrl && !shift && !alt && vk == 0x56 {
                paste_from_clipboard();
                return LRESULT(0);
            }

            if handle_vk(vk, shift, ctrl, alt) {
                return LRESULT(0);
            }

            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        WM_LBUTTONDOWN => {
            let x = (lparam.0 & 0xFFFF) as i16 as i32;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
            start_selection(hwnd, x, y);
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            if wparam.0 & 0x0001 != 0 {
                let x = (lparam.0 & 0xFFFF) as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
                update_selection(x, y);
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            end_selection();
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let raw = ((wparam.0 >> 16) & 0xFFFF) as i16 as i32;
            let accum = WHEEL_ACCUM.load(Ordering::Relaxed) + raw;
            let ticks = accum / 120;
            WHEEL_ACCUM.store(accum - ticks * 120, Ordering::Relaxed);
            let lines = ticks * 3;
            if lines != 0 {
                scroll_terminal(lines);
            }
            LRESULT(0)
        }
        WM_IME_STARTCOMPOSITION => {
            if let Some(state) = ENGINE.get() {
                unsafe {
                    let get_cursor: Symbol<GetCursorPosFn> = state
                        .lib
                        .get(b"sugarloaf_win_get_cursor_pos")
                        .unwrap();
                    let pos = get_cursor(state.handle, state.terminal_id);
                    let x = (pos.col as f32 * cell_w()) as i32;
                    let y = ((pos.row + 1) as f32 * cell_h()) as i32;

                    let himc = ImmGetContext(hwnd);
                    if !himc.0.is_null() {
                        let cf = COMPOSITIONFORM {
                            dwStyle: CFS_POINT,
                            ptCurrentPos: POINT { x, y },
                            ..Default::default()
                        };
                        let _ = ImmSetCompositionWindow(himc, &cf);
                        let _ = ImmReleaseContext(hwnd, himc);
                    }
                }
            }
            LRESULT(0)
        }
        WM_SIZE => {
            let width = (lparam.0 & 0xFFFF) as u16;
            let height = ((lparam.0 >> 16) & 0xFFFF) as u16;
            if width > 0 && height > 0 {
                if let Some(state) = ENGINE.get() {
                    unsafe {
                        let resize_renderer: Symbol<ResizeRendererFn> = state
                            .lib
                            .get(b"sugarloaf_win_resize_renderer")
                            .unwrap();
                        resize_renderer(state.handle, width as f32, height as f32);
                    }

                    update_font_metrics(state);

                    let cols = (width as f32 / cell_w()) as u16;
                    let rows = (height as f32 / cell_h()) as u16;
                    if cols > 0 && rows > 0 {
                        unsafe {
                            let resize: Symbol<ResizeFn> =
                                state.lib.get(b"sugarloaf_win_resize").unwrap();
                            resize(
                                state.handle,
                                state.terminal_id,
                                cols,
                                rows,
                                width,
                                height,
                            );
                        }
                    }
                }
            }
            LRESULT(0)
        }
        WM_TIMER => {
            if wparam.0 == TIMER_RENDER {
                if let Some(state) = ENGINE.get() {
                    unsafe {
                        let render: Symbol<RenderFn> =
                            state.lib.get(b"sugarloaf_win_render").unwrap();
                        render(state.handle);
                    }
                }
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            unsafe {
                let _ = KillTimer(Some(hwnd), TIMER_RENDER);
                if let Some(state) = ENGINE.get() {
                    let close: Symbol<CloseTerminalFn> = state
                        .lib
                        .get(b"sugarloaf_win_close_terminal")
                        .unwrap();
                    close(state.handle, state.terminal_id);

                    let destroy: Symbol<DestroyFn> =
                        state.lib.get(b"sugarloaf_win_destroy").unwrap();
                    destroy(state.handle);
                }
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => {
            if (0x020A..=0x020E).contains(&msg) {
                println!(
                    "[mouse-ext] msg=0x{:04X} wparam=0x{:X} lparam=0x{:X}",
                    msg, wparam.0, lparam.0
                );
            }
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
    }
}

fn main() {
    let lib = unsafe { Library::new("D:/dev/rio/target/release/sugarloaf_ffi_win.dll") }
        .expect("Failed to load sugarloaf_ffi_win.dll");

    let handle: *mut c_void;
    let terminal_id: i32;

    unsafe {
        let init: Symbol<InitFn> = lib.get(b"sugarloaf_win_init").unwrap();
        handle = init();
        assert!(!handle.is_null(), "sugarloaf_win_init returned null");
    }
    println!("Engine initialized");

    let hmodule = unsafe { GetModuleHandleW(windows::core::PCWSTR::null()).unwrap() };
    let hinstance = HINSTANCE(hmodule.0);
    let class_name = windows::core::w!("ETermWin");
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wndproc),
        hInstance: hinstance,
        lpszClassName: class_name,
        hCursor: unsafe { LoadCursorW(None, IDC_IBEAM).unwrap_or_default() },
        ..Default::default()
    };
    assert!(unsafe { RegisterClassExW(&wc) } != 0);

    let init_w: i32 = 960;
    let init_h: i32 = 640;
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            windows::core::w!("ETerm"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            init_w,
            init_h,
            None,
            None,
            Some(hinstance),
            None,
        )
    }
    .expect("CreateWindowExW");
    println!("Window created: {:?}", hwnd);

    unsafe {
        let init_renderer: Symbol<InitRendererFn> =
            lib.get(b"sugarloaf_win_init_renderer").unwrap();
        let rc = init_renderer(
            handle,
            hwnd.0 as *mut c_void,
            init_w as f32,
            init_h as f32,
            1.0,
        );
        assert_eq!(rc, 0, "init_renderer failed: {}", rc);
    }
    println!("Renderer initialized");

    unsafe {
        let mut metrics = FontMetrics {
            cell_width: 8.0,
            cell_height: 16.0,
            line_height: 16.0,
        };
        let get_metrics: Symbol<GetFontMetricsFn> =
            lib.get(b"sugarloaf_win_get_font_metrics").unwrap();
        let rc = get_metrics(handle, &mut metrics);
        if rc == 0 {
            println!(
                "Font metrics: cell_width={:.1}, cell_height={:.1}, line_height={:.1}",
                metrics.cell_width, metrics.cell_height, metrics.line_height
            );
            CELL_W.store(metrics.cell_width.to_bits(), Ordering::Relaxed);
            CELL_H.store(metrics.line_height.to_bits(), Ordering::Relaxed);
        } else {
            eprintln!("get_font_metrics failed ({}), using defaults 8x16", rc);
            CELL_W.store(8.0f32.to_bits(), Ordering::Relaxed);
            CELL_H.store(16.0f32.to_bits(), Ordering::Relaxed);
        }
    }

    let cols = (init_w as f32 / cell_w()) as u16;
    let rows = (init_h as f32 / cell_h()) as u16;
    unsafe {
        let create_terminal: Symbol<CreateTerminalFn> =
            lib.get(b"sugarloaf_win_create_terminal").unwrap();
        terminal_id = create_terminal(handle, cols, rows);
        assert!(terminal_id > 0, "create_terminal failed: {}", terminal_id);
    }
    println!(
        "Terminal created: id={}, {}x{} (cell {:.0}x{:.0})",
        terminal_id, cols, rows, cell_w(), cell_h()
    );

    ENGINE
        .set(EngineState {
            handle,
            terminal_id,
            lib,
        })
        .expect("ENGINE already set");

    unsafe {
        let _ = SetTimer(Some(hwnd), TIMER_RENDER, 16, None);
    }

    println!("Running. Close the window to exit.");
    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    println!("Exited cleanly.");
}
