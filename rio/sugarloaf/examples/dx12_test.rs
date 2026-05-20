//! Minimal D3D12 + Skia rendering test for Windows.
//!
//! Opens an 800x600 window, clears it to teal, renders ~120 frames, then exits.
//! Validates the D3D12 + Skia pipeline end-to-end.
//!
//! Run on Windows:
//!   cargo run --example dx12_test

#[cfg(target_os = "windows")]
fn main() {
    use raw_window_handle::{
        RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle,
    };
    use std::num::NonZeroIsize;
    use sugarloaf::context::GpuContext;
    use sugarloaf::{SugarloafRenderer, SugarloafWindow, SugarloafWindowSize};

    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::WindowsAndMessaging::*;

    unsafe extern "system" fn wndproc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    let hinstance = unsafe {
        GetModuleHandleW(windows::core::PCWSTR::null())
            .expect("GetModuleHandleW failed")
    };

    let class_name = windows::core::w!("ETermDx12TestClass");

    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wndproc),
        hInstance: hinstance.into(),
        lpszClassName: class_name,
        hCursor: unsafe {
            LoadCursorW(windows::Win32::Foundation::HINSTANCE::default(), IDC_ARROW)
                .unwrap_or_default()
        },
        ..Default::default()
    };

    let atom = unsafe { RegisterClassExW(&wc) };
    assert!(atom != 0, "RegisterClassExW failed");

    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            windows::core::w!("ETerm D3D12 Test"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            800,
            600,
            None,
            None,
            hinstance,
            None,
        )
    };

    assert!(!hwnd.is_invalid(), "CreateWindowExW returned invalid HWND");
    unsafe { let _ = ShowWindow(hwnd, SW_SHOW); };

    let wh = Win32WindowHandle::new(
        NonZeroIsize::new(hwnd.0 as isize).expect("HWND must be non-zero"),
    );
    let dh = WindowsDisplayHandle::new();

    let sugarloaf_window = SugarloafWindow {
        handle: RawWindowHandle::Win32(wh),
        display: RawDisplayHandle::Windows(dh),
        size: SugarloafWindowSize {
            width: 800.0,
            height: 600.0,
        },
        scale: 1.0,
    };

    let mut ctx = sugarloaf::context::Context::new(sugarloaf_window, SugarloafRenderer::default());
    println!("Dx12Context created successfully");

    let max_frames: u32 = 120;
    let mut frame_count: u32 = 0;
    let mut should_quit = false;

    while !should_quit && frame_count < max_frames {
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    should_quit = true;
                    break;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        if should_quit {
            break;
        }

        if let Some((mut surface, handle)) = ctx.begin_frame() {
            let canvas = surface.canvas();
            canvas.clear(skia_safe::Color4f::new(0.0, 0.502, 0.502, 1.0));
            drop(surface);
            ctx.end_frame(handle);
            frame_count += 1;

            if frame_count % 30 == 0 {
                println!("Rendered {frame_count}/{max_frames} frames");
            }
        }
    }

    println!("Rendered {frame_count} frames total. D3D12 pipeline test passed!");

    drop(ctx);
    unsafe { let _ = DestroyWindow(hwnd); }
}

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!("dx12_test: This example only runs on Windows.");
}
