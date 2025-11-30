use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use sugarloaf::{
    font::{FontLibrary, fonts::{SugarloafFonts, SugarloafFont, SugarloafFontStyle}},
    layout::RootStyle, FragmentStyle, Sugarloaf, SugarloafRenderer,
    SugarloafWindow, SugarloafWindowSize, Object,
};
use parking_lot::RwLock;

// 同步原语（FairMutex）
mod sync;
pub use sync::*;

// ============================================================================
// 新的 Rio 风格实现
// ============================================================================

// Rio 事件系统
mod rio_event;
pub use rio_event::{EventCallback, EventQueue, FFIEvent, FFIEventListener, RioEvent, StringEventCallback};

// Rio Machine（照抄 Rio 的 PTY 事件循环）
mod rio_machine;
pub use rio_machine::Machine;

// Rio Terminal（新的终端封装）
mod rio_terminal;
pub use rio_terminal::*;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SugarloafFontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub line_height: f32,
}

impl SugarloafFontMetrics {
    /// 临时 fallback 值，创建 RichText 后会被 get_rich_text_dimensions 替换
    fn fallback(scaled_font_size: f32) -> Self {
        let cell_width = scaled_font_size * 0.6;
        let cell_height = scaled_font_size * 1.2;
        Self {
            cell_width,
            cell_height,
            line_height: cell_height,
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
    /// 当前字体大小（用于追踪字体大小变化后更新 metrics）
    current_font_size: f32,
    /// 显示器缩放因子 (用于计算物理像素)
    scale: f32,
    /// 待渲染的 objects 列表（多终端渲染累积）
    pending_objects: Vec<Object>,
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

    /// 🎯 从 Sugarloaf 实际渲染获取精确的 dimensions
    /// 这是 Rio 使用的方式，通过渲染一个空格字符来获取精确的 cell 尺寸
    fn update_font_metrics_from_dimensions(&mut self, rt_id: usize) {
        let dimensions = self.instance.get_rich_text_dimensions(&rt_id);

        // 检查 dimensions 是否有效（Skia 版本可能返回 0）
        // 如果无效，保持当前的 fallback 值
        if dimensions.width > 0.0 && dimensions.height > 0.0 {
            // dimensions.width 和 height 是物理像素
            let metrics = SugarloafFontMetrics {
                cell_width: dimensions.width,
                cell_height: dimensions.height,
                line_height: dimensions.height,
            };

            self.font_metrics = metrics;
            set_global_font_metrics(metrics);
        }
        // 如果 dimensions 无效，保持使用 fallback 值
    }
}

/// 辅助宏：在 FFI 边界捕获 panic
macro_rules! catch_panic {
    ($default:expr, $body:expr) => {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| $body)) {
            Ok(result) => result,
            Err(e) => {
                eprintln!("[sugarloaf FFI] Caught panic: {:?}", e);
                $default
            }
        }
    };
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
    catch_panic!(ptr::null_mut(), {
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
                weight: Some(600),
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
                weight: Some(600),
                style: SugarloafFontStyle::Italic,
                width: None,
            },
            bold_italic: SugarloafFont {
                family: "MapleMono-NF-CN-BoldItalic".to_string(),
                weight: Some(700),
                style: SugarloafFontStyle::Italic,
                width: None,
            },
            // 🍎 启用 Apple Color Emoji（macOS 原生 emoji 支持）
            emoji: Some(SugarloafFont {
                family: "Apple Color Emoji".to_string(),
                weight: None,
                style: SugarloafFontStyle::Normal,
                width: None,
            }),
            ..Default::default()
        };

        let (font_library, _font_errors) = FontLibrary::new(font_spec);

        // 🎯 初始使用 fallback 值，真实值在创建 RichText 后通过 get_rich_text_dimensions 获取
        let scaled_font_size = font_size * scale;
        let font_metrics = SugarloafFontMetrics::fallback(scaled_font_size);
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
            instance.set_background_color(Some(skia_safe::Color4f::new(
                0.0, // r
                0.0, // g
                0.0, // b
                0.0, // a - 完全透明,让窗口的磨砂效果显示出来
            )));
        }

        let handle = Box::new(SugarloafHandle {
            instance,
            current_rt_id: None,
            _font_library: font_library,
            font_metrics,
            current_font_size: font_size,
            scale,
            pending_objects: Vec::new(),
        });
        Box::into_raw(handle)
    })
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

    // 🎯 关键：从 Sugarloaf 获取实际渲染使用的 dimensions
    // 这是 Rio 的做法，保证 Swift 侧计算的网格位置与渲染完全一致
    handle.update_font_metrics_from_dimensions(rt_id);

    rt_id
}

/// Returns the font metrics calculated by Skia.
/// This method directly queries Skia for accurate cell dimensions.
#[no_mangle]
pub extern "C" fn sugarloaf_get_font_metrics(
    handle: *mut SugarloafHandle,
    out_metrics: *mut SugarloafFontMetrics,
) -> bool {
    if handle.is_null() || out_metrics.is_null() {
        return false;
    }

    let handle_ref = unsafe { &mut *handle };

    // 直接从 Skia 获取字体度量
    let (cell_width, cell_height, line_height) = handle_ref.instance.get_font_metrics_skia();

    // 如果获取到有效值，更新缓存
    if cell_width > 0.0 && cell_height > 0.0 {
        let metrics = SugarloafFontMetrics {
            cell_width,
            cell_height,
            line_height,
        };
        handle_ref.font_metrics = metrics;
        set_global_font_metrics(metrics);

        unsafe {
            *out_metrics = metrics;
        }
    } else {
        // 返回缓存的值（fallback）
        unsafe {
            *out_metrics = handle_ref.font_metrics;
        }
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
    sugarloaf_content_add_text_with_width(handle, text, fg_r, fg_g, fg_b, fg_a, 1.0);
}

/// Add text with style and explicit width (for wide characters)
#[no_mangle]
pub extern "C" fn sugarloaf_content_add_text_with_width(
    handle: *mut SugarloafHandle,
    text: *const c_char,
    fg_r: f32,
    fg_g: f32,
    fg_b: f32,
    fg_a: f32,
    width: f32,
) {
    sugarloaf_content_add_text_styled(handle, text, fg_r, fg_g, fg_b, fg_a, width, false, 0.0, 0.0, 0.0, 0.0);
}

/// Add text with full styling options (width, cursor)
/// cursor_shape: 0 = None, 1 = Block, 2 = Underline, 3 = Beam
#[no_mangle]
pub extern "C" fn sugarloaf_content_add_text_styled(
    handle: *mut SugarloafHandle,
    text: *const c_char,
    fg_r: f32,
    fg_g: f32,
    fg_b: f32,
    fg_a: f32,
    width: f32,
    has_cursor: bool,
    cursor_r: f32,
    cursor_g: f32,
    cursor_b: f32,
    cursor_a: f32,
) {
    if handle.is_null() || text.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    let text_str = unsafe { CStr::from_ptr(text).to_str().unwrap_or("") };

    let cursor = if has_cursor {
        Some(sugarloaf::SugarCursor::Block([cursor_r, cursor_g, cursor_b, cursor_a]))
    } else {
        None
    };

    let style = FragmentStyle {
        color: [fg_r, fg_g, fg_b, fg_a],
        width,
        cursor,
        ..FragmentStyle::default()
    };

    handle.instance.content().add_text(text_str, style);
}

/// Add text with full styling options (width, cursor, background color)
/// Automatically handles font fallback for emoji and other special characters.
#[no_mangle]
pub extern "C" fn sugarloaf_content_add_text_full(
    handle: *mut SugarloafHandle,
    text: *const c_char,
    fg_r: f32, fg_g: f32, fg_b: f32, fg_a: f32,
    has_bg: bool,
    bg_r: f32, bg_g: f32, bg_b: f32, bg_a: f32,
    width: f32,
    has_cursor: bool,
    cursor_r: f32, cursor_g: f32, cursor_b: f32, cursor_a: f32,
) {
    if handle.is_null() || text.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    let text_str = unsafe { CStr::from_ptr(text).to_str().unwrap_or("") };

    let cursor = if has_cursor {
        Some(sugarloaf::SugarCursor::Block([cursor_r, cursor_g, cursor_b, cursor_a]))
    } else {
        None
    };

    let background_color = if has_bg {
        Some([bg_r, bg_g, bg_b, bg_a])
    } else {
        None
    };

    let base_style = FragmentStyle {
        color: [fg_r, fg_g, fg_b, fg_a],
        background_color,
        width,
        cursor,
        ..FragmentStyle::default()
    };

    // Check if text contains characters that need font fallback
    // For single characters, try to find the best font match
    let content = handle.instance.content();

    if text_str.chars().count() == 1 {
        // Single character - try font fallback
        let ch = text_str.chars().next().unwrap();

        // Check if this character might need fallback (emoji or non-ASCII)
        let needs_fallback = ch as u32 > 0x7F || is_emoji_like(ch);

        if needs_fallback {
            // Try to find the best font match
            let font_library = content.font_library();
            let font_library_data = font_library.inner.read();
            if let Some((font_id, _is_emoji)) = font_library_data.find_best_font_match(ch, &base_style) {
                drop(font_library_data);
                let style = FragmentStyle {
                    font_id,
                    ..base_style
                };
                content.add_text(text_str, style);
                return;
            }
            drop(font_library_data);
        }
    }

    // Default: use base style (font_id = 0)
    content.add_text(text_str, base_style);
}

/// Add text with full styling options including text decoration flags
/// flags bit mask:
///   0x0002 = BOLD
///   0x0004 = ITALIC
///   0x0008 = UNDERLINE
///   0x0080 = DIM
///   0x0200 = STRIKEOUT
///   0x0800 = DOUBLE_UNDERLINE
///   0x1000 = UNDERCURL
///   0x2000 = DOTTED_UNDERLINE
///   0x4000 = DASHED_UNDERLINE
#[no_mangle]
pub extern "C" fn sugarloaf_content_add_text_decorated(
    handle: *mut SugarloafHandle,
    text: *const c_char,
    fg_r: f32, fg_g: f32, fg_b: f32, fg_a: f32,
    has_bg: bool,
    bg_r: f32, bg_g: f32, bg_b: f32, bg_a: f32,
    width: f32,
    has_cursor: bool,
    cursor_r: f32, cursor_g: f32, cursor_b: f32, cursor_a: f32,
    flags: u32,
) {
    if handle.is_null() || text.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    let text_str = unsafe { CStr::from_ptr(text).to_str().unwrap_or("") };

    let cursor = if has_cursor {
        Some(sugarloaf::SugarCursor::Block([cursor_r, cursor_g, cursor_b, cursor_a]))
    } else {
        None
    };

    let background_color = if has_bg {
        Some([bg_r, bg_g, bg_b, bg_a])
    } else {
        None
    };

    // Parse decoration from flags
    use sugarloaf::layout::{FragmentStyleDecoration, UnderlineInfo, UnderlineShape};

    let decoration = if flags & 0x0008 != 0 {
        // UNDERLINE
        Some(FragmentStyleDecoration::Underline(UnderlineInfo {
            is_doubled: false,
            shape: UnderlineShape::Regular,
        }))
    } else if flags & 0x0800 != 0 {
        // DOUBLE_UNDERLINE
        Some(FragmentStyleDecoration::Underline(UnderlineInfo {
            is_doubled: true,
            shape: UnderlineShape::Regular,
        }))
    } else if flags & 0x1000 != 0 {
        // UNDERCURL
        Some(FragmentStyleDecoration::Underline(UnderlineInfo {
            is_doubled: false,
            shape: UnderlineShape::Curly,
        }))
    } else if flags & 0x2000 != 0 {
        // DOTTED_UNDERLINE
        Some(FragmentStyleDecoration::Underline(UnderlineInfo {
            is_doubled: false,
            shape: UnderlineShape::Dotted,
        }))
    } else if flags & 0x4000 != 0 {
        // DASHED_UNDERLINE
        Some(FragmentStyleDecoration::Underline(UnderlineInfo {
            is_doubled: false,
            shape: UnderlineShape::Dashed,
        }))
    } else if flags & 0x0200 != 0 {
        // STRIKEOUT
        Some(FragmentStyleDecoration::Strikethrough)
    } else {
        None
    };

    // Determine font_id based on bold/italic flags
    // FontLibrary 加载顺序: 0=regular, 1=italic, 2=bold, 3=bold_italic
    let is_bold = flags & 0x0002 != 0;
    let is_italic = flags & 0x0004 != 0;

    let base_font_id = match (is_bold, is_italic) {
        (false, false) => 0, // regular
        (true, false) => 2,  // bold
        (false, true) => 1,  // italic
        (true, true) => 3,   // bold_italic
    };

    // Apply DIM by reducing alpha
    let final_fg_a = if flags & 0x0080 != 0 {
        fg_a * 0.5
    } else {
        fg_a
    };

    let base_style = FragmentStyle {
        font_id: base_font_id,
        color: [fg_r, fg_g, fg_b, final_fg_a],
        background_color,
        width,
        cursor,
        decoration,
        decoration_color: Some([fg_r, fg_g, fg_b, final_fg_a]), // Use foreground color for decoration
        ..FragmentStyle::default()
    };

    // Check if text contains characters that need font fallback
    let content = handle.instance.content();

    if text_str.chars().count() == 1 {
        let ch = text_str.chars().next().unwrap();
        let needs_fallback = ch as u32 > 0x7F || is_emoji_like(ch);

        if needs_fallback {
            let font_library = content.font_library();
            let font_library_data = font_library.inner.read();
            if let Some((font_id, _is_emoji)) = font_library_data.find_best_font_match(ch, &base_style) {
                drop(font_library_data);
                let style = FragmentStyle {
                    font_id,
                    ..base_style
                };
                content.add_text(text_str, style);
                return;
            }
            drop(font_library_data);
        }
    }

    content.add_text(text_str, base_style);
}

/// Check if a character is emoji-like (needs special font)
fn is_emoji_like(ch: char) -> bool {
    let code = ch as u32;

    // Common emoji ranges
    // Emoticons
    (0x1F600..=0x1F64F).contains(&code) ||
    // Miscellaneous Symbols and Pictographs
    (0x1F300..=0x1F5FF).contains(&code) ||
    // Transport and Map Symbols
    (0x1F680..=0x1F6FF).contains(&code) ||
    // Supplemental Symbols and Pictographs
    (0x1F900..=0x1F9FF).contains(&code) ||
    // Symbols and Pictographs Extended-A
    (0x1FA00..=0x1FA6F).contains(&code) ||
    // Dingbats
    (0x2700..=0x27BF).contains(&code) ||
    // Miscellaneous Symbols
    (0x2600..=0x26FF).contains(&code) ||
    // Regional Indicator Symbols
    (0x1F1E0..=0x1F1FF).contains(&code)
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

/// Commit rich text as an object for rendering at (0, 0)
#[no_mangle]
pub extern "C" fn sugarloaf_commit_rich_text(handle: *mut SugarloafHandle, rt_id: usize) {
    sugarloaf_commit_rich_text_at(handle, rt_id, 0.0, 0.0);
}

/// Commit rich text as an object for rendering at specified position
///
/// Position is in logical coordinates (points), not physical pixels.
/// The Y coordinate is from top-left (0 = top of window).
#[no_mangle]
pub extern "C" fn sugarloaf_commit_rich_text_at(
    handle: *mut SugarloafHandle,
    rt_id: usize,
    x: f32,
    y: f32,
) {
    if handle.is_null() {
        return;
    }

    use sugarloaf::{Object, RichText};

    let handle = unsafe { &mut *handle };

    // 创建 RichText 对象，使用传入的位置
    let rich_text_obj = Object::RichText(RichText {
        id: rt_id,
        position: [x, y],
        lines: None,
    });

    // 只设置 RichText，移除测试矩形
    handle.set_objects(vec![rich_text_obj]);
}

// ============================================================================
// 多终端渲染 API（累积 + 统一提交）
// ============================================================================

/// 清空待渲染的 objects 列表（每帧开始时调用）
///
/// 在渲染多个终端之前，调用此函数清空上一帧的累积 objects。
#[no_mangle]
pub extern "C" fn sugarloaf_clear_objects(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.pending_objects.clear();
}

/// 累积 RichText 到待渲染列表（每个终端调用）
///
/// 将指定的 RichText 添加到待渲染列表中，位置由 (x, y) 指定。
/// 多终端场景下，每个终端调用一次此函数，然后统一调用 sugarloaf_flush_and_render。
///
/// # 参数
/// - rt_id: RichText 的 ID（通过 sugarloaf_create_rich_text 创建）
/// - x, y: 渲染位置（逻辑坐标，Y 轴从顶部开始）
#[no_mangle]
pub extern "C" fn sugarloaf_add_rich_text(
    handle: *mut SugarloafHandle,
    rt_id: usize,
    x: f32,
    y: f32,
) {
    if handle.is_null() {
        return;
    }

    use sugarloaf::RichText;

    let handle = unsafe { &mut *handle };

    let rich_text_obj = Object::RichText(RichText {
        id: rt_id,
        position: [x, y],
        lines: None,
    });

    handle.pending_objects.push(rich_text_obj);
}

/// 统一提交所有 objects 并渲染（每帧结束时调用）
///
/// 将 pending_objects 中累积的所有 RichText 一次性提交给 Sugarloaf，
/// 然后触发 GPU 渲染。渲染完成后清空 pending_objects。
#[no_mangle]
pub extern "C" fn sugarloaf_flush_and_render(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };

    // 提交所有累积的 objects
    handle.instance.set_objects(handle.pending_objects.clone());

    // 触发 GPU 渲染
    handle.instance.render();

    // 清空缓冲区
    handle.pending_objects.clear();
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
    eprintln!("[Sugarloaf FFI] sugarloaf_render() called");

    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] render() called with null handle!");
        return;
    }

    let handle = unsafe { &mut *handle };
    eprintln!("[Sugarloaf FFI] Calling instance.render()...");

    // 添加panic捕获
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        handle.instance.render();
    }));

    eprintln!("[Sugarloaf FFI] instance.render() completed");

    if let Err(e) = result {
        eprintln!("[Sugarloaf FFI] ❌ render() panicked: {:?}", e);
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
    println!("[Sugarloaf FFI] 📐 resize() called: {}x{} (current scale: {})", width, height, handle.scale);
    handle.instance.resize(width as u32, height as u32);
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
    let old_scale = handle.scale;
    println!("[Sugarloaf FFI] 🔄 rescale() called: {} -> {}", old_scale, scale);
    handle.instance.rescale(scale);

    // 关键修复：更新 handle.scale
    handle.scale = scale;

    // 关键修复：rescale 后重新计算 fontMetrics
    // 因为 fontMetrics 是物理像素，scale 变化后值会不同
    if let Some(rt_id) = handle.current_rt_id {
        handle.update_font_metrics_from_dimensions(rt_id);
    }
}

/// 字体大小操作类型
/// 0 = Reset (重置为默认)
/// 1 = Decrease (减小)
/// 2 = Increase (增大)
#[no_mangle]
pub extern "C" fn sugarloaf_change_font_size(
    handle: *mut SugarloafHandle,
    rich_text_id: usize,
    operation: u8,
) {
    if handle.is_null() {
        eprintln!("[Sugarloaf FFI] change_font_size() called with null handle!");
        return;
    }

    let handle = unsafe { &mut *handle };
    handle.instance.set_rich_text_font_size_based_on_action(&rich_text_id, operation);

    // 更新追踪的字体大小
    match operation {
        0 => handle.current_font_size = 12.0, // Reset 到默认值
        1 => handle.current_font_size = (handle.current_font_size - 1.0).max(6.0), // Decrease
        2 => handle.current_font_size = (handle.current_font_size + 1.0).min(100.0), // Increase
        _ => {}
    }

    // 🎯 从 Sugarloaf 获取实际渲染使用的 dimensions（字体大小变化后需要重新获取）
    handle.update_font_metrics_from_dimensions(rich_text_id);
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

