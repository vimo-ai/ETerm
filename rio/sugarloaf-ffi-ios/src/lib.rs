use std::ffi::c_void;
use std::ptr::NonNull;
use sugarloaf::font::FontLibrary;
use sugarloaf::layout::{RichTextLayout, RootStyle};
use sugarloaf::{FragmentStyle, Sugarloaf, SugarloafRenderer, SugarloafWindow, SugarloafWindowSize};
use sugarloaf::context::GpuContext;

struct SugarloafIosHandle {
    sugarloaf: Sugarloaf,
    state_id: usize,
}

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

    let handle = Box::new(SugarloafIosHandle {
        sugarloaf,
        state_id,
    });

    Box::into_raw(handle) as *mut c_void
}

#[no_mangle]
pub extern "C" fn sugarloaf_ios_render(handle: *mut c_void) -> bool {
    if handle.is_null() {
        return false;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };

    // bypass sugarloaf's rich text - draw directly with Skia
    let frame = h.sugarloaf.ctx.begin_frame();
    if frame.is_none() {
        return false;
    }

    let (mut surface, drawable) = frame.unwrap();
    let canvas = surface.canvas();

    // clear background
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

    // try direct Skia text drawing
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
        // no typeface - draw a red rect as indicator
        rect_paint.set_color(skia_safe::Color::from_rgb(255, 0, 0));
        canvas.draw_rect(
            skia_safe::Rect::from_xywh(20.0 * scale, 80.0 * scale, 200.0 * scale, 30.0 * scale),
            &rect_paint,
        );
    }

    h.sugarloaf.ctx.end_frame(drawable);
    true
}

#[no_mangle]
pub extern "C" fn sugarloaf_ios_resize(handle: *mut c_void, width: f32, height: f32) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &mut *(handle as *mut SugarloafIosHandle) };
    h.sugarloaf.resize(width as u32, height as u32);
}

#[no_mangle]
pub extern "C" fn sugarloaf_ios_destroy(handle: *mut c_void) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle as *mut SugarloafIosHandle);
        }
    }
}
