//! Windows FFI layer for ETerm terminal
//!
//! Provides C ABI functions for terminal lifecycle management using ConPTY.
//! This crate is Windows-only and will not compile on other platforms.

use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use teletypewriter::windows::{create_pty, Pty};
use teletypewriter::{ProcessReadWrite, WinsizeBuilder};

// ============================================================================
// Error codes
// ============================================================================

/// Success
const FFI_OK: i32 = 0;
/// Null handle pointer
const FFI_ERR_NULL_HANDLE: i32 = -1;
/// Terminal not found
const FFI_ERR_NOT_FOUND: i32 = -2;
/// I/O error (PTY creation, write, resize)
const FFI_ERR_IO: i32 = -3;
/// Null data pointer
const FFI_ERR_NULL_DATA: i32 = -4;
/// Panic caught at FFI boundary
const FFI_ERR_PANIC: i32 = -99;

// ============================================================================
// Opaque handle
// ============================================================================

/// Opaque handle exposed to C callers.
///
/// The actual data behind the pointer is a `WinEngine`.
#[repr(C)]
pub struct SugarloafWinHandle {
    _private: [u8; 0],
}

// ============================================================================
// Internal engine state
// ============================================================================

/// Per-terminal state wrapping a ConPTY instance.
struct Terminal {
    pty: Pty,
}

/// Top-level engine that owns all terminals.
struct WinEngine {
    terminals: HashMap<i32, Terminal>,
    next_id: i32,
}

impl WinEngine {
    fn new() -> Self {
        Self {
            terminals: HashMap::new(),
            next_id: 1,
        }
    }
}

// ============================================================================
// Helper utilities
// ============================================================================

/// Convert an opaque handle pointer back to a mutable `WinEngine` reference.
///
/// # Safety
///
/// The caller must guarantee that `handle` was produced by `sugarloaf_win_init`
/// and has not yet been passed to `sugarloaf_win_destroy`.
unsafe fn engine_ref<'a>(handle: *mut SugarloafWinHandle) -> &'a mut WinEngine {
    &mut *(handle as *mut WinEngine)
}

/// FFI boundary guard -- catches panics so they never unwind across the C ABI.
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

/// Create a new `WinEngine` and return an opaque handle.
///
/// Returns a non-null pointer on success, or null on failure.
/// The caller must eventually pass the handle to `sugarloaf_win_destroy`.
#[no_mangle]
pub extern "C" fn sugarloaf_win_init() -> *mut SugarloafWinHandle {
    ffi_boundary(std::ptr::null_mut(), || {
        let engine = Box::new(WinEngine::new());
        Box::into_raw(engine) as *mut SugarloafWinHandle
    })
}

/// Destroy a `WinEngine` and all terminals it owns.
///
/// After this call the handle is invalid and must not be reused.
#[no_mangle]
pub extern "C" fn sugarloaf_win_destroy(handle: *mut SugarloafWinHandle) {
    if handle.is_null() {
        return;
    }
    ffi_boundary((), || unsafe {
        let _ = Box::from_raw(handle as *mut WinEngine);
    });
}

/// Create a new terminal backed by ConPTY running `powershell.exe`.
///
/// Returns a positive terminal ID on success, or a negative error code.
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
                engine.terminals.insert(id, Terminal { pty });
                id
            }
            Err(e) => {
                eprintln!(
                    "[sugarloaf-ffi-win] create_terminal failed: {:?}",
                    e
                );
                FFI_ERR_IO
            }
        }
    })
}

/// Close and remove a terminal by ID.
///
/// Returns `FFI_OK` (0) on success, or a negative error code.
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
            Some(_terminal) => {
                // Dropping the Terminal (and its Pty) cleans up ConPTY resources.
                FFI_OK
            }
            None => FFI_ERR_NOT_FOUND,
        }
    })
}

/// Write bytes to a terminal's PTY.
///
/// `data` must point to at least `len` bytes.
/// Returns `FFI_OK` on success, or a negative error code.
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

/// Resize a terminal's PTY.
///
/// `cols` and `rows` are the new grid dimensions.
/// `width` and `height` are the pixel dimensions of the viewport.
/// Returns `FFI_OK` on success, or a negative error code.
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

/// Render stub -- not yet implemented.
///
/// Rendering integration will come in a later phase.
/// Returns `FFI_OK`.
#[no_mangle]
pub extern "C" fn sugarloaf_win_render(handle: *mut SugarloafWinHandle) -> i32 {
    // Rendering not yet wired -- intentional no-op.
    FFI_OK
}

/// Get the title of a terminal -- not yet implemented.
///
/// Returns a null pointer (title tracking will come with rendering integration).
/// When implemented, the caller must free the returned string with
/// `sugarloaf_win_free_string`.
#[no_mangle]
pub extern "C" fn sugarloaf_win_get_title(
    handle: *mut SugarloafWinHandle,
    terminal_id: i32,
) -> *mut c_char {
    // Title tracking not yet wired -- intentional stub.
    std::ptr::null_mut()
}

/// Free a string previously returned by this library (e.g. from `sugarloaf_win_get_title`).
#[no_mangle]
pub extern "C" fn sugarloaf_win_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}
