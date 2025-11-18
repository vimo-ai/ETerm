use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use sugarloaf::{
    font::{FontLibrary, fonts::{SugarloafFonts, SugarloafFont, SugarloafFontStyle}, metrics::Metrics},
    layout::RootStyle, FragmentStyle, Sugarloaf, SugarloafRenderer,
    SugarloafWindow, SugarloafWindowSize, Object,
};
use parking_lot::RwLock;

// 终端模块
mod terminal;
pub use terminal::*;

// Context Grid 模块（Split 布局管理）
mod context_grid;
pub use context_grid::*;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SugarloafFontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub line_height: f32,
}

impl SugarloafFontMetrics {
    fn from_metrics(metrics: Metrics) -> Self {
        // 🎯 二分法: (1.875 + 2.0) / 2 = 1.9375
        Self {
            cell_width: metrics.cell_width as f32,
            cell_height: metrics.cell_height as f32,
            line_height: metrics.cell_height as f32 * 1.9375,
        }
    }

    fn fallback(font_size: f32) -> Self {
        let cell_width = font_size * 0.6;
        let cell_height = font_size * 1.2;
        Self {
            cell_width,
            cell_height,
            line_height: cell_height * 1.9375,
        }
    }
}

static GLOBAL_FONT_METRICS: RwLock<Option<SugarloafFontMetrics>> = RwLock::new(None);

pub(crate) fn set_global_font_metrics(metrics: SugarloafFontMetrics) {
    *GLOBAL_FONT_METRICS.write() = Some(metrics);
}

pub(crate) fn global_font_metrics() -> Option<SugarloafFontMetrics> {
    let guard = GLOBAL_FONT_METRICS.read();
    guard.as_ref().copied()
}

/// Opaque pointer to Sugarloaf instance
pub struct SugarloafHandle {
    instance: Sugarloaf<'static>,
    current_rt_id: Option<usize>,
    _font_library: FontLibrary,
    font_metrics: SugarloafFontMetrics,
}

impl SugarloafHandle {
    fn set_objects(&mut self, objects: Vec<Object>) {
        self.instance.set_objects(objects);
    }

    fn clear(&mut self) {
        self.instance.clear();
    }

    fn render(&mut self) {
        self.instance.render();
    }
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
        return ptr::null_mut();
    }

    if width <= 0.0 || height <= 0.0 {
        return ptr::null_mut();
    }

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
    // 🔧 指定 Maple Mono NF CN 作为主字体
    let font_spec = SugarloafFonts {
        family: Some("Maple Mono NF CN".to_string()),
        size: font_size,
        hinting: true,
        regular: SugarloafFont {
            family: "MapleMono-NF-CN-Regular".to_string(),
            weight: Some(400),
            style: SugarloafFontStyle::Normal,
            width: None,
        },
        bold: SugarloafFont {
            family: "MapleMono-NF-CN-Bold".to_string(),
            weight: Some(700),
            style: SugarloafFontStyle::Normal,
            width: None,
        },
        italic: SugarloafFont {
            family: "MapleMono-NF-CN-Italic".to_string(),
            weight: Some(400),
            style: SugarloafFontStyle::Italic,
            width: None,
        },
        bold_italic: SugarloafFont {
            family: "MapleMono-NF-CN-BoldItalic".to_string(),
            weight: Some(700),
            style: SugarloafFontStyle::Italic,
            width: None,
        },
        ..Default::default()
    };

    let (font_library, _font_errors) = FontLibrary::new(font_spec);

    let font_metrics = {
        let mut data = font_library.inner.write();
        let metrics = data.get_primary_metrics(font_size);
        eprintln!("[Sugarloaf Init] 🔍 Raw Metrics from font_library:");
        if let Some(ref m) = metrics {
            eprintln!("  cell_width: {}", m.cell_width);
            eprintln!("  cell_height: {}", m.cell_height);
            eprintln!("  cell_baseline: {}", m.cell_baseline);
        }
        metrics
            .map(SugarloafFontMetrics::from_metrics)
            .unwrap_or_else(|| SugarloafFontMetrics::fallback(font_size))
    };
    eprintln!("[Sugarloaf Init] 📊 Calculated SugarloafFontMetrics:");
    eprintln!("  cell_width: {}", font_metrics.cell_width);
    eprintln!("  cell_height: {}", font_metrics.cell_height);
    eprintln!("  line_height: {}", font_metrics.line_height);
    set_global_font_metrics(font_metrics);

    let layout = RootStyle {
        font_size,
        line_height: 1.0,  // 和 Rio 保持一致
        scale_factor: scale,
    };

    let mut instance = match Sugarloaf::new(window, renderer, &font_library, layout) {
        Ok(instance) => instance,
        Err(with_errors) => with_errors.instance,
    };

    #[cfg(target_os = "macos")]
    {
        instance.set_background_color(Some(wgpu::Color {
            r: 0.0,
            g: 0.0,
            b: 0.0,
            a: 0.0,  // 完全透明,让窗口的磨砂效果显示出来
        }));
    }

    let handle = Box::new(SugarloafHandle {
        instance,
        current_rt_id: None,
        _font_library: font_library,
        font_metrics,
    });
    Box::into_raw(handle)
}

/// Create a new rich text state
#[no_mangle]
pub extern "C" fn sugarloaf_create_rich_text(handle: *mut SugarloafHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    let handle = unsafe { &mut *handle };
    let rt_id = handle.instance.create_rich_text();
    handle.current_rt_id = Some(rt_id);
    rt_id
}

/// Returns the cached font metrics used by Sugarloaf.
#[no_mangle]
pub extern "C" fn sugarloaf_get_font_metrics(
    handle: *mut SugarloafHandle,
    out_metrics: *mut SugarloafFontMetrics,
) -> bool {
    if handle.is_null() || out_metrics.is_null() {
        return false;
    }

    let handle_ref = unsafe { &mut *handle };
    unsafe {
        *out_metrics = handle_ref.font_metrics;
    }
    true
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

    use sugarloaf::{Object, RichText};

    let handle = unsafe { &mut *handle };

    // 创建 RichText 对象，位置在左上角 (0, 0)
    let rich_text_obj = Object::RichText(RichText {
        id: rt_id,
        position: [0.0, 0.0],  // 左上角，与 Rio 终端一致
        lines: None,
    });

    eprintln!("[Sugarloaf FFI] Committing RichText object with id {} at position [0, 0]", rt_id);

    // 只设置 RichText，移除测试矩形
    handle.set_objects(vec![rich_text_obj]);
}

/// Clear the screen
#[no_mangle]
pub extern "C" fn sugarloaf_clear(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.clear();
}

/// Set objects (for testing with Quads)
#[no_mangle]
pub extern "C" fn sugarloaf_set_test_objects(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    use sugarloaf::{Object, Quad, RichText};

    let handle = unsafe { &mut *handle };

    eprintln!("[Sugarloaf FFI] Testing simple text rendering");

    // 创建 rich text
    let rt_id = handle.instance.create_temp_rich_text();
    eprintln!("[Sugarloaf FFI] Created rich text ID: {}", rt_id);

    // 选择并清空
    let content = handle.instance.content();
    content.sel(rt_id);
    content.clear();

    // 添加简单文本
    eprintln!("[Sugarloaf FFI] Adding test text");
    content.add_text("Hello, Sugarloaf!", FragmentStyle {
        color: [1.0, 1.0, 0.0, 1.0], // 黄色
        ..FragmentStyle::default()
    });

    // 构建
    eprintln!("[Sugarloaf FFI] Building content");
    content.build();

    // 创建测试用的彩色矩形和文本对象
    let objects = vec![
        Object::Quad(Quad {
            position: [100.0, 100.0],
            size: [200.0, 200.0],
            color: [1.0, 0.0, 0.0, 1.0], // 红色
            ..Quad::default()
        }),
        Object::RichText(RichText {
            id: rt_id,
            position: [150.0, 150.0],  // 放在红色矩形中间
            lines: None,
        }),
    ];

    eprintln!("[Sugarloaf FFI] Setting {} test objects (quad + richtext)", objects.len());
    handle.set_objects(objects);
}

/// Render a simple rich text demo completely from Rust for integration testing.
#[no_mangle]
pub extern "C" fn sugarloaf_render_demo(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] sugarloaf_render_demo called with null handle!");
        return;
    }

    use sugarloaf::{Object, RichText};

    let handle = unsafe { &mut *handle };
    let rt_id = handle.instance.create_temp_rich_text();
    let content = handle.instance.content();
    content.sel(rt_id);
    content.clear();

    content.add_text(
        "Rust-rendered Sugarloaf demo",
        FragmentStyle {
            color: [1.0, 0.85, 0.2, 1.0],
            ..FragmentStyle::default()
        },
    );
    content.new_line();
    content.add_text(
        "Line 2: 渲染链路验证成功 ✅",
        FragmentStyle {
            color: [0.6, 0.85, 1.0, 1.0],
            ..FragmentStyle::default()
        },
    );
    content.new_line();
    content.add_text(
        "Line 3: wgpu → CAMetalLayer present",
        FragmentStyle {
            color: [0.8, 0.8, 0.8, 1.0],
            ..FragmentStyle::default()
        },
    );
    content.build();

    let object = Object::RichText(RichText {
        id: rt_id,
        position: [20.0, 40.0],
        lines: None,
    });

    handle.set_objects(vec![object]);
    handle.instance.render();
}

/// Render demo text using an existing rich text id (matching Swift's usage).
#[no_mangle]
pub extern "C" fn sugarloaf_render_demo_with_rich_text(
    handle: *mut SugarloafHandle,
    rich_text_id: usize,
) {
    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] sugarloaf_render_demo_with_rich_text called with null handle!");
        return;
    }

    use sugarloaf::{Object, RichText};

    let handle = unsafe { &mut *handle };
    let content = handle.instance.content();
    content.sel(rich_text_id);
    content.clear();


    content.add_text(
        "[Swift→Rust] RichText demo via shared ID",
        FragmentStyle {
            color: [0.9, 0.9, 0.2, 1.0],
            ..FragmentStyle::default()
        },
    );
    content.new_line();
    content.add_text(
        "Line 2 via sugarloaf_render_demo_with_rich_text",
        FragmentStyle {
            color: [0.6, 0.85, 1.0, 1.0],
            ..FragmentStyle::default()
        },
    );
    content.new_line();
    content.add_text(
        "Line 3 ✓ verifying sugarloaf_create_rich_text flow",
        FragmentStyle {
            color: [0.8, 0.8, 0.8, 1.0],
            ..FragmentStyle::default()
        },
    );
    content.build();

    let object = Object::RichText(RichText {
        id: rich_text_id,
        position: [20.0, 80.0],
        lines: None,
    });

    handle.set_objects(vec![object]);
    handle.instance.render();
}

/// Render
#[no_mangle]
pub extern "C" fn sugarloaf_render(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] render() called with null handle!");
        return;
    }

    let handle = unsafe { &mut *handle };
    eprintln!("[Sugarloaf FFI] 🎨 Calling sugarloaf.render()...");
    // 添加panic捕获
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        handle.instance.render();
    }));

    match result {
        Ok(_) => eprintln!("[Sugarloaf FFI] ✅ render() completed successfully"),
        Err(e) => eprintln!("[Sugarloaf FFI] ❌ render() panicked: {:?}", e),
    }
}

/// Resize Sugarloaf rendering surface
#[no_mangle]
pub extern "C" fn sugarloaf_resize(
    handle: *mut SugarloafHandle,
    width: f32,
    height: f32,
) {
    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] resize() called with null handle!");
        return;
    }

    if width <= 0.0 || height <= 0.0 {
        eprintln!("[Sugarloaf FFI] resize() called with invalid dimensions: {}x{}", width, height);
        return;
    }

    let handle = unsafe { &mut *handle };
    eprintln!("[Sugarloaf FFI] 🔄 Resizing Sugarloaf to {}x{}", width, height);
    handle.instance.resize(width as u32, height as u32);
    eprintln!("[Sugarloaf FFI] ✅ Resize completed");
}

/// Rescale Sugarloaf (for DPI changes)
#[no_mangle]
pub extern "C" fn sugarloaf_rescale(
    handle: *mut SugarloafHandle,
    scale: f32,
) {
    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] rescale() called with null handle!");
        return;
    }

    if scale <= 0.0 {
        eprintln!("[Sugarloaf FFI] rescale() called with invalid scale: {}", scale);
        return;
    }

    let handle = unsafe { &mut *handle };
    eprintln!("[Sugarloaf FFI] 🔄 Rescaling Sugarloaf to scale {}", scale);
    handle.instance.rescale(scale);
    eprintln!("[Sugarloaf FFI] ✅ Rescale completed");
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

// ============================================================================
// 新的 Panel 配置 API
// ============================================================================

// ❌ 删除：create_panel 已废弃（Swift 负责创建 Panel）
/*
#[no_mangle]
pub extern "C" fn tab_manager_create_panel(...) -> usize { ... }
*/

/// 🧪 测试函数：在四个角创建测试 pane
#[no_mangle]
pub extern "C" fn tab_manager_test_corner_panes(
    manager: *mut terminal::TabManager,
    container_width: f32,
    container_height: f32,
) {
    if manager.is_null() {
        eprintln!("[FFI] ❌ tab_manager_test_corner_panes: manager is null");
        return;
    }

    let manager = unsafe { &mut *manager };
    manager.test_corner_panes(container_width, container_height);
}

#[no_mangle]
pub extern "C" fn tab_manager_update_panel_config(
    manager: *mut terminal::TabManager,
    panel_id: usize,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    cols: u16,
    rows: u16,
) -> i32 {
    if manager.is_null() {
        eprintln!("[FFI] ❌ tab_manager_update_panel_config: manager is null");
        return 0;
    }

    let manager = unsafe { &mut *manager };
    if manager.update_panel_config(panel_id, x, y, width, height, cols, rows) {
        1
    } else {
        0
    }
}
