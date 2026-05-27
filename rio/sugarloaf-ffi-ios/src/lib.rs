use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::Arc;
use sugarloaf::font::FontLibrary;
use sugarloaf::layout::{RichTextLayout, RootStyle, BuilderLine, FragmentData, FragmentStyle};
use sugarloaf::{Object, RichText, Sugarloaf, SugarloafRenderer, SugarloafWindow, SugarloafWindowSize};
use sugarloaf::context::GpuContext;

use terminal_core::crosswords::Crosswords;
use terminal_core::grid::Dimensions;
use terminal_core::grid::row::Row;
use terminal_core::pos::Column;
use terminal_core::square::{Flags, Square};
use terminal_core::colors::{AnsiColor, NamedColor};
use terminal_core::event::VoidListener;
use terminal_core::handler::Processor;

use render_core::{
    FontContext, TextShaper, GlyphAtlas, GlyphRasterizer, BlockDrawer,
    GlyphKey, FontMetrics, compute_font_metrics, is_drawable_block_char,
};

// ---------------------------------------------------------------------------
// Terminal grid dimensions helper
// ---------------------------------------------------------------------------

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
    fn total_lines(&self) -> usize { self.rows + 1000 }
    fn screen_lines(&self) -> usize { self.rows }
    fn columns(&self) -> usize { self.cols }
    fn square_width(&self) -> f32 { 0.0 }
    fn square_height(&self) -> f32 { 0.0 }
}

// ---------------------------------------------------------------------------
// ANSI color mapping
// ---------------------------------------------------------------------------

fn named_color_to_rgba(color: NamedColor) -> [f32; 4] {
    match color {
        NamedColor::Black       => [0.00, 0.00, 0.00, 1.0],
        NamedColor::Red         => [0.80, 0.14, 0.11, 1.0],
        NamedColor::Green       => [0.30, 0.73, 0.09, 1.0],
        NamedColor::Yellow      => [0.77, 0.63, 0.00, 1.0],
        NamedColor::Blue        => [0.20, 0.46, 0.82, 1.0],
        NamedColor::Magenta     => [0.69, 0.35, 0.74, 1.0],
        NamedColor::Cyan        => [0.02, 0.68, 0.68, 1.0],
        NamedColor::White       => [0.82, 0.82, 0.82, 1.0],
        NamedColor::LightBlack   => [0.33, 0.33, 0.33, 1.0],
        NamedColor::LightRed     => [0.94, 0.35, 0.31, 1.0],
        NamedColor::LightGreen   => [0.45, 0.82, 0.31, 1.0],
        NamedColor::LightYellow  => [0.99, 0.86, 0.37, 1.0],
        NamedColor::LightBlue    => [0.45, 0.66, 0.95, 1.0],
        NamedColor::LightMagenta => [0.82, 0.53, 0.87, 1.0],
        NamedColor::LightCyan    => [0.32, 0.87, 0.87, 1.0],
        NamedColor::LightWhite   => [0.93, 0.93, 0.93, 1.0],
        NamedColor::DimBlack     => [0.00, 0.00, 0.00, 1.0],
        NamedColor::DimRed       => [0.56, 0.10, 0.08, 1.0],
        NamedColor::DimGreen     => [0.21, 0.51, 0.06, 1.0],
        NamedColor::DimYellow    => [0.54, 0.44, 0.00, 1.0],
        NamedColor::DimBlue      => [0.14, 0.32, 0.57, 1.0],
        NamedColor::DimMagenta   => [0.48, 0.25, 0.52, 1.0],
        NamedColor::DimCyan      => [0.01, 0.48, 0.48, 1.0],
        NamedColor::DimWhite     => [0.57, 0.57, 0.57, 1.0],
        NamedColor::Foreground      => [0.90, 0.90, 0.90, 1.0],
        NamedColor::Background      => [0.12, 0.12, 0.15, 1.0],
        NamedColor::Cursor          => [0.90, 0.90, 0.90, 1.0],
        NamedColor::LightForeground => [1.00, 1.00, 1.00, 1.0],
        NamedColor::DimForeground   => [0.63, 0.63, 0.63, 1.0],
    }
}

fn ansi_color_to_rgba(color: &AnsiColor) -> [f32; 4] {
    match color {
        AnsiColor::Named(named) => named_color_to_rgba(*named),
        AnsiColor::Spec(rgb) => rgb.to_arr(),
        AnsiColor::Indexed(idx) => {
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
                16..=231 => {
                    let n = idx - 16;
                    let b = (n % 6) as f32;
                    let g = ((n / 6) % 6) as f32;
                    let r = (n / 36) as f32;
                    let to_f = |v: f32| -> f32 {
                        if v == 0.0 { 0.0 } else { (55.0 + 40.0 * v) / 255.0 }
                    };
                    [to_f(r), to_f(g), to_f(b), 1.0]
                }
                232..=255 => {
                    let level = (8 + 10 * (idx - 232)) as f32 / 255.0;
                    [level, level, level, 1.0]
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Row → BuilderLine conversion
// ---------------------------------------------------------------------------

fn row_to_builder_line(row: &Row<Square>, cols: usize) -> BuilderLine {
    let mut fragments = Vec::new();
    let mut current_content = String::new();
    let mut current_style: Option<FragmentStyle> = None;

    for col_idx in 0..cols.min(row.len()) {
        let sq = &row[Column(col_idx)];

        if sq.flags.contains(Flags::WIDE_CHAR_SPACER) {
            continue;
        }

        let style = square_to_fragment_style(sq);
        let ch = if sq.c == '\0' || sq.c == '\t' { ' ' } else { sq.c };

        if let Some(ref prev_style) = current_style {
            if !fragment_styles_equal(prev_style, &style) {
                if !current_content.is_empty() {
                    fragments.push(FragmentData {
                        content: current_content.clone(),
                        style: prev_style.clone(),
                    });
                    current_content.clear();
                }
                current_style = Some(style);
            }
        } else {
            current_style = Some(style);
        }

        current_content.push(ch);

        if let Some(zerowidth) = sq.zerowidth() {
            for &zw in zerowidth {
                current_content.push(zw);
            }
        }
    }

    if !current_content.is_empty() {
        if let Some(style) = current_style {
            fragments.push(FragmentData {
                content: current_content,
                style,
            });
        }
    }

    BuilderLine {
        fragments,
        ..Default::default()
    }
}

fn square_to_fragment_style(sq: &Square) -> FragmentStyle {
    let mut fg = ansi_color_to_rgba(&sq.fg);

    if sq.flags.contains(Flags::INVERSE) {
        fg = ansi_color_to_rgba(&sq.bg);
        if sq.bg == AnsiColor::Named(NamedColor::Background) {
            fg = named_color_to_rgba(NamedColor::Black);
        }
    }

    if sq.flags.contains(Flags::DIM) {
        fg[0] *= 0.67;
        fg[1] *= 0.67;
        fg[2] *= 0.67;
    }

    if sq.flags.contains(Flags::HIDDEN) {
        fg[3] = 0.0;
    }

    let mut bg_color: Option<[f32; 4]> = None;
    if sq.flags.contains(Flags::INVERSE) || sq.bg != AnsiColor::Named(NamedColor::Background) {
        let bg = if sq.flags.contains(Flags::INVERSE) {
            ansi_color_to_rgba(&sq.fg)
        } else {
            ansi_color_to_rgba(&sq.bg)
        };
        if bg[3] > 0.01 {
            bg_color = Some(bg);
        }
    }

    let width = if sq.flags.contains(Flags::WIDE_CHAR) { 2.0 } else { 1.0 };

    FragmentStyle {
        color: fg,
        background_color: bg_color,
        width,
        ..FragmentStyle::default()
    }
}

fn fragment_styles_equal(a: &FragmentStyle, b: &FragmentStyle) -> bool {
    a.color == b.color
        && a.background_color == b.background_color
        && a.width == b.width
        && a.font_attrs == b.font_attrs
}

// ---------------------------------------------------------------------------
// FFI handle
// ---------------------------------------------------------------------------

struct SugarloafIosHandle {
    sugarloaf: Sugarloaf,
    crosswords: Crosswords<VoidListener>,
    processor: Processor,
    has_content: bool,
    view_width: f32,
    view_height: f32,
    user_scale: f32,
    user_offset_x: f32,
    user_offset_y: f32,
    // render-core components (created once)
    font_context: Arc<FontContext>,
    text_shaper: TextShaper,
    glyph_rasterizer: GlyphRasterizer,
    glyph_atlas: GlyphAtlas,
    block_drawer: BlockDrawer,
    cached_metrics: Option<FontMetrics>,
    cached_scale: f32,
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

    // Build render-core components (clone FontLibrary — just Arc clone, zero-cost)
    let font_context = Arc::new(FontContext::new(font_library.clone()));
    let text_shaper = TextShaper::new(font_context.clone());
    let glyph_rasterizer = GlyphRasterizer::new();
    let glyph_atlas = GlyphAtlas::new();
    let block_drawer = BlockDrawer::new();

    let mut sugarloaf = match Sugarloaf::new(window, renderer, &font_library, layout) {
        Ok(s) => s,
        Err(e) => e.instance,
    };

    sugarloaf.set_background_color(Some(skia_safe::Color4f::new(0.12, 0.12, 0.15, 1.0)));

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
        crosswords,
        processor,
        has_content: false,
        view_width: width,
        view_height: height,
        user_scale: 1.0,
        user_offset_x: 0.0,
        user_offset_y: 0.0,
        font_context,
        text_shaper,
        glyph_rasterizer,
        glyph_atlas,
        block_drawer,
        cached_metrics: None,
        cached_scale: scale,
    });

    Box::into_raw(handle) as *mut c_void
}

// ---------------------------------------------------------------------------
// FFI: write PTY bytes
// ---------------------------------------------------------------------------

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
    h.processor.advance(&mut h.crosswords, bytes);
    h.has_content = true;
}

// ---------------------------------------------------------------------------
// FFI: resize grid
// ---------------------------------------------------------------------------

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
    h.user_scale = 1.0;
    h.user_offset_x = 0.0;
    h.user_offset_y = 0.0;
}

// ---------------------------------------------------------------------------
// FFI: render (render-core pipeline)
// ---------------------------------------------------------------------------

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

    canvas.clear(skia_safe::Color4f::new(0.12, 0.12, 0.15, 1.0));

    if !h.has_content {
        h.sugarloaf.ctx.end_frame(drawable);
        return true;
    }

    // Get font metrics (cached, rounded to integer pixels)
    let font_size_phys = 16.0 * device_scale;
    let metrics = match h.cached_metrics {
        Some(m) if h.cached_scale == device_scale => m,
        _ => {
            let m = compute_font_metrics(font_size_phys, &h.font_context);
            h.cached_metrics = Some(m);
            h.cached_scale = device_scale;
            m
        }
    };

    let cell_width = metrics.cell_width;
    let cell_height = metrics.cell_height;
    let baseline_offset = metrics.baseline_offset;
    let line_height = cell_height * 1.2;

    // Scale-to-fit
    let cols = h.crosswords.columns() as f32;
    let num_rows = h.crosswords.screen_lines() as f32;
    let content_w = cols * cell_width;
    let content_h = num_rows * line_height;
    let viewport_w = h.view_width * device_scale;
    let viewport_h = h.view_height * device_scale;

    let fit_scale = if content_w > 0.0 && content_h > 0.0 {
        (viewport_w / content_w).min(viewport_h / content_h).min(1.0)
    } else {
        1.0
    };
    let total_scale = fit_scale * h.user_scale;

    canvas.save();
    canvas.scale((total_scale, total_scale));
    canvas.translate((h.user_offset_x * device_scale / total_scale,
                      h.user_offset_y * device_scale / total_scale));

    let mut bg_paint = skia_safe::Paint::default();

    let rows = h.crosswords.visible_rows();
    let num_cols = h.crosswords.columns();

    for (row_idx, row) in rows.iter().enumerate() {
        let y_offset = (row_idx as f32) * line_height;

        // Build BuilderLine from Crosswords row
        let builder_line = row_to_builder_line(row, num_cols);

        // Text shaping via render-core
        let layout = h.text_shaper.shape_line(&builder_line, font_size_phys, cell_width);

        // Render using GlyphAtlas pipeline
        let mut xforms: Vec<skia_safe::RSXform> = Vec::with_capacity(layout.glyphs.len());
        let mut tex_rects: Vec<skia_safe::Rect> = Vec::with_capacity(layout.glyphs.len());
        let mut colors: Vec<skia_safe::Color> = Vec::with_capacity(layout.glyphs.len());

        for glyph in &layout.glyphs {
            // Draw background
            if let Some(bg) = glyph.background_color {
                bg_paint.set_color4f(bg, None);
                let bg_width = cell_width * glyph.width;
                canvas.draw_rect(
                    skia_safe::Rect::from_xywh(glyph.x, y_offset, bg_width, line_height),
                    &bg_paint,
                );
            }

            // Block characters → BlockDrawer
            let first_char = glyph.grapheme.chars().next().unwrap_or(' ');
            if glyph.grapheme.chars().count() == 1 && is_drawable_block_char(first_char) {
                h.block_drawer.draw(
                    canvas,
                    first_char,
                    glyph.x,
                    y_offset,
                    cell_width * glyph.width,
                    line_height,
                    glyph.color,
                    device_scale,
                );
                continue;
            }

            // Emoji → Paragraph API
            if glyph.is_emoji() {
                let mut paint = skia_safe::Paint::default();
                paint.set_anti_alias(true);
                paint.set_color4f(glyph.color, None);
                canvas.draw_str(
                    &glyph.grapheme,
                    skia_safe::Point::new(glyph.x, y_offset + baseline_offset),
                    &glyph.font,
                    &paint,
                );
                continue;
            }

            // Normal characters → GlyphAtlas batch
            let key = GlyphRasterizer::make_key(glyph, font_size_phys);
            let region = h.glyph_atlas.get_or_rasterize(key, || {
                h.glyph_rasterizer.rasterize(glyph, cell_width, cell_height, baseline_offset)
            });

            if let Some(region) = region {
                if region.width > 0 && region.height > 0 {
                    let (_, bounds) = glyph.font.measure_str(&glyph.grapheme, None);
                    let x_offset = if bounds.left < 0.0 { -bounds.left + 1.0 } else { 1.0 };

                    xforms.push(skia_safe::RSXform::new(
                        1.0, 0.0,
                        skia_safe::Vector::new(glyph.x - x_offset, y_offset),
                    ));
                    tex_rects.push(region.to_src_rect());
                    colors.push(glyph.color.to_color());
                }
            }
        }

        // Batch draw all normal characters for this row
        if !xforms.is_empty() {
            let atlas_image = h.glyph_atlas.get_image();
            canvas.draw_atlas(
                atlas_image,
                &xforms,
                &tex_rects,
                Some(colors.as_slice()),
                skia_safe::BlendMode::Modulate,
                skia_safe::SamplingOptions::default(),
                None,
                None,
            );
        }
    }

    canvas.restore();
    h.sugarloaf.ctx.end_frame(drawable);
    true
}

// ---------------------------------------------------------------------------
// FFI: diagnostic render (unchanged)
// ---------------------------------------------------------------------------

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

    let mut rect_paint = skia_safe::Paint::default();
    rect_paint.set_color(skia_safe::Color::from_rgb(0, 200, 50));
    rect_paint.set_anti_alias(true);
    canvas.draw_rect(
        skia_safe::Rect::from_xywh(20.0 * scale, 20.0 * scale, 360.0 * scale, 40.0 * scale),
        &rect_paint,
    );

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

        canvas.draw_str("Hello from Skia on iOS!", skia_safe::Point::new(30.0 * scale, 100.0 * scale), &font, &text_paint);
        canvas.draw_str("$ sugarloaf rendering pipeline OK", skia_safe::Point::new(30.0 * scale, 140.0 * scale), &font, &text_paint);
        canvas.draw_str("ETerm x Vlaude - Terminal on iPhone", skia_safe::Point::new(30.0 * scale, 180.0 * scale), &font, &text_paint);
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
    let scale = h.sugarloaf.ctx.scale();
    let font_size_phys = 16.0 * scale;
    let metrics = compute_font_metrics(font_size_phys, &h.font_context);
    unsafe {
        *out_cell_width = metrics.cell_width / scale;
        *out_cell_height = metrics.cell_height / scale;
    }
    true
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
