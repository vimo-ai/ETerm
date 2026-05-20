//! Windows frame pacer — replacement for macOS CVDisplayLink
//!
//! On macOS, CVDisplayLink delivers a hardware VSync callback.
//! Windows has no direct equivalent, so we emulate it with a dedicated
//! thread that sleeps at the monitor's refresh interval using a
//! high-resolution waitable timer (`CreateWaitableTimerExW` with
//! `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`).
//!
//! Fallback: if the high-resolution timer is unavailable (pre-Windows 10
//! 1803), we fall back to `DwmFlush()` which blocks until the next DWM
//! composition cycle.

#![allow(non_upper_case_globals)]
#![allow(non_snake_case)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

// ============================================================================
// Windows API bindings (minimal, no winapi/windows crate dependency)
// ============================================================================

type HANDLE = *mut std::ffi::c_void;
type BOOL = i32;
type DWORD = u32;
type LONG = i32;
type WORD = u16;
type LARGE_INTEGER = i64;
type LPCWSTR = *const u16;

const INVALID_HANDLE_VALUE: HANDLE = -1_isize as HANDLE;
const INFINITE: DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: DWORD = 0;
const WAIT_FAILED: DWORD = 0xFFFFFFFF;
const FALSE: BOOL = 0;
const TRUE: BOOL = 1;
const TIMER_ALL_ACCESS: DWORD = 0x1F0003;
const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x00000002;

// DEVMODEW — only the fields we need (dmSize, dmPelsWidth, dmPelsHeight,
// dmDisplayFrequency). The full struct is 220+ bytes; we declare it at
// full size so offsets are correct.
#[repr(C)]
#[derive(Clone, Copy)]
struct DEVMODEW {
    dmDeviceName: [u16; 32],
    dmSpecVersion: WORD,
    dmDriverVersion: WORD,
    dmSize: WORD,
    dmDriverExtra: WORD,
    dmFields: DWORD,
    // Union area (position / display orientation / etc.) — 16 bytes
    _union1: [u8; 16],
    dmColor: i16,
    dmDuplex: i16,
    dmYResolution: i16,
    dmTTOption: i16,
    dmCollate: i16,
    dmFormName: [u16; 32],
    dmLogPixels: WORD,
    dmBitsPerPel: DWORD,
    dmPelsWidth: DWORD,
    dmPelsHeight: DWORD,
    // Union area (dmDisplayFlags / dmNup) — 4 bytes
    _union2: [u8; 4],
    dmDisplayFrequency: DWORD,
    // Remaining fields (ICM, media, dither, reserved) — we zero-pad
    _rest: [u8; 64],
}

impl Default for DEVMODEW {
    fn default() -> Self {
        let mut dm: DEVMODEW = unsafe { std::mem::zeroed() };
        dm.dmSize = std::mem::size_of::<DEVMODEW>() as WORD;
        dm
    }
}

const ENUM_CURRENT_SETTINGS: DWORD = 0xFFFFFFFF;

extern "system" {
    // Display settings
    fn EnumDisplaySettingsW(
        lpszDeviceName: LPCWSTR,
        iModeNum: DWORD,
        lpDevMode: *mut DEVMODEW,
    ) -> BOOL;

    // Waitable timer
    fn CreateWaitableTimerExW(
        lpTimerAttributes: *mut std::ffi::c_void,
        lpTimerName: LPCWSTR,
        dwFlags: DWORD,
        dwDesiredAccess: DWORD,
    ) -> HANDLE;

    fn SetWaitableTimer(
        hTimer: HANDLE,
        lpDueTime: *const LARGE_INTEGER,
        lPeriod: LONG,
        pfnCompletionRoutine: *const std::ffi::c_void,
        lpArgToCompletionRoutine: *mut std::ffi::c_void,
        fResume: BOOL,
    ) -> BOOL;

    fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) -> DWORD;

    fn CloseHandle(hObject: HANDLE) -> BOOL;

    fn CancelWaitableTimer(hTimer: HANDLE) -> BOOL;

    // DWM fallback
    fn DwmFlush() -> i32; // HRESULT

    // Events for signalling the thread to stop
    fn CreateEventW(
        lpEventAttributes: *mut std::ffi::c_void,
        bManualReset: BOOL,
        bInitialState: BOOL,
        lpName: LPCWSTR,
    ) -> HANDLE;

    fn SetEvent(hEvent: HANDLE) -> BOOL;

    fn WaitForMultipleObjects(
        nCount: DWORD,
        lpHandles: *const HANDLE,
        bWaitAll: BOOL,
        dwMilliseconds: DWORD,
    ) -> DWORD;
}

// ============================================================================
// Helper: query display refresh rate
// ============================================================================

/// Query the primary display's refresh rate in Hz.
/// Returns 60 if the query fails or returns 0/1 (some drivers report 0 or 1
/// for "default").
fn query_refresh_rate() -> u32 {
    let mut devmode = DEVMODEW::default();
    let ok = unsafe {
        EnumDisplaySettingsW(std::ptr::null(), ENUM_CURRENT_SETTINGS, &mut devmode)
    };
    if ok != 0 && devmode.dmDisplayFrequency > 1 {
        devmode.dmDisplayFrequency
    } else {
        60
    }
}

// ============================================================================
// Frame pacer strategy
// ============================================================================

/// Strategy used by the worker thread to pace frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PacerStrategy {
    /// High-resolution waitable timer (Windows 10 1803+).
    HighResTimer,
    /// DwmFlush fallback (blocks until next DWM composition).
    DwmFlush,
}

// ============================================================================
// DisplayLinkWin
// ============================================================================

/// Windows frame pacer — drop-in replacement for macOS `DisplayLink`.
///
/// # Usage
/// ```ignore
/// let dl = DisplayLinkWin::new(|| {
///     // called once per VSync interval
///     if should_render() { render(); }
/// });
/// dl.start();
/// // ...
/// dl.stop();
/// ```
pub struct DisplayLinkWin {
    /// Shared flag: set to `true` to signal the worker thread to exit.
    done: Arc<AtomicBool>,
    /// Win32 manual-reset event — signalled to wake the thread immediately
    /// when `done` is set.
    stop_event: HANDLE,
    /// Worker thread handle.
    thread: Option<thread::JoinHandle<()>>,
    /// Whether the loop is currently running.
    running: Arc<AtomicBool>,
}

// Safety: HANDLE values are plain pointers into the kernel object table and
// can be sent/shared across threads.  The callback stored in the worker
// thread closure is `Send + Sync`.
unsafe impl Send for DisplayLinkWin {}
unsafe impl Sync for DisplayLinkWin {}

impl DisplayLinkWin {
    /// Create a new `DisplayLinkWin`.
    ///
    /// The frame pacer thread is created but **not** started — call
    /// [`start`](Self::start) to begin invoking the callback.
    ///
    /// Returns `None` if the Win32 event object cannot be created.
    pub fn new<F>(callback: F) -> Option<Self>
    where
        F: Fn() + Send + Sync + 'static,
    {
        // Create a manual-reset event (unsignalled).
        let stop_event =
            unsafe { CreateEventW(std::ptr::null_mut(), TRUE, FALSE, std::ptr::null()) };
        if stop_event.is_null() || stop_event == INVALID_HANDLE_VALUE {
            crate::rust_log_error!("[RenderLoop] Failed to create Win32 stop event");
            return None;
        }

        let done = Arc::new(AtomicBool::new(false));
        let running = Arc::new(AtomicBool::new(false));

        let done_clone = done.clone();
        let running_clone = running.clone();
        // HANDLE is a pointer-sized value; cloning it is fine.
        let stop_event_for_thread = stop_event;

        let callback = Arc::new(callback);

        let thread = thread::Builder::new()
            .name("display-link-win".into())
            .spawn(move || {
                Self::worker_loop(
                    done_clone,
                    running_clone,
                    stop_event_for_thread,
                    callback,
                );
            })
            .ok()?;

        Some(Self {
            done,
            stop_event,
            thread: Some(thread),
            running,
        })
    }

    /// Start the frame pacer.  The callback will be invoked once per
    /// display refresh interval until [`stop`](Self::stop) is called.
    pub fn start(&self) -> bool {
        if self.done.load(Ordering::SeqCst) {
            return false;
        }
        self.running.store(true, Ordering::SeqCst);
        crate::rust_log_info!("[RenderLoop] DisplayLinkWin started");
        true
    }

    /// Stop the frame pacer.  The callback will no longer be invoked,
    /// but the worker thread stays alive so `start` can resume it.
    pub fn stop(&self) -> bool {
        self.running.store(false, Ordering::SeqCst);
        true
    }

    /// No-op — matches macOS `DisplayLink::request_render`.
    /// Dirty checking is the caller's responsibility.
    #[inline]
    pub fn request_render(&self) {
        // intentionally empty
    }

    // -----------------------------------------------------------------------
    // Worker thread
    // -----------------------------------------------------------------------

    fn worker_loop(
        done: Arc<AtomicBool>,
        running: Arc<AtomicBool>,
        stop_event: HANDLE,
        callback: Arc<dyn Fn() + Send + Sync>,
    ) {
        let refresh_rate = query_refresh_rate();
        // Interval in 100-ns ticks (negative = relative).
        let interval_100ns: i64 = -(10_000_000i64 / refresh_rate as i64);

        // Try to create a high-resolution waitable timer.
        let (strategy, timer_handle) = {
            let h = unsafe {
                CreateWaitableTimerExW(
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                    TIMER_ALL_ACCESS,
                )
            };
            if !h.is_null() && h != INVALID_HANDLE_VALUE {
                (PacerStrategy::HighResTimer, Some(h))
            } else {
                crate::rust_log_info!(
                    "[RenderLoop] High-res timer unavailable, falling back to DwmFlush"
                );
                (PacerStrategy::DwmFlush, None)
            }
        };

        crate::rust_log_info!(
            "[RenderLoop] DisplayLinkWin worker: {}Hz, strategy={:?}",
            refresh_rate,
            strategy
        );

        while !done.load(Ordering::SeqCst) {
            // If not running, sleep briefly and re-check.
            if !running.load(Ordering::SeqCst) {
                // Wait on the stop event with a 50ms timeout so we
                // re-check `running` promptly when `start()` is called.
                unsafe {
                    WaitForSingleObject(stop_event, 50);
                }
                continue;
            }

            match strategy {
                PacerStrategy::HighResTimer => {
                    let timer = timer_handle.unwrap();

                    // Arm the timer for one interval from now.
                    let ok = unsafe {
                        SetWaitableTimer(
                            timer,
                            &interval_100ns,
                            0, // no periodic repeat — we re-arm each iteration
                            std::ptr::null(),
                            std::ptr::null_mut(),
                            FALSE,
                        )
                    };
                    if ok == 0 {
                        // SetWaitableTimer failed — fall back to a plain sleep
                        // to avoid a busy loop.
                        thread::sleep(std::time::Duration::from_millis(
                            (1000 / refresh_rate) as u64,
                        ));
                        (callback)();
                        continue;
                    }

                    // Wait for either the timer or the stop event.
                    let handles: [HANDLE; 2] = [timer, stop_event];
                    let result = unsafe {
                        WaitForMultipleObjects(2, handles.as_ptr(), FALSE, INFINITE)
                    };

                    if result == WAIT_OBJECT_0 {
                        // Timer fired — invoke callback.
                        (callback)();
                    }
                    // WAIT_OBJECT_0 + 1 => stop_event signalled, loop will
                    // re-check `done`.
                }
                PacerStrategy::DwmFlush => {
                    // DwmFlush blocks until the next DWM composition cycle.
                    let hr = unsafe { DwmFlush() };
                    if hr < 0 {
                        // DWM not available (e.g., compositing disabled).
                        // Fall back to a timed sleep.
                        thread::sleep(std::time::Duration::from_millis(
                            (1000 / refresh_rate) as u64,
                        ));
                    }

                    if done.load(Ordering::SeqCst) {
                        break;
                    }

                    if running.load(Ordering::SeqCst) {
                        (callback)();
                    }
                }
            }
        }

        // Cleanup timer handle.
        if let Some(h) = timer_handle {
            unsafe {
                CancelWaitableTimer(h);
                CloseHandle(h);
            }
        }
    }
}

impl Drop for DisplayLinkWin {
    fn drop(&mut self) {
        // Signal the worker thread to exit.
        self.done.store(true, Ordering::SeqCst);
        self.running.store(false, Ordering::SeqCst);

        // Wake the thread if it is blocked on WaitForSingleObject /
        // WaitForMultipleObjects.
        unsafe {
            SetEvent(self.stop_event);
        }

        // Join the thread.
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }

        // Close the stop event.
        unsafe {
            CloseHandle(self.stop_event);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn test_display_link_creation() {
        let call_count = Arc::new(AtomicUsize::new(0));
        let call_count_clone = call_count.clone();

        let display_link = DisplayLinkWin::new(move || {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        });

        assert!(display_link.is_some());
    }

    #[test]
    fn test_display_link_start_stop() {
        let display_link = DisplayLinkWin::new(|| {}).unwrap();

        assert!(display_link.start());
        thread::sleep(Duration::from_millis(100));
        assert!(display_link.stop());
    }

    #[test]
    fn test_display_link_request_render() {
        let call_count = Arc::new(AtomicUsize::new(0));
        let call_count_clone = call_count.clone();

        let display_link = DisplayLinkWin::new(move || {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        })
        .unwrap();

        display_link.start();

        // request_render is a no-op, same as macOS
        display_link.request_render();
        thread::sleep(Duration::from_millis(50));

        display_link.stop();

        // Should have been called at least once
        assert!(call_count.load(Ordering::SeqCst) >= 1);
    }

    #[test]
    fn test_display_link_drop_while_running() {
        let call_count = Arc::new(AtomicUsize::new(0));
        let call_count_clone = call_count.clone();

        let display_link = DisplayLinkWin::new(move || {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        })
        .unwrap();

        display_link.start();
        thread::sleep(Duration::from_millis(50));

        // Drop while running — must not hang or crash.
        drop(display_link);

        // If we reach here, the drop completed cleanly.
    }

    #[test]
    fn test_query_refresh_rate() {
        let rate = query_refresh_rate();
        // Should be a sane value (30..=360 Hz covers all common displays).
        assert!(
            rate >= 30 && rate <= 360,
            "unexpected refresh rate: {}",
            rate
        );
    }
}
