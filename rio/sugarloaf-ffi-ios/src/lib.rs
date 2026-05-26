use std::ffi::c_void;
use std::ptr::NonNull;
use sugarloaf::font::FontLibrary;
use sugarloaf::layout::{RichTextLayout, RootStyle};
use sugarloaf::{FragmentStyle, Object, RichText, Sugarloaf, SugarloafRenderer, SugarloafWindow, SugarloafWindowSize};
use sugarloaf::context::GpuContext;

use terminal_core::crosswords::Crosswords;
use terminal_core::grid::Dimensions;
use terminal_core::pos::Column;
use terminal_core::square::{Flags, Square};
use terminal_core::colors::{AnsiColor, NamedColor};
use terminal_core::event::VoidListener;
use terminal_core::handler::Processor;

// ---------------------------------------------------------------------------
// Terminal grid dimensions helper
// ---------------------------------------------------------------------------

/// Minimal Dimensions impl for creating/resizing the Crosswords grid.
struct TermSize {
    cols: usize,
    rows: usize,
}

impl TermSize {
    fn new(cols: usize, rows: usize) -> Self {
        Self { cols, rows }
    }
}

impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        // screen lines + scrollback history
        self.rows + 1000
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }

    fn square_width(&self) -> f32 {
        0.0
    }

    fn square_height(&self) -> f32 {
        0.0
    }
}

// ---------------------------------------------------------------------------
// ANSI color mapping (16 named colors -> RGBA f32)
// ---------------------------------------------------------------------------

/// Map a NamedColor to an RGBA [f32; 4] array.
/// Uses a standard dark-theme ANSI-16 palette.
fn named_color_to_rgba(color: NamedColor) -> [f32; 4] {
    match color {
        // Normal colors
        NamedColor::Black       => [0.00, 0.00, 0.00, 1.0],
        NamedColor::Red         => [0.80, 0.14, 0.11, 1.0],
        NamedColor::Green       => [0.30, 0.73, 0.09, 1.0],
        NamedColor::Yellow      => [0.77, 0.63, 0.00, 1.0],
        NamedColor::Blue        => [0.20, 0.46, 0.82, 1.0],
        NamedColor::Magenta     => [0.69, 0.35, 0.74, 1.0],
        NamedColor::Cyan        => [0.02, 0.68, 0.68, 1.0],
        NamedColor::White       => [0.82, 0.82, 0.82, 1.0],

        // Bright (light) colors
        NamedColor::LightBlack   => [0.33, 0.33, 0.33, 1.0],
        NamedColor::LightRed     => [0.94, 0.35, 0.31, 1.0],
        NamedColor::LightGreen   => [0.45, 0.82, 0.31, 1.0],
        NamedColor::LightYellow  => [0.99, 0.86, 0.37, 1.0],
        NamedColor::LightBlue    => [0.45, 0.66, 0.95, 1.0],
        NamedColor::LightMagenta => [0.82, 0.53, 0.87, 1.0],
        NamedColor::LightCyan    => [0.32, 0.87, 0.87, 1.0],
        NamedColor::LightWhite   => [0.93, 0.93, 0.93, 1.0],

        // Dim variants — slightly darker than normal
        NamedColor::DimBlack     => [0.00, 0.00, 0.00, 1.0],
        NamedColor::DimRed       => [0.56, 0.10, 0.08, 1.0],
        NamedColor::DimGreen     => [0.21, 0.51, 0.06, 1.0],
        NamedColor::DimYellow    => [0.54, 0.44, 0.00, 1.0],
        NamedColor::DimBlue      => [0.14, 0.32, 0.57, 1.0],
        NamedColor::DimMagenta   => [0.48, 0.25, 0.52, 1.0],
        NamedColor::DimCyan      => [0.01, 0.48, 0.48, 1.0],
        NamedColor::DimWhite     => [0.57, 0.57, 0.57, 1.0],

        // Semantic colors
        NamedColor::Foreground      => [0.90, 0.90, 0.90, 1.0],
        NamedColor::Background      => [0.12, 0.12, 0.15, 1.0],
        NamedColor::Cursor          => [0.90, 0.90, 0.90, 1.0],
        NamedColor::LightForeground => [1.00, 1.00, 1.00, 1.0],
        NamedColor::DimForeground   => [0.63, 0.63, 0.63, 1.0],
    }
}

/// Convert an AnsiColor to RGBA [f32; 4].
fn ansi_color_to_rgba(color: &AnsiColor) -> [f32; 4] {
    match color {
        AnsiColor::Named(named) => named_color_to_rgba(*named),
        AnsiColor::Spec(rgb) => rgb.to_arr(),
        AnsiColor::Indexed(idx) => {
            // Map the standard 256-color palette.
            // 0-7: normal ANSI, 8-15: bright ANSI, 16-231: 6x6x6 cube, 232-255: grayscale
            match *idx {
                0  => named_color_to_rgba(NamedColor::Black),
                1  => named_color_to_rgba(NamedColor::Red),
                2  => named_color_to_rgba(NamedColor::Green),
                3  => named_color_to_rgba(NamedColor::Yellow),
                4  => named_color_to_rgba(NamedColor::Blue),
                5  => named_color_to_rgba(NamedColor::Magenta),
                6  => named_color_to_rgba(NamedColor::Cyan),
                7  => named_color_to_rgba(NamedColor::White),
                8  => named_color_to_rgba(NamedColor::LightBlack),
                9  => named_color_to_rgba(NamedColor::LightRed),
                10 => named_color_to_rgba(NamedColor::LightGreen),
                11 => named_color_to_rgba(NamedColor::LightYellow),
                12 => named_color_to_rgba(NamedColor::LightBlue),
                13 => named_color_to_rgba(NamedColor::LightMagenta),
                14 => named_color_to_rgba(NamedColor::LightCyan),
                15 => named_color_to_rgba(NamedColor::LightWhite),
                // 6x6x6 color cube (indices 16-231)
                16..=231 => {
                    let n = idx - 16;
                    let b = (n % 6) as f32;
                    let g = ((n / 6) % 6) as f32;
                    let r = (n / 36) as f32;
                    // Each component: 0 -> 0, 1 -> 0x5f, 2 -> 0x87, 3 -> 0xaf, 4 -> 0xd7, 5 -> 0xff
                    let to_f = |v: f32| -> f32 {
                        if v == 0.0 { 0.0 } else { (55.0 + 40.0 * v) / 255.0 }
                    };
                    [to_f(r), to_f(g), to_f(b), 1.0]
                }
                // Grayscale ramp (indices 232-255)
                232..=255 => {
                    let level = (8 + 10 * (idx - 232)) as f32 / 255.0;
                    [level, level, level, 1.0]
                }
            }
        }
    }
}

/// Build a FragmentStyle from a Square, considering fg/bg and flags.
fn square_to_fragment_style(sq: &Square) -> FragmentStyle {
    let mut fg = ansi_color_to_rgba(&sq.fg);

    // Handle INVERSE flag: swap fg and bg conceptually.
    // For text rendering we only care about the foreground color applied to glyphs.
    if sq.flags.contains(Flags::INVERSE) {
        fg = ansi_color_to_rgba(&sq.bg);
        // If the original bg was "Background" (transparent), use a visible default
        if sq.bg == AnsiColor::Named(NamedColor::Background) {
            fg = named_color_to_rgba(NamedColor::Black);
        }
    }

    // Handle DIM flag: reduce brightness by 33%
    if sq.flags.contains(Flags::DIM) {
        fg[0] *= 0.67;
        fg[1] *= 0.67;
        fg[2] *= 0.67;
    }

    // Handle HIDDEN flag: make text invisible
    if sq.flags.contains(Flags::HIDDEN) {
        fg[3] = 0.0;
    }

    FragmentStyle {
        color: fg,
        ..FragmentStyle::default()
    }
}

// ---------------------------------------------------------------------------
// FFI handle
// ---------------------------------------------------------------------------

struct SugarloafIosHandle {
    sugarloaf: Sugarloaf,
    state_id: usize,
    crosswords: Crosswords<VoidListener>,
    processor: Processor,
    has_content: bool,
    // Viewport dimensions (logical points, from Swift bounds)
    view_width: f32,
    view_height: f32,
    // User gesture state
    user_scale: f32,      // pinch zoom (1.0 = no zoom)
    user_offset_x: f32,   // pan X (logical points)
    user_offset_y: f32,   // pan Y (logical points)
}

// ---------------------------------------------------------------------------
// FFI: create
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn sugarloaf_ios_create(
    ui_view: *mut c_void,
    width: f32,
    height: f32,
    scale: f32,
) -> *mut c_void {
    if ui_view.is_null() {
        return std::ptr::null_mut();
    }

    let raw_window = {
        use raw_window_handle::{RawWindowHandle, UiKitWindowHandle};
        let handle = UiKitWindowHandle::new(NonNull::new(ui_view).unwrap());
        RawWindowHandle::UiKit(handle)
    };

    let raw_display = {
        use raw_window_handle::{RawDisplayHandle, UiKitDisplayHandle};
        RawDisplayHandle::UiKit(UiKitDisplayHandle::new())
    };

    let window = SugarloafWindow {
        handle: raw_window,
        display: raw_display,
        size: SugarloafWindowSize { width, height },
        scale,
    };

    let renderer = SugarloafRenderer::default();
    let fonts = sugarloaf::font::fonts::SugarloafFonts::default();
    let (font_library, _errors) = FontLibrary::new(fonts);
    let layout = RootStyle::new(scale, 16.0, 1.2);

    let mut sugarloaf = match Sugarloaf::new(window, renderer, &font_library, layout) {
        Ok(s) => s,
        Err(e) => e.instance,
    };

    sugarloaf.set_background_color(Some(skia_safe::Color4f::new(0.12, 0.12, 0.15, 1.0)));

    let rt_layout = RichTextLayout::from_default_layout(&RootStyle::new(scale, 16.0, 1.2));
    let state_id = sugarloaf.content().create_state(&rt_layout);

    sugarloaf.set_objects(vec![
        Object::RichText(RichText {
            id: state_id,
            position: [0.0, 0.0],
            lines: None,
        }),
    ]);

    // Create a minimal grid — will be resized when AttachReady arrives with real cols/rows
    let term_size = TermSize::new(80, 24);
    let crosswords = Crosswords::new(
        term_size,
        terminal_core::mode::CursorShape::Block,
        VoidListener,
        0u64.into(),
        0,
    );
    let processor = Processor::new();

    let handle = Box::new(SugarloafIosHandle {
        sugarloaf,
        state_id,
        crosswords,
        processor,
        has_content: false,
        view_width: width,
        view_height: height,
        user_scale: 1.0,
        user_offset_x: 0.0,
        user_offset_y: 0.0,
    });

    Box::into_raw(handle) as *mut c_void
}

// ---------------------------------------------------------------------------
// FFI: write PTY bytes
// ---------------------------------------------------------------------------

/// Feed raw PTY output bytes into the terminal emulator.
/// The bytes are parsed through the VTE state machine and applied to the
/// Crosswords grid. The next call to sugarloaf_ios_render() will display
/// the updated content.
#[no_mangle]
pub extern "C" fn sugarloaf_ios_write_pty(
    handle: *mut c_void,
    data: *const u8,
    len: usize,
) {
    if handle.is_null() || data.is_null() || len == 0 {
        return;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };

    // Feed bytes through the VTE processor into Crosswords.
    // Processor::advance wraps copa::Parser and dispatches to Crosswords
    // via the Handler trait.
    h.processor.advance(&mut h.crosswords, bytes);
    h.has_content = true;
}

// ---------------------------------------------------------------------------
// FFI: resize grid
// ---------------------------------------------------------------------------

/// Resize the terminal grid to new column/row dimensions.
/// Should be called when the terminal viewport size changes
/// (e.g., after a device rotation or window resize on iPad).
#[no_mangle]
pub extern "C" fn sugarloaf_ios_resize_grid(
    handle: *mut c_void,
    cols: u32,
    rows: u32,
) {
    if handle.is_null() || cols == 0 || rows == 0 {
        return;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };
    let size = TermSize::new(cols as usize, rows as usize);
    h.crosswords.resize(size);
    // Reset user zoom/pan when grid size changes
    h.user_scale = 1.0;
    h.user_offset_x = 0.0;
    h.user_offset_y = 0.0;
}

// ---------------------------------------------------------------------------
// FFI: render
// ---------------------------------------------------------------------------

/// Render the current terminal grid content directly via Skia.
///
/// Bypasses sugarloaf's RichText pipeline so we can apply canvas transforms
/// (scale-to-fit + user pinch zoom + pan offset). Each cell is drawn
/// character-by-character with proper ANSI color mapping.
#[no_mangle]
pub extern "C" fn sugarloaf_ios_render(handle: *mut c_void) -> bool {
    if handle.is_null() {
        return false;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };

    let frame = h.sugarloaf.ctx.begin_frame();
    if frame.is_none() {
        return false;
    }

    let (mut surface, drawable) = frame.unwrap();
    let canvas = surface.canvas();
    let device_scale = h.sugarloaf.ctx.scale();

    // Clear background
    canvas.clear(skia_safe::Color4f::new(0.12, 0.12, 0.15, 1.0));

    if !h.has_content {
        h.sugarloaf.ctx.end_frame(drawable);
        return true;
    }

    // Get font
    let font_mgr = skia_safe::FontMgr::new();
    let typeface = font_mgr
        .match_family_style("Cascadia Code", skia_safe::FontStyle::normal())
        .or_else(|| font_mgr.match_family_style("Menlo", skia_safe::FontStyle::normal()))
        .or_else(|| font_mgr.match_family_style("Courier", skia_safe::FontStyle::normal()));

    let typeface = match typeface {
        Some(tf) => tf,
        None => {
            h.sugarloaf.ctx.end_frame(drawable);
            return false;
        }
    };

    // All rendering in physical pixels. Font metrics are in physical pixels.
    let font_size_phys = 16.0 * device_scale;
    let font = skia_safe::Font::from_typeface(&typeface, font_size_phys);
    let (_, metrics) = font.metrics();
    let (cell_width, _) = font.measure_str("M", None);
    let cell_height = (-metrics.ascent + metrics.descent + metrics.leading) * 1.2;
    let baseline_offset = -metrics.ascent;

    // Calculate scale-to-fit: shrink terminal content to fit viewport
    let cols = h.crosswords.columns() as f32;
    let rows = h.crosswords.screen_lines() as f32;
    let content_w = cols * cell_width;
    let content_h = rows * cell_height;
    let viewport_w = h.view_width * device_scale;
    let viewport_h = h.view_height * device_scale;

    let fit_scale = if content_w > 0.0 && content_h > 0.0 {
        (viewport_w / content_w).min(viewport_h / content_h).min(1.0)
    } else {
        1.0
    };
    let total_scale = fit_scale * h.user_scale;

    // Apply transform: scale then translate (user pan)
    canvas.save();
    canvas.scale((total_scale, total_scale));
    canvas.translate((h.user_offset_x * device_scale / total_scale,
                      h.user_offset_y * device_scale / total_scale));

    let mut paint = skia_safe::Paint::default();
    paint.set_anti_alias(true);

    let mut bg_paint = skia_safe::Paint::default();

    // Read visible rows from the terminal grid
    let rows = h.crosswords.visible_rows();

    for (row_idx, row) in rows.iter().enumerate() {
        let y = (row_idx as f32) * cell_height + baseline_offset;

        for col_idx in 0..row.len() {
            let sq = &row[Column(col_idx)];

            if sq.flags.contains(Flags::WIDE_CHAR_SPACER) {
                continue;
            }

            let style = square_to_fragment_style(sq);
            let ch = if sq.c == '\0' || sq.c == '\t' { ' ' } else { sq.c };
            let x = (col_idx as f32) * cell_width;

            // Draw background if set
            if sq.flags.contains(Flags::INVERSE) || sq.bg != AnsiColor::Named(NamedColor::Background) {
                let bg_color = if sq.flags.contains(Flags::INVERSE) {
                    ansi_color_to_rgba(&sq.fg)
                } else {
                    ansi_color_to_rgba(&sq.bg)
                };
                if bg_color[3] > 0.01 {
                    bg_paint.set_color(skia_safe::Color::from_argb(
                        (bg_color[3] * 255.0) as u8,
                        (bg_color[0] * 255.0) as u8,
                        (bg_color[1] * 255.0) as u8,
                        (bg_color[2] * 255.0) as u8,
                    ));
                    canvas.draw_rect(
                        skia_safe::Rect::from_xywh(x, y - baseline_offset, cell_width, cell_height),
                        &bg_paint,
                    );
                }
            }

            // Draw character
            if ch != ' ' {
                paint.set_color(skia_safe::Color::from_argb(
                    (style.color[3] * 255.0) as u8,
                    (style.color[0] * 255.0) as u8,
                    (style.color[1] * 255.0) as u8,
                    (style.color[2] * 255.0) as u8,
                ));
                let ch_str = ch.to_string();
                canvas.draw_str(
                    &ch_str,
                    skia_safe::Point::new(x, y),
                    &font,
                    &paint,
                );
            }
        }
    }

    canvas.restore();
    h.sugarloaf.ctx.end_frame(drawable);
    true
}

// ---------------------------------------------------------------------------
// FFI: diagnostic render (unchanged)
// ---------------------------------------------------------------------------

/// Diagnostic render: bypass sugarloaf's rich text and draw directly with Skia.
/// Useful for isolating whether the issue is in the rendering pipeline vs font loading.
#[no_mangle]
pub extern "C" fn sugarloaf_ios_render_diagnostic(handle: *mut c_void) -> bool {
    if handle.is_null() {
        return false;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };

    let frame = h.sugarloaf.ctx.begin_frame();
    if frame.is_none() {
        return false;
    }

    let (mut surface, drawable) = frame.unwrap();
    let canvas = surface.canvas();

    canvas.clear(skia_safe::Color4f::new(0.12, 0.12, 0.15, 1.0));

    let scale = h.sugarloaf.ctx.scale();

    // draw a green rectangle to prove canvas drawing works
    let mut rect_paint = skia_safe::Paint::default();
    rect_paint.set_color(skia_safe::Color::from_rgb(0, 200, 50));
    rect_paint.set_anti_alias(true);
    canvas.draw_rect(
        skia_safe::Rect::from_xywh(20.0 * scale, 20.0 * scale, 360.0 * scale, 40.0 * scale),
        &rect_paint,
    );

    // try direct Skia text drawing with system fonts
    let font_mgr = skia_safe::FontMgr::new();
    let typeface = font_mgr
        .match_family_style("Menlo", skia_safe::FontStyle::normal())
        .or_else(|| font_mgr.match_family_style("Courier", skia_safe::FontStyle::normal()))
        .or_else(|| font_mgr.match_family_style("", skia_safe::FontStyle::normal()));

    if let Some(tf) = typeface {
        let font = skia_safe::Font::from_typeface(tf, 16.0 * scale);
        let mut text_paint = skia_safe::Paint::default();
        text_paint.set_color(skia_safe::Color::WHITE);
        text_paint.set_anti_alias(true);

        canvas.draw_str(
            "Hello from Skia on iOS!",
            skia_safe::Point::new(30.0 * scale, 100.0 * scale),
            &font,
            &text_paint,
        );
        canvas.draw_str(
            "$ sugarloaf rendering pipeline OK",
            skia_safe::Point::new(30.0 * scale, 140.0 * scale),
            &font,
            &text_paint,
        );
        canvas.draw_str(
            "ETerm x Vlaude - Terminal on iPhone",
            skia_safe::Point::new(30.0 * scale, 180.0 * scale),
            &font,
            &text_paint,
        );
    } else {
        rect_paint.set_color(skia_safe::Color::from_rgb(255, 0, 0));
        canvas.draw_rect(
            skia_safe::Rect::from_xywh(20.0 * scale, 80.0 * scale, 200.0 * scale, 30.0 * scale),
            &rect_paint,
        );
    }

    h.sugarloaf.ctx.end_frame(drawable);
    true
}

// ---------------------------------------------------------------------------
// FFI: resize surface
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn sugarloaf_ios_resize(handle: *mut c_void, width: f32, height: f32) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };
    h.view_width = width;
    h.view_height = height;
    h.sugarloaf.resize(width as u32, height as u32);
}

/// Set user gesture state (pinch zoom + pan offset).
/// `user_scale`: 1.0 = no zoom, >1 = zoom in. Clamped to [0.5, 5.0].
/// `offset_x/y`: pan offset in logical points.
#[no_mangle]
pub extern "C" fn sugarloaf_ios_set_transform(
    handle: *mut c_void,
    user_scale: f32,
    offset_x: f32,
    offset_y: f32,
) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };
    h.user_scale = user_scale.clamp(0.5, 5.0);
    h.user_offset_x = offset_x;
    h.user_offset_y = offset_y;
}

/// Get font metrics (cell width/height in logical points).
#[no_mangle]
pub extern "C" fn sugarloaf_ios_get_font_metrics(
    handle: *mut c_void,
    out_cell_width: *mut f32,
    out_cell_height: *mut f32,
) -> bool {
    if handle.is_null() || out_cell_width.is_null() || out_cell_height.is_null() {
        return false;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };
    let (cw, ch) = get_font_metrics_physical(h);
    let scale = h.sugarloaf.ctx.scale();
    unsafe {
        *out_cell_width = cw / scale;
        *out_cell_height = ch / scale;
    }
    true
}

/// Get font metrics in physical pixels. Returns (cell_width, cell_height).
fn get_font_metrics_physical(h: &SugarloafIosHandle) -> (f32, f32) {
    let scale = h.sugarloaf.ctx.scale();
    let font_size = 16.0 * scale;

    let font_mgr = skia_safe::FontMgr::new();
    let typeface = font_mgr
        .match_family_style("Cascadia Code", skia_safe::FontStyle::normal())
        .or_else(|| font_mgr.match_family_style("Menlo", skia_safe::FontStyle::normal()))
        .or_else(|| font_mgr.match_family_style("Courier", skia_safe::FontStyle::normal()));

    if let Some(tf) = typeface {
        let font = skia_safe::Font::from_typeface(tf, font_size);
        let (_, metrics) = font.metrics();
        let (cell_width, _) = font.measure_str("M", None);
        let cell_height = (-metrics.ascent + metrics.descent + metrics.leading) * 1.2;
        (cell_width, cell_height)
    } else {
        (font_size * 0.6, font_size * 1.2)
    }
}

// ---------------------------------------------------------------------------
// FFI: destroy
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn sugarloaf_ios_destroy(handle: *mut c_void) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle as *mut SugarloafIosHandle);
        }
    }
}
