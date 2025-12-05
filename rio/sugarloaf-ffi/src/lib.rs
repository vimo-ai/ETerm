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
// 全局常量
// ============================================================================

/// 默认行高倍数（1.0 = 无额外行间距）
///
/// 注意：line_height > 1.0 会在每行底部增加空白，导致行间缝隙
/// 建议使用 1.0 以获得最佳渲染效果
pub const DEFAULT_LINE_HEIGHT: f32 = 1.0;

/// 创建默认字体配置（Maple Mono NF CN + Apple Color Emoji）
///
/// 统一的字体配置入口，确保所有终端实例使用相同的字体设置
pub fn create_default_font_spec(font_size: f32) -> SugarloafFonts {
    SugarloafFonts {
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
    }
}

// ============================================================================
// 新架构模块（DDD 分层架构，使用 feature flag 隔离）
// ============================================================================

#[cfg(feature = "new_architecture")]
pub mod domain;

#[cfg(feature = "new_architecture")]
pub mod render;

#[cfg(feature = "new_architecture")]
pub mod compositor;

#[cfg(feature = "new_architecture")]
pub mod app;

// CVDisplayLink Rust 绑定（macOS only）
#[cfg(all(feature = "new_architecture", target_os = "macos"))]
pub mod display_link;

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
    /// Damaged 行的列表，None = Full damage (macOS only)
    #[cfg(target_os = "macos")]
    damaged_lines: Option<Vec<usize>>,
}

impl SugarloafHandle {
    fn set_objects(&mut self, objects: Vec<Object>) {
        self.instance.set_objects(objects);
    }

    fn clear(&mut self) {
        self.instance.clear();
    }

    #[allow(dead_code)] // Legacy wrapper method
    fn render(&mut self) {
        self.instance.render();
    }

    /// 🎯 从 Skia 获取精确的字体度量
    /// 直接调用 get_font_metrics_skia 测量 "M" 字符，确保与渲染完全一致
    fn update_font_metrics_from_dimensions(&mut self, _rt_id: usize) {
        // 直接从 Skia 获取字体度量（测量 "M" 字符）
        let (cell_width, cell_height, line_height) = self.instance.get_font_metrics_skia();

        // 检查度量是否有效
        if cell_width > 0.0 && cell_height > 0.0 {
            // 返回的是物理像素
            let metrics = SugarloafFontMetrics {
                cell_width,
                cell_height,
                line_height,
            };

            self.font_metrics = metrics;
            set_global_font_metrics(metrics);
        }
        // 如果度量无效，保持使用 fallback 值
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

        // 使用统一的字体配置
        let font_spec = create_default_font_spec(font_size);
        let (font_library, _font_errors) = FontLibrary::new(font_spec);

        // 🎯 延迟初始化：真实值在创建 RichText 后通过 get_font_metrics_skia 获取
        // 初始使用零值，调用方已有 unwrap_or_else 兜底逻辑
        let font_metrics = SugarloafFontMetrics {
            cell_width: 0.0,
            cell_height: 0.0,
            line_height: 0.0,
        };
        // 不设置 global_font_metrics，等 create_rich_text() 时再设置真实值

        let layout = RootStyle {
            font_size,
            line_height: DEFAULT_LINE_HEIGHT,
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
            #[cfg(target_os = "macos")]
            damaged_lines: None,
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

/// Check if layout cache contains a specific content hash (macOS only)
///
/// Returns true if the cache has a layout for this hash, false otherwise.
/// This is used to optimize rendering by skipping extraction of cached lines.
#[cfg(target_os = "macos")]
#[no_mangle]
pub extern "C" fn sugarloaf_has_cached_layout(
    handle: *mut SugarloafHandle,
    content_hash: u64,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };
    handle.instance.has_cached_layout(content_hash)
}

#[cfg(not(target_os = "macos"))]
#[no_mangle]
pub extern "C" fn sugarloaf_has_cached_layout(
    _handle: *mut SugarloafHandle,
    _content_hash: u64,
) -> bool {
    false
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

/// 设置本帧的 damage 信息（macOS only）
///
/// # 参数
/// - lines_ptr: 指向 usize 数组的指针，包含 damaged 行号
/// - lines_count: 数组长度，0 表示 Full damage
///
/// # 说明
/// 此函数必须在每帧 sugarloaf_flush_and_render 之前调用。
/// 如果不调用此函数，默认为 Full damage。
#[no_mangle]
#[cfg(target_os = "macos")]
pub extern "C" fn sugarloaf_set_damage(
    handle: *mut SugarloafHandle,
    lines_ptr: *const usize,
    lines_count: usize,
) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { &mut *handle };

    if lines_count == 0 || lines_ptr.is_null() {
        // Full damage
        handle.damaged_lines = None;
    } else {
        // Partial damage
        let lines = unsafe {
            std::slice::from_raw_parts(lines_ptr, lines_count)
        };
        handle.damaged_lines = Some(lines.to_vec());
    }
}

#[no_mangle]
#[cfg(not(target_os = "macos"))]
pub extern "C" fn sugarloaf_set_damage(
    _handle: *mut SugarloafHandle,
    _lines_ptr: *const usize,
    _lines_count: usize,
) {
    // No-op on non-macOS platforms
}

/// 统一提交所有 objects 并渲染（每帧结束时调用）
///
/// 将 pending_objects 中累积的所有 RichText 一次性提交给 Sugarloaf，
/// 然后触发 GPU 渲染。渲染完成后清空 pending_objects。
///
/// 🎯 使用 off-screen surface + damage tracking 优化渲染
#[no_mangle]
pub extern "C" fn sugarloaf_flush_and_render(handle: *mut SugarloafHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { &mut *handle };

    // 提交所有累积的 objects
    handle.instance.set_objects(handle.pending_objects.clone());

    // 触发 GPU 渲染（使用 off-screen surface 优化）
    #[cfg(target_os = "macos")]
    {
        // 获取 damage 信息并传递给 render_with_damage
        let damaged = handle.damaged_lines.take(); // take 并重置为 None
        handle.instance.render_with_damage(damaged.as_deref());
    }

    #[cfg(not(target_os = "macos"))]
    {
        handle.instance.render();
    }

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

    // 创建 rich text
    let rt_id = handle.instance.create_temp_rich_text();

    // 选择并清空
    let content = handle.instance.content();
    content.sel(rt_id);
    content.clear();

    // 添加简单文本
    content.add_text("Hello, Sugarloaf!", FragmentStyle {
        color: [1.0, 1.0, 0.0, 1.0], // 黄色
        ..FragmentStyle::default()
    });

    // 构建
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

// ============================================================================
// Terminal Rendering API - Batch rendering in Rust
// ============================================================================

/// Render terminal content directly from Rust (batch rendering)
///
/// This function moves all rendering logic from Swift to Rust, reducing FFI calls
/// from ~14000 per frame to just 1.
///
/// # Parameters
/// - pool_handle: Terminal pool handle
/// - terminal_id: Terminal ID
/// - sugarloaf_handle: Sugarloaf handle
/// - rich_text_id: RichText ID to render into
/// - cursor_visible: Whether cursor is visible
///
/// # Returns
/// - 0: Success
/// - -1: Error (null pointer, terminal not found, etc.)
#[no_mangle]
pub extern "C" fn rio_terminal_render_to_richtext(
    pool_handle: *mut crate::rio_terminal::RioTerminalPool,
    terminal_id: i32,
    sugarloaf_handle: *mut SugarloafHandle,
    rich_text_id: i32,
    cursor_visible: bool,
) -> i32 {
    catch_panic!(-1, {
        // Validate pointers
        if pool_handle.is_null() || sugarloaf_handle.is_null() {
            eprintln!("[rio_terminal_render_to_richtext] Null pointer error");
            return -1;
        }

        let pool = unsafe { &*pool_handle };
        let sugarloaf = unsafe { &mut *sugarloaf_handle };
        let terminal_id_usize = terminal_id as usize;

        // Get terminal
        let terminal = match pool.get(terminal_id_usize) {
            Some(t) => t,
            None => {
                eprintln!("[rio_terminal_render_to_richtext] Terminal {} not found", terminal_id);
                return -1;
            }
        };

        // Get snapshot
        let snapshot = terminal.snapshot();

        // Select and clear rich text
        let content = sugarloaf.instance.content();
        content.sel(rich_text_id as usize);
        content.clear();

        // Flag constants (from Swift)
        const INVERSE: u32 = 0x0001;
        const WIDE_CHAR: u32 = 0x0020;
        const WIDE_CHAR_SPACER: u32 = 0x0040;
        const LEADING_WIDE_CHAR_SPACER: u32 = 0x0400;

        // Render each line
        let lines_to_render = snapshot.screen_lines;
        let cols_to_render = snapshot.columns;

        for row_index in 0..lines_to_render {
            if row_index > 0 {
                content.new_line();
            }

            // Calculate absolute row
            let absolute_row = snapshot.scrollback_lines as i64
                - snapshot.display_offset as i64
                + row_index as i64;

            // Get row cells
            let cells = terminal.get_row_cells(absolute_row);

            // Check if this is a cursor position report line (skip if so)
            if is_cursor_position_report_line(&cells) {
                continue;
            }

            let cursor_row = snapshot.cursor_row;
            let cursor_col = snapshot.cursor_col;

            // Render each cell
            for (col_index, cell) in cells.iter().enumerate().take(cols_to_render) {
                // Skip spacers
                let is_spacer = cell.flags & (WIDE_CHAR_SPACER | LEADING_WIDE_CHAR_SPACER);
                if is_spacer != 0 {
                    continue;
                }

                // Get character
                let scalar = match std::char::from_u32(cell.character) {
                    Some(s) => s,
                    None => continue,
                };

                // Add VS16 if needed
                let char_to_render = if cell.has_vs16 {
                    format!("{}\u{FE0F}", scalar)
                } else {
                    scalar.to_string()
                };

                // Determine width
                let is_wide = cell.flags & WIDE_CHAR != 0;
                let glyph_width = if is_wide { 2.0 } else { 1.0 };

                // Get colors (normalized to 0.0-1.0)
                let mut fg_r = cell.fg_r as f32 / 255.0;
                let mut fg_g = cell.fg_g as f32 / 255.0;
                let mut fg_b = cell.fg_b as f32 / 255.0;
                let mut fg_a = cell.fg_a as f32 / 255.0;

                let mut bg_r = cell.bg_r as f32 / 255.0;
                let mut bg_g = cell.bg_g as f32 / 255.0;
                let mut bg_b = cell.bg_b as f32 / 255.0;
                let mut bg_a = cell.bg_a as f32 / 255.0;

                // Handle INVERSE flag
                let is_inverse = cell.flags & INVERSE != 0;
                let has_bg = if is_inverse {
                    // Swap foreground and background (including alpha)
                    std::mem::swap(&mut fg_r, &mut bg_r);
                    std::mem::swap(&mut fg_g, &mut bg_g);
                    std::mem::swap(&mut fg_b, &mut bg_b);
                    std::mem::swap(&mut fg_a, &mut bg_a);
                    true
                } else {
                    bg_r > 0.01 || bg_g > 0.01 || bg_b > 0.01
                };

                // Handle cursor
                let has_cursor = cursor_visible
                    && row_index == cursor_row
                    && col_index == cursor_col;

                let cursor_r = 1.0;
                let cursor_g = 1.0;
                let cursor_b = 1.0;
                let cursor_a = 0.8;

                // Block cursor inverts colors
                if has_cursor && snapshot.cursor_shape == 0 {
                    fg_r = 0.0;
                    fg_g = 0.0;
                    fg_b = 0.0;
                }

                // Call sugarloaf to add text (need to convert to CString)
                let c_str = match std::ffi::CString::new(char_to_render.as_bytes()) {
                    Ok(s) => s,
                    Err(_) => continue,
                };

                sugarloaf_content_add_text_decorated(
                    sugarloaf_handle,
                    c_str.as_ptr(),
                    fg_r, fg_g, fg_b, fg_a,
                    has_bg,
                    bg_r, bg_g, bg_b, bg_a,
                    glyph_width,
                    has_cursor && snapshot.cursor_shape == 0,
                    cursor_r, cursor_g, cursor_b, cursor_a,
                    cell.flags,
                );
            }
        }

        // Build content
        content.build();

        0 // Success
    })
}

/// Check if a line is a cursor position report (DSR response)
fn is_cursor_position_report_line(cells: &[crate::rio_terminal::FFICell]) -> bool {
    if cells.is_empty() {
        return false;
    }

    // Must start with ESC (0x1B)
    if cells[0].character != 27 {
        return false;
    }

    // Build string from cells
    let mut scalars = Vec::new();
    for cell in cells {
        if cell.character == 0 {
            break; // Stop at null
        }
        if let Some(scalar) = std::char::from_u32(cell.character) {
            scalars.push(scalar);
        }
        if scalars.len() > 32 {
            return false; // Too long
        }
    }

    if scalars.is_empty() {
        return false;
    }

    let text: String = scalars.into_iter().collect();

    // Pattern: ESC[<row>;<col>R
    // Simple check: starts with "\x1B[" and ends with "R"
    text.starts_with("\x1B[") && text.ends_with('R') && text.contains(';')
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


// ============================================================================
// 新架构 FFI 接口（TerminalApp）
// ============================================================================

#[cfg(feature = "new_architecture")]
use app::{TerminalApp, AppConfig, ErrorCode, FontMetrics, GridPoint};

#[cfg(feature = "new_architecture")]
use app::ffi::{TerminalEvent, TerminalAppEventCallback};

/// 不透明句柄（Swift 不可见内部结构）
#[cfg(feature = "new_architecture")]
#[repr(C)]
pub struct TerminalAppHandle {
    _private: [u8; 0],
}

// ===== 生命周期管理 =====

/// 创建终端应用
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_create(config: AppConfig) -> *mut TerminalAppHandle {
    match TerminalApp::new(config) {
        Ok(app) => Box::into_raw(Box::new(app)) as *mut TerminalAppHandle,
        Err(e) => {
            eprintln!("[TerminalApp FFI] Failed to create: {:?}", e);
            std::ptr::null_mut()
        }
    }
}

/// 销毁终端应用
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_destroy(handle: *mut TerminalAppHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle as *mut TerminalApp);
        }
    }
}

// ===== 核心功能 =====

/// 写入数据（PTY → Terminal）
/// ⚠️ 已废弃：在 PTY 模式下，PTY 输出通过 Machine 自动喂给 Terminal
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_write(
    handle: *mut TerminalAppHandle,
    data: *const u8,
    len: usize,
) -> ErrorCode {
    if handle.is_null() || data.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    let data_slice = unsafe { std::slice::from_raw_parts(data, len) };

    match app.write(data_slice) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 处理键盘输入（Keyboard → PTY）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_input(
    handle: *mut TerminalAppHandle,
    data: *const u8,
    len: usize,
) -> ErrorCode {
    if handle.is_null() || data.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    let data_slice = unsafe { std::slice::from_raw_parts(data, len) };

    match app.input(data_slice) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 渲染（批量渲染所有行）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_render(handle: *mut TerminalAppHandle) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.render() {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 调整大小
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_resize(
    handle: *mut TerminalAppHandle,
    cols: u16,
    rows: u16,
) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.resize(cols, rows) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 调整大小（包含像素尺寸）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_resize_with_pixels(
    handle: *mut TerminalAppHandle,
    cols: u16,
    rows: u16,
    width: f32,
    height: f32,
) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.resize_with_pixels(cols, rows, width, height) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

// ===== 交互功能 =====

/// 开始选区
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_start_selection(
    handle: *mut TerminalAppHandle,
    point: GridPoint,
) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.start_selection(point) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 更新选区
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_update_selection(
    handle: *mut TerminalAppHandle,
    point: GridPoint,
) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.update_selection(point) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 清除选区
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_clear_selection(handle: *mut TerminalAppHandle) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.clear_selection() {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 获取选区文本
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_get_selection_text(
    handle: *mut TerminalAppHandle,
    out_buffer: *mut u8,
    buffer_len: usize,
    out_written: *mut usize,
) -> ErrorCode {
    if handle.is_null() || out_buffer.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &*(handle as *const TerminalApp) };
    let buffer = unsafe { std::slice::from_raw_parts_mut(out_buffer, buffer_len) };

    match app.get_selection_text(buffer) {
        Ok(written) => {
            if !out_written.is_null() {
                unsafe { *out_written = written };
            }
            ErrorCode::Success
        }
        Err(e) => e,
    }
}

/// 搜索文本
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_search(
    handle: *mut TerminalAppHandle,
    pattern: *const c_char,
) -> usize {
    if handle.is_null() || pattern.is_null() {
        return 0;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    let pattern_str = unsafe { CStr::from_ptr(pattern).to_str().unwrap_or("") };

    app.search(pattern_str)
}

/// 下一个匹配
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_next_match(handle: *mut TerminalAppHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    app.next_match()
}

/// 上一个匹配
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_prev_match(handle: *mut TerminalAppHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    app.prev_match()
}

/// 清除搜索
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_clear_search(handle: *mut TerminalAppHandle) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.clear_search() {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 滚动
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_scroll(handle: *mut TerminalAppHandle, delta: i32) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.scroll(delta) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 滚动到顶部
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_scroll_to_top(handle: *mut TerminalAppHandle) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.scroll_to_top() {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 滚动到底部
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_scroll_to_bottom(handle: *mut TerminalAppHandle) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.scroll_to_bottom() {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

// ===== 配置和状态 =====

/// 重新配置
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_reconfigure(
    handle: *mut TerminalAppHandle,
    config: AppConfig,
) -> ErrorCode {
    if handle.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    match app.reconfigure(config) {
        Ok(()) => ErrorCode::Success,
        Err(e) => e,
    }
}

/// 获取字体度量
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_get_font_metrics(
    handle: *mut TerminalAppHandle,
    out_metrics: *mut FontMetrics,
) -> ErrorCode {
    if handle.is_null() || out_metrics.is_null() {
        return ErrorCode::NullPointer;
    }

    let app = unsafe { &*(handle as *const TerminalApp) };
    let metrics = app.get_font_metrics();

    unsafe {
        *out_metrics = metrics;
    }

    ErrorCode::Success
}

/// 设置事件回调
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_app_set_event_callback(
    handle: *mut TerminalAppHandle,
    callback: TerminalAppEventCallback,
    context: *mut c_void,
) {
    if handle.is_null() {
        return;
    }

    let app = unsafe { &mut *(handle as *mut TerminalApp) };
    app.set_event_callback(callback, context);
}

// ============================================================================
// TerminalPool FFI - 多终端管理 + 统一渲染
// ============================================================================

#[cfg(feature = "new_architecture")]
use app::TerminalPool;

#[cfg(feature = "new_architecture")]
use app::RenderScheduler;

/// TerminalPool 句柄（不透明指针）
#[cfg(feature = "new_architecture")]
#[repr(C)]
pub struct TerminalPoolHandle {
    _private: [u8; 0],
}

/// 创建 TerminalPool
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_create(config: AppConfig) -> *mut TerminalPoolHandle {
    match TerminalPool::new(config) {
        Ok(pool) => {
            let boxed = Box::new(pool);
            Box::into_raw(boxed) as *mut TerminalPoolHandle
        }
        Err(e) => {
            eprintln!("[TerminalPool FFI] Create failed: {:?}", e);
            std::ptr::null_mut()
        }
    }
}

/// 销毁 TerminalPool
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_destroy(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(handle as *mut TerminalPool);
    }
}

/// 创建新终端
///
/// 返回终端 ID（>= 1），失败返回 -1
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal(
    handle: *mut TerminalPoolHandle,
    cols: u16,
    rows: u16,
) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.create_terminal(cols, rows)
}

/// 关闭终端
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_close_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.close_terminal(terminal_id)
}

/// 调整终端大小
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_resize_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    cols: u16,
    rows: u16,
    width: f32,
    height: f32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.resize_terminal(terminal_id, cols, rows, width, height)
}

/// 发送输入到终端
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_input(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    data: *const u8,
    len: usize,
) -> bool {
    if handle.is_null() || data.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    let data_slice = unsafe { std::slice::from_raw_parts(data, len) };
    pool.input(terminal_id, data_slice)
}

/// 滚动终端
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_scroll(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    delta: i32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.scroll(terminal_id, delta)
}

// ===== 渲染流程（统一提交）=====

/// 开始新的一帧（清空待渲染列表）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_begin_frame(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.begin_frame();
}

/// 渲染终端到指定位置（累积到待渲染列表）
///
/// # 参数
/// - terminal_id: 终端 ID
/// - x, y: 渲染位置（逻辑坐标）
/// - width, height: 终端区域大小（逻辑坐标）
///   - 如果 > 0，会自动计算 cols/rows 并 resize
///   - 如果 = 0，不执行 resize（保持当前尺寸）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_render_terminal(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.render_terminal(terminal_id, x, y, width, height)
}

/// 结束帧（统一提交渲染）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_end_frame(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.end_frame();
}

/// 调整 Sugarloaf 渲染表面大小
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_resize_sugarloaf(
    handle: *mut TerminalPoolHandle,
    width: f32,
    height: f32,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.resize_sugarloaf(width, height);
}

/// 设置事件回调
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_set_event_callback(
    handle: *mut TerminalPoolHandle,
    callback: TerminalAppEventCallback,
    context: *mut c_void,
) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.set_event_callback(callback, context);
}

/// 获取终端数量
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_terminal_count(handle: *mut TerminalPoolHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.terminal_count()
}

/// 检查是否需要渲染
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_needs_render(handle: *mut TerminalPoolHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.needs_render()
}

/// 清除渲染标记
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_clear_render_flag(handle: *mut TerminalPoolHandle) {
    if handle.is_null() {
        return;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.clear_render_flag();
}

// ============================================================================
// RenderScheduler FFI - 渲染调度器（CVDisplayLink）
// ============================================================================

/// RenderScheduler 句柄（不透明指针）
#[cfg(feature = "new_architecture")]
#[repr(C)]
pub struct RenderSchedulerHandle {
    _private: [u8; 0],
}

/// 渲染布局信息
#[cfg(feature = "new_architecture")]
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RenderLayout {
    pub terminal_id: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// 渲染回调类型
///
/// 在 VSync 时触发，Swift 侧应该在回调中执行渲染：
/// - terminal_pool_begin_frame
/// - terminal_pool_render_terminal (for each layout item)
/// - terminal_pool_end_frame
#[cfg(feature = "new_architecture")]
pub type RenderSchedulerCallback = extern "C" fn(
    context: *mut c_void,
    layout: *const RenderLayout,
    layout_count: usize,
);

/// 创建 RenderScheduler
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_create() -> *mut RenderSchedulerHandle {
    let scheduler = RenderScheduler::new();
    Box::into_raw(Box::new(scheduler)) as *mut RenderSchedulerHandle
}

/// 销毁 RenderScheduler
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_destroy(handle: *mut RenderSchedulerHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(handle as *mut RenderScheduler);
    }
}

/// 设置渲染回调
///
/// 回调在 CVDisplayLink VSync 时触发
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_set_callback(
    handle: *mut RenderSchedulerHandle,
    callback: RenderSchedulerCallback,
    context: *mut c_void,
) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &*(handle as *const RenderScheduler) };

    // 包装 C 回调为 Rust 闭包
    // 注意：context 需要是 Send + Sync（Swift 侧保证）
    let context_ptr = context as usize; // 转成 usize 来满足 Send + Sync
    scheduler.set_render_callback(move |layout: &[(usize, f32, f32, f32, f32)]| {
        // 转换布局格式
        let layouts: Vec<RenderLayout> = layout
            .iter()
            .map(|&(terminal_id, x, y, width, height)| RenderLayout {
                terminal_id,
                x,
                y,
                width,
                height,
            })
            .collect();

        // 调用 C 回调
        callback(context_ptr as *mut c_void, layouts.as_ptr(), layouts.len());
    });
}

/// 启动 RenderScheduler（启动 CVDisplayLink）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_start(handle: *mut RenderSchedulerHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let scheduler = unsafe { &mut *(handle as *mut RenderScheduler) };
    scheduler.start()
}

/// 停止 RenderScheduler
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_stop(handle: *mut RenderSchedulerHandle) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &mut *(handle as *mut RenderScheduler) };
    scheduler.stop();
}

/// 请求渲染（标记 dirty）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_request_render(handle: *mut RenderSchedulerHandle) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &*(handle as *const RenderScheduler) };
    scheduler.request_render();
}

/// 设置渲染布局
///
/// 布局信息会在下次 VSync 回调时传给回调函数
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_set_layout(
    handle: *mut RenderSchedulerHandle,
    layout: *const RenderLayout,
    count: usize,
) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &*(handle as *const RenderScheduler) };

    let layouts = if layout.is_null() || count == 0 {
        Vec::new()
    } else {
        let slice = unsafe { std::slice::from_raw_parts(layout, count) };
        slice
            .iter()
            .map(|l| (l.terminal_id, l.x, l.y, l.width, l.height))
            .collect()
    };

    scheduler.set_layout(layouts);
}

/// 绑定到 TerminalPool 的 needs_render 标记
///
/// 让 RenderScheduler 和 TerminalPool 共享同一个 dirty 标记
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn render_scheduler_bind_to_pool(
    scheduler_handle: *mut RenderSchedulerHandle,
    pool_handle: *mut TerminalPoolHandle,
) {
    if scheduler_handle.is_null() || pool_handle.is_null() {
        return;
    }

    let scheduler = unsafe { &mut *(scheduler_handle as *mut RenderScheduler) };
    let pool = unsafe { &*(pool_handle as *const TerminalPool) };

    scheduler.bind_needs_render(pool.needs_render_flag());
}
