use std::ffi::c_void;
use std::sync::OnceLock;

use libloading::{Library, Symbol};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM, HINSTANCE};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
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

const CELL_W: u16 = 8;
const CELL_H: u16 = 16;
const TIMER_RENDER: usize = 1;

#[derive(Debug)]
struct EngineState {
    handle: *mut c_void,
    terminal_id: i32,
    cols: u16,
    rows: u16,
    lib: Library,
}

unsafe impl Send for EngineState {}
unsafe impl Sync for EngineState {}

static ENGINE: OnceLock<EngineState> = OnceLock::new();

fn write_to_pty(data: &[u8]) {
    let Some(state) = ENGINE.get() else { return };
    unsafe {
        let write: Symbol<WriteFn> = state.lib.get(b"sugarloaf_win_write").unwrap();
        write(state.handle, state.terminal_id, data.as_ptr(), data.len() as u32);
    }
}

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

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CHAR => {
            let ch = char::from_u32(wparam.0 as u32);
            if let Some(c) = ch {
                if c as u32 >= 0x20 || c == '\r' || c == '\t' || c == '\x08' {
                    let mut buf = [0u8; 4];
                    let s = c.encode_utf8(&mut buf);
                    write_to_pty(s.as_bytes());
                }
            }
            LRESULT(0)
        }
        WM_KEYDOWN | WM_SYSKEYDOWN => {
            let vk = (wparam.0 & 0xFFFF) as u16;
            let shift = unsafe { GetKeyState(VK_SHIFT.0 as i32) } < 0;
            let ctrl = unsafe { GetKeyState(VK_CONTROL.0 as i32) } < 0;
            let alt = msg == WM_SYSKEYDOWN || unsafe { GetKeyState(VK_MENU.0 as i32) } < 0;

            if handle_vk(vk, shift, ctrl, alt) {
                return LRESULT(0);
            }

            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        WM_SIZE => {
            let width = (lparam.0 & 0xFFFF) as u16;
            let height = ((lparam.0 >> 16) & 0xFFFF) as u16;
            if width > 0 && height > 0 {
                if let Some(state) = ENGINE.get() {
                    let cols = width / CELL_W;
                    let rows = height / CELL_H;
                    if cols > 0 && rows > 0 {
                        unsafe {
                            let resize_renderer: Symbol<ResizeRendererFn> =
                                state.lib.get(b"sugarloaf_win_resize_renderer").unwrap();
                            resize_renderer(state.handle, width as f32, height as f32);

                            let resize: Symbol<ResizeFn> =
                                state.lib.get(b"sugarloaf_win_resize").unwrap();
                            resize(state.handle, state.terminal_id, cols, rows, width, height);
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
                    let close: Symbol<CloseTerminalFn> =
                        state.lib.get(b"sugarloaf_win_close_terminal").unwrap();
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
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
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
            CW_USEDEFAULT, CW_USEDEFAULT,
            init_w, init_h,
            None, None, Some(hinstance), None,
        )
    }.expect("CreateWindowExW");
    println!("Window created: {:?}", hwnd);

    unsafe {
        let init_renderer: Symbol<InitRendererFn> =
            lib.get(b"sugarloaf_win_init_renderer").unwrap();
        let rc = init_renderer(handle, hwnd.0 as *mut c_void, init_w as f32, init_h as f32, 1.0);
        assert_eq!(rc, 0, "init_renderer failed: {}", rc);
    }
    println!("Renderer initialized");

    let cols = init_w as u16 / CELL_W;
    let rows = init_h as u16 / CELL_H;
    unsafe {
        let create_terminal: Symbol<CreateTerminalFn> =
            lib.get(b"sugarloaf_win_create_terminal").unwrap();
        terminal_id = create_terminal(handle, cols, rows);
        assert!(terminal_id > 0, "create_terminal failed: {}", terminal_id);
    }
    println!("Terminal created: id={}, {}x{}", terminal_id, cols, rows);

    ENGINE.set(EngineState {
        handle,
        terminal_id,
        cols,
        rows,
        lib,
    }).expect("ENGINE already set");

    unsafe { let _ = SetTimer(Some(hwnd), TIMER_RENDER, 16, None); }

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
