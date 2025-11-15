use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use sugarloaf::{
    font::{FontLibrary, fonts::{SugarloafFonts, SugarloafFont, SugarloafFontStyle}},
    layout::RootStyle, FragmentStyle, Sugarloaf, SugarloafRenderer,
    SugarloafWindow, SugarloafWindowSize,
};

// 终端模块
mod terminal;
pub use terminal::*;

/// Opaque pointer to Sugarloaf instance
pub struct SugarloafHandle {
    instance: Sugarloaf<'static>,
    current_rt_id: Option<usize>,
}

/// Initialize Sugarloaf
#[no_mangle]
pub extern "C" fn sugarloaf_new(
    window_handle: *mut c_void,
    _display_handle: *mut c_void,
    width: f32,
    height: f32,
    scale: f32,
    font_size: f32,
) -> *mut SugarloafHandle {
    // 验证输入
    if window_handle.is_null() {
        eprintln!("[Sugarloaf FFI] Error: window_handle is null");
        return ptr::null_mut();
    }

    if width <= 0.0 || height <= 0.0 {
        eprintln!("[Sugarloaf FFI] Error: invalid dimensions {}x{}", width, height);
        return ptr::null_mut();
    }

    eprintln!("[Sugarloaf FFI] Initializing with:");
    eprintln!("  - window_handle: {:?}", window_handle);
    eprintln!("  - dimensions: {}x{}", width, height);
    eprintln!("  - scale: {}", scale);

    // 创建 raw window handle (这里需要根据平台处理)
    #[cfg(target_os = "macos")]
    let raw_window_handle = {
        use raw_window_handle::{AppKitWindowHandle, RawWindowHandle};
        match std::ptr::NonNull::new(window_handle) {
            Some(nn_ptr) => {
                let handle = AppKitWindowHandle::new(nn_ptr);
                RawWindowHandle::AppKit(handle)
            }
            None => {
                eprintln!("[Sugarloaf FFI] Error: Failed to create NonNull pointer");
                return ptr::null_mut();
            }
        }
    };

    #[cfg(target_os = "macos")]
    let raw_display_handle = {
        use raw_window_handle::{AppKitDisplayHandle, RawDisplayHandle};
        RawDisplayHandle::AppKit(AppKitDisplayHandle::new())
    };

    let window = SugarloafWindow {
        handle: raw_window_handle,
        display: raw_display_handle,
        size: SugarloafWindowSize { width, height },
        scale,
    };

    let renderer = SugarloafRenderer::default();

    // 创建字体配置（添加中文字体支持）
    eprintln!("[Sugarloaf FFI] Creating font library with CJK support...");

    let font_spec = SugarloafFonts {
        family: Some("Maple Mono NF CN".to_string()),
        size: font_size,
        hinting: true,
        regular: SugarloafFont {
            family: "Maple Mono NF CN".to_string(),
            weight: Some(400),
            style: SugarloafFontStyle::Normal,
            width: None,
        },
        bold: SugarloafFont {
            family: "Maple Mono NF CN".to_string(),
            weight: Some(700),
            style: SugarloafFontStyle::Normal,
            width: None,
        },
        italic: SugarloafFont {
            family: "Maple Mono NF CN".to_string(),
            weight: Some(400),
            style: SugarloafFontStyle::Italic,
            width: None,
        },
        bold_italic: SugarloafFont {
            family: "Maple Mono NF CN".to_string(),
            weight: Some(700),
            style: SugarloafFontStyle::Italic,
            width: None,
        },
        ..Default::default()
    };

    let (font_library, font_errors) = FontLibrary::new(font_spec);

    if let Some(errors) = font_errors {
        eprintln!("[Sugarloaf FFI] ⚠️  Font warnings: {:?}", errors);
    }

    eprintln!("[Sugarloaf FFI] Font library created with CJK support");

    let layout = RootStyle {
        font_size,
        line_height: 1.5,  // 增加行高
        scale_factor: scale,
    };

    eprintln!("[Sugarloaf FFI] Layout: font_size={}, line_height=1.5, scale={}", font_size, scale);

    eprintln!("[Sugarloaf FFI] Creating Sugarloaf instance...");
    match Sugarloaf::new(window, renderer, &font_library, layout) {
        Ok(instance) => {
            eprintln!("[Sugarloaf FFI] ✅ Successfully created Sugarloaf instance (no errors)");
            let handle = Box::new(SugarloafHandle {
                instance,
                current_rt_id: None,
            });
            Box::into_raw(handle)
        }
        Err(with_errors) => {
            eprintln!("[Sugarloaf FFI] ⚠️  Created Sugarloaf instance with errors:");
            eprintln!("   {:?}", with_errors.errors);

            // 即使有错误也返回实例（Rio 的做法）
            let handle = Box::new(SugarloafHandle {
                instance: with_errors.instance,
                current_rt_id: None,
            });
            Box::into_raw(handle)
        }
    }
}

/// Create a new rich text state
#[no_mangle]
pub extern "C" fn sugarloaf_create_rich_text(handle: *mut SugarloafHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let rt_id = handle.instance.create_temp_rich_text();
    handle.current_rt_id = Some(rt_id);
    rt_id
}

/// Select a rich text state
#[no_mangle]
pub extern "C" fn sugarloaf_content_sel(handle: *mut SugarloafHandle, rt_id: usize) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.current_rt_id = Some(rt_id);
    handle.instance.content().sel(rt_id);
}

/// Clear content
#[no_mangle]
pub extern "C" fn sugarloaf_content_clear(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.instance.content().clear();
}

/// Add a new line
#[no_mangle]
pub extern "C" fn sugarloaf_content_new_line(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.instance.content().new_line();
}

/// Add text with style
#[no_mangle]
pub extern "C" fn sugarloaf_content_add_text(
    handle: *mut SugarloafHandle,
    text: *const c_char,
    fg_r: f32,
    fg_g: f32,
    fg_b: f32,
    fg_a: f32,
) {
    if handle.is_null() || text.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    let text_str = unsafe { CStr::from_ptr(text).to_str().unwrap_or("") };

    eprintln!("[Sugarloaf FFI] Adding text: '{}' with color [{}, {}, {}, {}]",
              text_str, fg_r, fg_g, fg_b, fg_a);

    let style = FragmentStyle {
        color: [fg_r, fg_g, fg_b, fg_a],
        ..FragmentStyle::default()
    };

    handle.instance.content().add_text(text_str, style);
}

/// Build content
#[no_mangle]
pub extern "C" fn sugarloaf_content_build(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.instance.content().build();
}

/// Commit rich text as an object for rendering
#[no_mangle]
pub extern "C" fn sugarloaf_commit_rich_text(handle: *mut SugarloafHandle, rt_id: usize) {
    if handle.is_null() {
        return;
    }

    use sugarloaf::{Object, RichText, Quad};

    let handle = unsafe { &mut *handle };

    // 创建 RichText 对象，位置在左上角
    let rich_text_obj = Object::RichText(RichText {
        id: rt_id,
        position: [10.0, 10.0],  // 左上角位置，留点边距
        lines: None,
    });

    eprintln!("[Sugarloaf FFI] Committing RichText object with id {} at position [10, 10]", rt_id);

    // 只设置 RichText（移除测试用的背景矩形）
    handle.instance.set_objects(vec![rich_text_obj]);
}

/// Clear the screen
#[no_mangle]
pub extern "C" fn sugarloaf_clear(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.instance.clear();
}

/// Set objects (for testing with Quads)
#[no_mangle]
pub extern "C" fn sugarloaf_set_test_objects(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    use sugarloaf::{Object, Quad};

    let handle = unsafe { &mut *handle };

    // 创建测试用的彩色矩形
    let objects = vec![
        Object::Quad(Quad {
            position: [100.0, 100.0],
            size: [200.0, 200.0],
            color: [1.0, 0.0, 0.0, 1.0], // 红色
            ..Quad::default()
        }),
        Object::Quad(Quad {
            position: [350.0, 100.0],
            size: [200.0, 200.0],
            color: [0.0, 1.0, 0.0, 1.0], // 绿色
            ..Quad::default()
        }),
        Object::Quad(Quad {
            position: [600.0, 100.0],
            size: [200.0, 200.0],
            color: [0.0, 0.0, 1.0, 1.0], // 蓝色
            ..Quad::default()
        }),
    ];

    eprintln!("[Sugarloaf FFI] Setting {} test objects (quads)", objects.len());
    handle.instance.set_objects(objects);
}

/// Render
#[no_mangle]
pub extern "C" fn sugarloaf_render(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.instance.render();
}

/// Free Sugarloaf instance
#[no_mangle]
pub extern "C" fn sugarloaf_free(handle: *mut SugarloafHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}
