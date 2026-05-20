//! Windows FFI layer for ETerm terminal
//!
//! Provides C ABI functions for terminal lifecycle + rendering using ConPTY
//! and the Sugarloaf D3D12 backend.

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::io::Write;
use std::num::NonZeroIsize;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use raw_window_handle::{RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle};
use sugarloaf::context::GpuContext;
use sugarloaf::{Sugarloaf, SugarloafRenderer, SugarloafWindow, SugarloafWindowSize};
use sugarloaf::font::FontLibrary;
use sugarloaf::layout::RootStyle;
use teletypewriter::windows::{create_pty, Pty};
use teletypewriter::{ProcessReadWrite, WinsizeBuilder};

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
    pty: Pty,
    title: String,
}

struct WinEngine {
    terminals: HashMap<i32, Terminal>,
    next_id: i32,
    sugarloaf: Option<Sugarloaf>,
    font_library: FontLibrary,
}

impl WinEngine {
    fn new() -> Self {
        Self {
            terminals: HashMap::new(),
            next_id: 1,
            sugarloaf: None,
            font_library: FontLibrary::default(),
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
        let _ = Box::from_raw(handle as *mut WinEngine);
    });
}

/// Initialize the D3D12 rendering surface for a given Win32 HWND.
///
/// Must be called before `sugarloaf_win_render`. The `hwnd` is the native
/// window handle (HWND cast to void*), and `width`/`height` are the initial
/// viewport size in logical pixels.
///
/// Returns `FFI_OK` on success.
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
            Ok(sugarloaf) => {
                engine.sugarloaf = Some(sugarloaf);
                tracing::info!("Renderer initialized: {}x{} @ {:.1}x", width, height, scale);
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

        match create_pty("powershell.exe", vec![], &None, cols, rows) {
            Ok(pty) => {
                let id = engine.next_id;
                engine.next_id += 1;
                engine.terminals.insert(
                    id,
                    Terminal {
                        pty,
                        title: format!("Terminal {}", id),
                    },
                );
                id
            }
            Err(e) => {
                eprintln!("[sugarloaf-ffi-win] create_terminal failed: {:?}", e);
                FFI_ERR_IO
            }
        }
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
            Some(_) => FFI_OK,
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

        match engine.terminals.get_mut(&terminal_id) {
            Some(terminal) => {
                let writer = terminal.pty.writer();
                match writer.write_all(bytes) {
                    Ok(()) => FFI_OK,
                    Err(e) => {
                        eprintln!(
                            "[sugarloaf-ffi-win] write failed (id={}): {:?}",
                            terminal_id, e
                        );
                        FFI_ERR_IO
                    }
                }
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
                let winsize = WinsizeBuilder {
                    rows,
                    cols,
                    width,
                    height,
                };
                match terminal.pty.set_winsize(winsize) {
                    Ok(()) => FFI_OK,
                    Err(e) => {
                        eprintln!(
                            "[sugarloaf-ffi-win] resize failed (id={}): {:?}",
                            terminal_id, e
                        );
                        FFI_ERR_IO
                    }
                }
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

/// Render a single frame using the D3D12 Sugarloaf backend.
///
/// The renderer must have been initialized via `sugarloaf_win_init_renderer`.
/// Returns `FFI_OK` on success, or `FFI_ERR_RENDER` if the renderer is not
/// initialized or the frame fails.
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

        sugarloaf.render();
        FFI_OK
    })
}

/// Resize the rendering surface (call when the window is resized).
///
/// Returns `FFI_OK` on success.
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
        if let Some(sugarloaf) = engine.sugarloaf.as_mut() {
            sugarloaf.resize(width as u32, height as u32);
        }
        FFI_OK
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
                CString::new(terminal.title.as_str())
                    .map(|cs| cs.into_raw())
                    .unwrap_or(std::ptr::null_mut())
            }
            None => std::ptr::null_mut(),
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
