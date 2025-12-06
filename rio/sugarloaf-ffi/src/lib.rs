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

/// 创建新终端（指定工作目录）
///
/// 返回终端 ID（>= 1），失败返回 -1
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_create_terminal_with_cwd(
    handle: *mut TerminalPoolHandle,
    cols: u16,
    rows: u16,
    working_dir: *const std::ffi::c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    let working_dir_opt = if working_dir.is_null() {
        None
    } else {
        unsafe { std::ffi::CStr::from_ptr(working_dir).to_str().ok().map(|s| s.to_string()) }
    };

    pool.create_terminal_with_cwd(cols, rows, working_dir_opt)
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

/// 获取终端的当前工作目录
///
/// 返回的字符串需要调用者使用 `rio_free_string` 释放
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_get_cwd(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> *mut std::ffi::c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let pool = unsafe { &*(handle as *mut TerminalPool) };

    if let Some(cwd) = pool.get_cwd(terminal_id) {
        match std::ffi::CString::new(cwd.to_string_lossy().as_bytes()) {
            Ok(c_str) => c_str.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    } else {
        std::ptr::null_mut()
    }
}

/// 释放 Rust 分配的字符串
///
/// 用于释放 `terminal_pool_get_cwd` 等函数返回的字符串
#[no_mangle]
pub extern "C" fn rio_free_string(s: *mut std::ffi::c_char) {
    if !s.is_null() {
        unsafe {
            drop(std::ffi::CString::from_raw(s));
        }
    }
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

/// 获取字体度量（物理像素）
///
/// 返回与渲染一致的字体度量：
/// - cell_width: 单元格宽度（物理像素）
/// - cell_height: 基础单元格高度（物理像素，不含 line_height_factor）
/// - line_height: 实际行高（物理像素，= cell_height * line_height_factor）
///
/// 注意：鼠标坐标转换应使用 line_height（而非 cell_height）
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_get_font_metrics(
    handle: *mut TerminalPoolHandle,
    out_metrics: *mut SugarloafFontMetrics,
) -> bool {
    if handle.is_null() || out_metrics.is_null() {
        return false;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    let (cell_width, cell_height, line_height) = pool.get_font_metrics();

    unsafe {
        (*out_metrics).cell_width = cell_width;
        (*out_metrics).cell_height = cell_height;
        (*out_metrics).line_height = line_height;
    }

    true
}

/// 调整字体大小
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - operation: 0=重置(14pt), 1=减小(-1pt), 2=增大(+1pt)
///
/// # 返回
/// - true: 成功
/// - false: 句柄无效
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_change_font_size(
    handle: *mut TerminalPoolHandle,
    operation: u8,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };
    pool.change_font_size(operation);
    true
}

/// 获取当前字体大小
///
/// # 参数
/// - handle: TerminalPool 句柄
///
/// # 返回
/// - 当前字体大小（pt），如果句柄无效返回 0.0
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_get_font_size(
    handle: *mut TerminalPoolHandle,
) -> f32 {
    if handle.is_null() {
        return 0.0;
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };
    pool.get_font_size()
}

// ============================================================================
// Cursor FFI - 光标相关
// ============================================================================

/// 光标位置结果
#[cfg(feature = "new_architecture")]
#[repr(C)]
pub struct FFICursorPosition {
    /// 光标列（从 0 开始）
    pub col: u16,
    /// 光标行（从 0 开始，相对于可见区域）
    pub row: u16,
    /// 是否有效（terminal_id 无效时为 false）
    pub valid: bool,
}

/// 获取终端光标位置
///
/// 返回光标的屏幕坐标（相对于可见区域）
///
/// # 参数
/// - handle: TerminalPool 句柄
/// - terminal_id: 终端 ID
///
/// # 返回
/// - FFICursorPosition，失败时 valid=false, col=0, row=0
///
/// # 注意
/// - 返回的是**屏幕坐标**（相对于可见区域），不是绝对坐标
/// - row=0 表示屏幕第一行，row=rows-1 表示屏幕最后一行
/// - 如果终端正在滚动查看历史，光标可能不在可见区域
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_get_cursor(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> FFICursorPosition {
    if handle.is_null() {
        return FFICursorPosition { col: 0, row: 0, valid: false };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    if let Some(terminal) = pool.get_terminal(terminal_id) {
        // 从 state() 获取光标位置
        let state = terminal.state();
        let cursor = &state.cursor;

        // cursor.position 是绝对坐标，需要转换为屏幕坐标
        // 屏幕坐标 = 绝对坐标 - history_size + display_offset
        let grid = &state.grid;
        let history_size = grid.history_size();
        let display_offset = grid.display_offset();

        // 计算屏幕行
        // absolute_line = cursor.line()
        // screen_row = absolute_line - history_size + display_offset
        let absolute_line = cursor.line();
        let screen_row = if absolute_line >= history_size {
            // 正常情况：光标在可见区域或下方
            (absolute_line - history_size + display_offset) as i64
        } else {
            // 光标在历史缓冲区（不应该发生，但为了安全）
            -1
        };

        // 验证光标是否在可见区域
        let rows = terminal.rows();
        let valid = screen_row >= 0 && screen_row < rows as i64;

        FFICursorPosition {
            col: cursor.col() as u16,
            row: if valid { screen_row as u16 } else { 0 },
            valid,
        }
    } else {
        FFICursorPosition { col: 0, row: 0, valid: false }
    }
}

// ============================================================================
// Selection FFI - 选区相关
// ============================================================================

/// 屏幕坐标转绝对坐标结果
#[cfg(feature = "new_architecture")]
#[repr(C)]
pub struct ScreenToAbsoluteResult {
    pub absolute_row: i64,
    pub col: usize,
    pub success: bool,
}

/// 屏幕坐标转绝对坐标
///
/// 将屏幕坐标（相对于可见区域）转换为绝对坐标（含历史缓冲区）
///
/// 坐标系说明：
/// - 屏幕坐标：screen_row=0 是屏幕顶部，screen_row=screen_lines-1 是屏幕底部
/// - 绝对坐标：从 0 开始，0 是历史缓冲区最开始（最旧的行）
///   - 当 history_size=0 时，absolute_row 范围是 [0, screen_lines-1]
///   - 当 history_size>0 时，absolute_row 范围是 [0, history_size+screen_lines-1]
///
/// 转换公式（考虑滚动偏移）：
/// absolute_row = history_size - display_offset + screen_row
///
/// 注意：这里的 absolute_row 总是非负数，因为：
/// - history_size >= display_offset（display_offset 不能超过历史大小）
/// - screen_row >= 0
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_screen_to_absolute(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    screen_row: usize,
    screen_col: usize,
) -> ScreenToAbsoluteResult {
    if handle.is_null() {
        return ScreenToAbsoluteResult { absolute_row: 0, col: 0, success: false };
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    if let Some(terminal) = pool.get_terminal(terminal_id) {
        // 从 state() 获取 grid 信息
        let state = terminal.state();
        let history_size = state.grid.history_size();
        let display_offset = state.grid.display_offset();

        // 绝对行号 = history_size - display_offset + screen_row
        // 这保证结果是非负数
        let absolute_row = (history_size + screen_row).saturating_sub(display_offset) as i64;

        ScreenToAbsoluteResult {
            absolute_row,
            col: screen_col,
            success: true,
        }
    } else {
        ScreenToAbsoluteResult { absolute_row: 0, col: 0, success: false }
    }
}

/// 设置选区
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_set_selection(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
    start_absolute_row: i64,
    start_col: usize,
    end_absolute_row: i64,
    end_col: usize,
) -> bool {
    use crate::domain::primitives::AbsolutePoint;
    use crate::domain::views::SelectionType;

    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    if let Some(mut terminal) = pool.get_terminal_mut(terminal_id) {
        // 使用 start_selection + update_selection 来设置选区
        let start_pos = AbsolutePoint::new(start_absolute_row as usize, start_col);
        let end_pos = AbsolutePoint::new(end_absolute_row as usize, end_col);

        terminal.start_selection(start_pos, SelectionType::Simple);
        terminal.update_selection(end_pos);

        true
    } else {
        false
    }
}

/// 清除选区
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_clear_selection(
    handle: *mut TerminalPoolHandle,
    terminal_id: usize,
) -> bool {
    if handle.is_null() {
        return false;
    }

    let pool = unsafe { &mut *(handle as *mut TerminalPool) };

    if let Some(mut terminal) = pool.get_terminal_mut(terminal_id) {
        terminal.clear_selection();
        true
    } else {
        false
    }
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

// ============================================================================
// Word Boundary Detection FFI - 分词相关
// ============================================================================

/// 词边界结果（C ABI 兼容）
#[cfg(feature = "new_architecture")]
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FFIWordBoundary {
    /// 单词起始列（屏幕坐标）
    pub start_col: u16,
    /// 单词结束列（屏幕坐标，包含）
    pub end_col: u16,
    /// 绝对行号
    pub absolute_row: i64,
    /// 单词文本指针（需要调用者使用 terminal_pool_free_word_boundary 释放）
    pub text_ptr: *mut c_char,
    /// 文本长度（字节）
    pub text_len: usize,
    /// 是否有效
    pub valid: bool,
}

#[cfg(not(feature = "new_architecture"))]
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FFIWordBoundary {
    pub start_col: u16,
    pub end_col: u16,
    pub absolute_row: i64,
    pub text_ptr: *mut c_char,
    pub text_len: usize,
    pub valid: bool,
}

impl Default for FFIWordBoundary {
    fn default() -> Self {
        Self {
            start_col: 0,
            end_col: 0,
            absolute_row: 0,
            text_ptr: std::ptr::null_mut(),
            text_len: 0,
            valid: false,
        }
    }
}

/// 获取指定位置的单词边界
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
/// - `screen_row`: 屏幕行（0-based）
/// - `screen_col`: 屏幕列（0-based）
///
/// # 返回
/// - `FFIWordBoundary`: 单词边界信息，失败时 valid=false
///
/// # 分词规则（参考 Swift WordBoundaryDetector）
/// 1. 中文字符：连续中文算一个词
/// 2. 英文/数字/下划线：连续算一个词
/// 3. 空白符号：作为分隔符
/// 4. 其他符号：独立成词
///
/// # 注意
/// - 返回的 text_ptr 需要调用者使用 `terminal_pool_free_word_boundary` 释放
/// - 如果 valid=false，text_ptr 为 null，不需要释放
#[cfg(feature = "new_architecture")]
#[no_mangle]
pub extern "C" fn terminal_pool_get_word_at(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
    screen_row: i32,
    screen_col: i32,
) -> FFIWordBoundary {
    if handle.is_null() || screen_row < 0 || screen_col < 0 {
        return FFIWordBoundary::default();
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    if let Some(terminal) = pool.get_terminal(terminal_id as usize) {
        let state = terminal.state();
        let grid = &state.grid;

        // 验证坐标有效性
        if screen_row as usize >= grid.lines() || screen_col as usize >= grid.columns() {
            return FFIWordBoundary::default();
        }

        // 获取行数据
        if let Some(row) = grid.row(screen_row as usize) {
            let cells = row.cells();
            let position = screen_col as usize;

            // 检查位置是否在范围内
            if position >= cells.len() {
                return FFIWordBoundary::default();
            }

            // 执行分词
            let (start_col, end_col) = find_word_boundary(cells, position);

            // 提取文本
            let word_text: String = cells[start_col..=end_col]
                .iter()
                .map(|cell| cell.c)
                .collect();

            // 转换为绝对行号
            let absolute_row = grid.screen_to_absolute(screen_row as usize, 0).line as i64;

            // 分配 C 字符串
            match std::ffi::CString::new(word_text.as_bytes()) {
                Ok(c_string) => {
                    let ptr = c_string.into_raw();
                    FFIWordBoundary {
                        start_col: start_col as u16,
                        end_col: end_col as u16,
                        absolute_row,
                        text_ptr: ptr,
                        text_len: word_text.len(),
                        valid: true,
                    }
                }
                Err(_) => FFIWordBoundary::default(),
            }
        } else {
            FFIWordBoundary::default()
        }
    } else {
        FFIWordBoundary::default()
    }
}

#[cfg(not(feature = "new_architecture"))]
#[no_mangle]
pub extern "C" fn terminal_pool_get_word_at(
    _handle: *mut TerminalPoolHandle,
    _terminal_id: i32,
    _screen_row: i32,
    _screen_col: i32,
) -> FFIWordBoundary {
    FFIWordBoundary::default()
}

/// 释放单词边界资源
///
/// # 参数
/// - `boundary`: 由 `terminal_pool_get_word_at` 返回的边界
///
/// # 安全性
/// - 只应该对 valid=true 的边界调用此函数
/// - 不要对同一个边界重复释放
#[no_mangle]
pub extern "C" fn terminal_pool_free_word_boundary(boundary: FFIWordBoundary) {
    if boundary.valid && !boundary.text_ptr.is_null() {
        unsafe {
            // 重新构建 CString 并释放
            let _ = std::ffi::CString::from_raw(boundary.text_ptr);
        }
    }
}

/// 分词辅助函数
///
/// # 参数
/// - `cells`: 行的所有 cell 数据
/// - `position`: 点击位置（列索引）
///
/// # 返回
/// - `(start_col, end_col)`: 单词的起始和结束列（包含）
///
/// # 分词规则
/// 1. 中文字符（CJK）：连续中文算一个词
/// 2. 英文/数字/下划线：连续算一个词
/// 3. 空白符号：作为分隔符
/// 4. 其他符号：独立成词
#[cfg(feature = "new_architecture")]
fn find_word_boundary(cells: &[crate::domain::views::grid::CellData], position: usize) -> (usize, usize) {
    if cells.is_empty() || position >= cells.len() {
        return (0, 0);
    }

    // 宽字符标志位（中文等占 2 列的字符）
    const WIDE_CHAR_SPACER: u16 = 0b0000_0000_0100_0000;

    // 如果点击在宽字符占位符上，向左移动到实际字符
    let mut actual_position = position;
    if cells[actual_position].flags & WIDE_CHAR_SPACER != 0 && actual_position > 0 {
        actual_position -= 1;
    }

    let target_char = cells[actual_position].c;

    // 如果点击在空白符上，返回单个空格
    if is_word_separator(target_char) {
        return (actual_position, actual_position);
    }

    let char_type = classify_char(target_char);

    // 向左扩展（跳过宽字符占位符）
    let mut start = actual_position;
    while start > 0 {
        let prev_cell = &cells[start - 1];
        // 跳过宽字符占位符
        if prev_cell.flags & WIDE_CHAR_SPACER != 0 {
            start -= 1;
            continue;
        }
        let prev_char = prev_cell.c;
        if is_word_separator(prev_char) || classify_char(prev_char) != char_type {
            break;
        }
        start -= 1;
    }

    // 向右扩展（跳过宽字符占位符）
    let mut end = actual_position;
    while end + 1 < cells.len() {
        let next_cell = &cells[end + 1];
        // 跳过宽字符占位符
        if next_cell.flags & WIDE_CHAR_SPACER != 0 {
            end += 1;
            continue;
        }
        let next_char = next_cell.c;
        if is_word_separator(next_char) || classify_char(next_char) != char_type {
            break;
        }
        end += 1;
    }

    // 确保选区包含最后一个宽字符的占位符
    while end + 1 < cells.len() && cells[end + 1].flags & WIDE_CHAR_SPACER != 0 {
        end += 1;
    }

    (start, end)
}

/// 字符类型
#[cfg(feature = "new_architecture")]
#[derive(Debug, PartialEq, Eq)]
enum CharType {
    /// 中日韩字符（CJK）
    CJK,
    /// 字母数字下划线
    Alphanumeric,
    /// 其他符号
    Symbol,
}

/// 分类字符
#[cfg(feature = "new_architecture")]
fn classify_char(ch: char) -> CharType {
    // 中日韩字符（Unicode CJK 块）
    if is_cjk(ch) {
        return CharType::CJK;
    }

    // 字母、数字、下划线
    if ch.is_alphanumeric() || ch == '_' {
        return CharType::Alphanumeric;
    }

    // 其他符号
    CharType::Symbol
}

/// 判断是否为 CJK 字符
#[cfg(feature = "new_architecture")]
fn is_cjk(ch: char) -> bool {
    let code = ch as u32;
    // CJK Unified Ideographs
    (0x4E00..=0x9FFF).contains(&code) ||
    // CJK Extension A
    (0x3400..=0x4DBF).contains(&code) ||
    // CJK Extension B-F
    (0x20000..=0x2A6DF).contains(&code) ||
    // CJK Compatibility Ideographs
    (0xF900..=0xFAFF).contains(&code) ||
    // Hangul (韩文)
    (0xAC00..=0xD7AF).contains(&code) ||
    // Hiragana and Katakana (日文假名)
    (0x3040..=0x309F).contains(&code) ||
    (0x30A0..=0x30FF).contains(&code)
}

/// 判断是否为分隔符
#[cfg(feature = "new_architecture")]
fn is_word_separator(ch: char) -> bool {
    // 下划线不是分隔符
    if ch == '_' {
        return false;
    }

    // 空白符
    if ch.is_whitespace() {
        return true;
    }

    // ASCII 标点
    if ch.is_ascii_punctuation() {
        return true;
    }

    // 中文标点（常见的）
    // 使用 Unicode 码点范围检查
    let code = ch as u32;

    // 中文标点符号块
    // CJK Symbols and Punctuation: U+3000..U+303F
    if (0x3000..=0x303F).contains(&code) {
        return true;
    }

    // 全角 ASCII 标点: U+FF00..U+FFEF（全角标点）
    if (0xFF01..=0xFF0F).contains(&code) ||  // ！"＃＄％等
       (0xFF1A..=0xFF1F).contains(&code) ||  // ：；＜＝＞？
       (0xFF3B..=0xFF40).contains(&code) ||  // ［＼］＾＿｀
       (0xFF5B..=0xFF60).contains(&code) {   // ｛｜｝～
        return true;
    }

    // 其他常用中文标点
    matches!(ch,
        '\u{2014}' |  // — (EM DASH)
        '\u{2026}' |  // … (HORIZONTAL ELLIPSIS)
        '\u{00B7}' |  // · (MIDDLE DOT)
        '\u{201C}' | '\u{201D}' |  // " " (双引号)
        '\u{2018}' | '\u{2019}'    // ' ' (单引号)
    )
}

// ============================================================================
// Tests - 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试 terminal_pool_get_cursor - 初始光标位置
    #[test]
    fn test_terminal_pool_get_cursor_initial() {
        // 由于 TerminalPool::new 需要有效的 window_handle，
        // 我们无法在测试中创建真实的 TerminalPool
        // 这里只测试 FFICursorPosition 结构体的基本功能

        let valid_cursor = FFICursorPosition {
            col: 10,
            row: 5,
            valid: true,
        };

        assert_eq!(valid_cursor.col, 10);
        assert_eq!(valid_cursor.row, 5);
        assert!(valid_cursor.valid);

        let invalid_cursor = FFICursorPosition {
            col: 0,
            row: 0,
            valid: false,
        };

        assert_eq!(invalid_cursor.col, 0);
        assert_eq!(invalid_cursor.row, 0);
        assert!(!invalid_cursor.valid);
    }

    /// 测试 terminal_pool_get_cursor - 空句柄
    #[test]
    fn test_terminal_pool_get_cursor_null_handle() {
        let result = terminal_pool_get_cursor(std::ptr::null_mut(), 0);

        assert_eq!(result.col, 0);
        assert_eq!(result.row, 0);
        assert!(!result.valid);
    }

    /// 测试 FFICursorPosition 的 C ABI 兼容性
    #[test]
    fn test_ffi_cursor_position_size_and_alignment() {
        use std::mem::{size_of, align_of};

        // 验证结构体大小符合预期（u16 + u16 + bool，考虑对齐）
        // u16 (2) + u16 (2) + bool (1) + padding (1) = 6 bytes
        // 但实际上会对齐到 2 的倍数，所以是 6 bytes
        let size = size_of::<FFICursorPosition>();
        assert!(size >= 5 && size <= 8, "FFICursorPosition size is {}, expected 5-8 bytes", size);

        // 验证对齐
        let alignment = align_of::<FFICursorPosition>();
        assert!(alignment >= 2, "FFICursorPosition alignment is {}, expected >= 2", alignment);
    }

    // ===== Word Boundary Tests =====

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_classify_char_english() {
        use super::{classify_char, CharType};

        assert_eq!(classify_char('a'), CharType::Alphanumeric);
        assert_eq!(classify_char('Z'), CharType::Alphanumeric);
        assert_eq!(classify_char('0'), CharType::Alphanumeric);
        assert_eq!(classify_char('9'), CharType::Alphanumeric);
        assert_eq!(classify_char('_'), CharType::Alphanumeric);
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_classify_char_cjk() {
        use super::{classify_char, CharType};

        // 中文
        assert_eq!(classify_char('中'), CharType::CJK);
        assert_eq!(classify_char('文'), CharType::CJK);
        // 日文假名
        assert_eq!(classify_char('あ'), CharType::CJK);
        assert_eq!(classify_char('ア'), CharType::CJK);
        // 韩文
        assert_eq!(classify_char('한'), CharType::CJK);
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_classify_char_symbol() {
        use super::{classify_char, CharType};

        assert_eq!(classify_char('!'), CharType::Symbol);
        assert_eq!(classify_char('@'), CharType::Symbol);
        assert_eq!(classify_char('#'), CharType::Symbol);
        assert_eq!(classify_char('$'), CharType::Symbol);
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_is_word_separator() {
        use super::is_word_separator;

        // 空白符
        assert!(is_word_separator(' '));
        assert!(is_word_separator('\t'));
        assert!(is_word_separator('\n'));

        // ASCII 标点
        assert!(is_word_separator('.'));
        assert!(is_word_separator(','));
        assert!(is_word_separator('!'));
        assert!(is_word_separator('?'));

        // 非分隔符
        assert!(!is_word_separator('a'));
        assert!(!is_word_separator('中'));
        assert!(!is_word_separator('_'));
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_find_word_boundary_english() {
        use super::find_word_boundary;
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello world
        let text = "hello world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 'e' (position=1)
        let (start, end) = find_word_boundary(&cells, 1);
        assert_eq!(start, 0);
        assert_eq!(end, 4);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "hello");

        // 点击 'w' (position=6)
        let (start, end) = find_word_boundary(&cells, 6);
        assert_eq!(start, 6);
        assert_eq!(end, 10);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "world");

        // 点击空格 (position=5)
        let (start, end) = find_word_boundary(&cells, 5);
        assert_eq!(start, 5);
        assert_eq!(end, 5);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, " ");
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_find_word_boundary_chinese() {
        use super::find_word_boundary;
        use crate::domain::views::grid::CellData;

        // 创建测试数据：你好世界
        let text = "你好世界";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 '好' (position=1)
        let (start, end) = find_word_boundary(&cells, 1);
        assert_eq!(start, 0);
        assert_eq!(end, 3); // 连续 CJK 算一个词
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "你好世界");
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_find_word_boundary_mixed() {
        use super::find_word_boundary;
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello 世界
        let text = "hello 世界";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 'l' (position=2)
        let (start, end) = find_word_boundary(&cells, 2);
        assert_eq!(start, 0);
        assert_eq!(end, 4);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "hello");

        // 点击 '世' (position=6)
        let (start, end) = find_word_boundary(&cells, 6);
        assert_eq!(start, 6);
        assert_eq!(end, 7);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "世界");
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_find_word_boundary_underscore() {
        use super::find_word_boundary;
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello_world
        let text = "hello_world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 '_' (position=5)
        let (start, end) = find_word_boundary(&cells, 5);
        assert_eq!(start, 0);
        assert_eq!(end, 10); // 下划线算字母数字
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "hello_world");
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_find_word_boundary_symbol() {
        use super::find_word_boundary;
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello@world
        let text = "hello@world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 '@' (position=5)
        let (start, end) = find_word_boundary(&cells, 5);
        assert_eq!(start, 5);
        assert_eq!(end, 5); // 符号独立成词
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "@");
    }

    #[cfg(feature = "new_architecture")]
    #[test]
    fn test_find_word_boundary_edge_cases() {
        use super::find_word_boundary;
        use crate::domain::views::grid::CellData;

        // 空数组
        let cells: Vec<CellData> = Vec::new();
        let (start, end) = find_word_boundary(&cells, 0);
        assert_eq!(start, 0);
        assert_eq!(end, 0);

        // 单字符
        let text = "a";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();
        let (start, end) = find_word_boundary(&cells, 0);
        assert_eq!(start, 0);
        assert_eq!(end, 0);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "a");

        // 行首
        let text = "hello world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();
        let (start, end) = find_word_boundary(&cells, 0);
        assert_eq!(start, 0);
        assert_eq!(end, 4);

        // 行尾
        let (start, end) = find_word_boundary(&cells, 10);
        assert_eq!(start, 6);
        assert_eq!(end, 10);
    }

    #[test]
    fn test_ffi_word_boundary_default() {
        let boundary = FFIWordBoundary::default();
        assert_eq!(boundary.start_col, 0);
        assert_eq!(boundary.end_col, 0);
        assert_eq!(boundary.absolute_row, 0);
        assert!(boundary.text_ptr.is_null());
        assert_eq!(boundary.text_len, 0);
        assert!(!boundary.valid);
    }

    #[test]
    fn test_terminal_pool_get_word_at_null_handle() {
        let result = terminal_pool_get_word_at(std::ptr::null_mut(), 0, 0, 0);
        assert!(!result.valid);
        assert!(result.text_ptr.is_null());
    }

    #[test]
    fn test_terminal_pool_free_word_boundary_invalid() {
        // 释放无效边界不应该崩溃
        let boundary = FFIWordBoundary::default();
        terminal_pool_free_word_boundary(boundary);
    }
}
