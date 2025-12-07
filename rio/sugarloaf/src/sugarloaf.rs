//! # Sugarloaf - Skia 渲染引擎 (macOS only)
//!
//! 架构说明: 参见 `sugarloaf/RENDERING_ARCHITECTURE.md`
//!
//! 当前实现: 纯 Skia 渲染，通过 CAMetalLayer 使用 Metal backend

pub mod graphics;
pub mod primitives;
pub mod state;

use crate::font::{fonts::SugarloafFont, FontLibrary};
use crate::layout::{RichTextLayout, RootStyle};
use crate::sugarloaf::graphics::Graphics;
use crate::Content;
use crate::SugarDimensions;
use crate::{context::Context, Object, Quad};
use core::fmt::{Debug, Formatter};
use primitives::ImageProperties;
use raw_window_handle::{
    DisplayHandle, HandleError, HasDisplayHandle, HasWindowHandle, WindowHandle,
};
use state::SugarState;

#[cfg(target_os = "macos")]
use skia_safe::{Color4f, Font, FontMgr, FontStyle, Paint, Point, Typeface};

// ========== 脏区渲染优化：布局缓存数据结构 ==========

/// 缓存单行的布局计算结果
#[cfg(target_os = "macos")]
#[derive(Clone)]
struct CachedLineLayout {
    /// 字符列表
    chars: Vec<char>,
    /// 每个字符对应的 Typeface（字体查找结果）
    typefaces: Vec<Typeface>,
    /// 每个字符的 X 坐标（相对于行起始位置）
    positions: Vec<f32>,
    /// 字体大小（用于创建 Font）
    #[allow(dead_code)]
    font_size: f32,
    /// cell 宽度
    #[allow(dead_code)]
    cell_width: f32,
}

/// 行级布局缓存（优化版：直接使用 content hash 作为 key）
#[cfg(target_os = "macos")]
struct LineLayoutCache {
    /// Key: content_hash (u64), Value: 缓存的布局结果
    entries: std::collections::HashMap<u64, CachedLineLayout>,
}

#[cfg(target_os = "macos")]
impl LineLayoutCache {
    fn new() -> Self {
        Self {
            entries: std::collections::HashMap::new(),
        }
    }

    /// 根据 content hash 获取缓存的布局
    fn get(&self, content_hash: u64) -> Option<&CachedLineLayout> {
        self.entries.get(&content_hash)
    }

    /// 根据 content hash 存储布局
    fn set(&mut self, content_hash: u64, layout: CachedLineLayout) {
        self.entries.insert(content_hash, layout);
    }

    /// 清空缓存
    fn clear(&mut self) {
        self.entries.clear();
    }
}

// ========== 主要渲染结构体 ==========

pub struct Sugarloaf<'a> {
    pub ctx: Context<'a>,
    state: state::SugarState,
    pub background_color: Option<Color4f>,
    pub graphics: Graphics,

    // Skia rendering resources - 使用 FontLibrary 管理的字体
    #[cfg(target_os = "macos")]
    font_library: std::sync::Arc<parking_lot::RwLock<crate::font::FontLibraryData>>,
    #[cfg(target_os = "macos")]
    typeface_cache: std::cell::RefCell<std::collections::HashMap<usize, Typeface>>,
    /// 字符到 Typeface 的缓存，避免每帧都查询系统字体
    #[cfg(target_os = "macos")]
    char_font_cache: std::cell::RefCell<std::collections::HashMap<char, (Typeface, bool)>>,
    #[cfg(target_os = "macos")]
    font_size: f32,
    /// 复用的 FontMgr 实例，避免每次字体查找时重复创建
    #[cfg(target_os = "macos")]
    font_mgr: FontMgr,
    /// 布局计算结果缓存（脏区优化）
    #[cfg(target_os = "macos")]
    layout_cache: std::cell::RefCell<LineLayoutCache>,
}

#[derive(Debug)]
pub struct SugarloafErrors {
    pub fonts_not_found: Vec<SugarloafFont>,
}

pub struct SugarloafWithErrors<'a> {
    pub instance: Sugarloaf<'a>,
    pub errors: SugarloafErrors,
}

impl Debug for SugarloafWithErrors<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self.errors)
    }
}

#[derive(Copy, Clone)]
pub struct SugarloafWindowSize {
    pub width: f32,
    pub height: f32,
}

pub struct SugarloafWindow {
    pub handle: raw_window_handle::RawWindowHandle,
    pub display: raw_window_handle::RawDisplayHandle,
    pub size: SugarloafWindowSize,
    pub scale: f32,
}

pub struct SugarloafRenderer {
    pub font_features: Option<Vec<String>>,
    pub colorspace: Colorspace,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Colorspace {
    Srgb,
    DisplayP3,
    Rec2020,
}

#[cfg(target_os = "macos")]
#[allow(clippy::derivable_impls)]
impl Default for Colorspace {
    fn default() -> Colorspace {
        Colorspace::DisplayP3
    }
}

// #[cfg(not(target_os = "macos"))]
// #[allow(clippy::derivable_impls)]
// impl Default for Colorspace {
//     fn default() -> Colorspace {
//         Colorspace::Srgb
//     }
// }

impl Default for SugarloafRenderer {
    fn default() -> SugarloafRenderer {
        SugarloafRenderer {
            font_features: None,
            colorspace: Colorspace::default(),
        }
    }
}

impl SugarloafWindow {
    fn raw_window_handle(&self) -> raw_window_handle::RawWindowHandle {
        self.handle
    }

    fn raw_display_handle(&self) -> raw_window_handle::RawDisplayHandle {
        self.display
    }
}

impl HasWindowHandle for SugarloafWindow {
    fn window_handle(&self) -> std::result::Result<WindowHandle<'_>, HandleError> {
        let raw = self.raw_window_handle();
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

impl HasDisplayHandle for SugarloafWindow {
    fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
        let raw = self.raw_display_handle();
        Ok(unsafe { DisplayHandle::borrow_raw(raw) })
    }
}

unsafe impl Send for SugarloafWindow {}
unsafe impl Sync for SugarloafWindow {}

impl Sugarloaf<'_> {
    pub fn new<'a>(
        window: SugarloafWindow,
        renderer: SugarloafRenderer,
        font_library: &FontLibrary,
        layout: RootStyle,
    ) -> Result<Sugarloaf<'a>, Box<SugarloafWithErrors<'a>>> {
        let font_features = renderer.font_features.to_owned();
        let ctx = Context::new(window, renderer);

        let state = SugarState::new(layout, font_library, &font_features);

        // Initialize Skia font resources - 使用 FontLibrary
        #[cfg(target_os = "macos")]
        let font_size = state.style.font_size;

        // 启动时创建一次 FontMgr，避免每次字体查找时重复创建
        #[cfg(target_os = "macos")]
        let font_mgr = FontMgr::new();

        let instance = Sugarloaf {
            state,
            ctx,
            background_color: None,  // 透明背景，不硬编码黑色
            graphics: Graphics::default(),
            #[cfg(target_os = "macos")]
            font_library: font_library.inner.clone(),
            #[cfg(target_os = "macos")]
            typeface_cache: std::cell::RefCell::new(std::collections::HashMap::new()),
            #[cfg(target_os = "macos")]
            char_font_cache: std::cell::RefCell::new(std::collections::HashMap::new()),
            #[cfg(target_os = "macos")]
            font_size,
            #[cfg(target_os = "macos")]
            font_mgr,
            #[cfg(target_os = "macos")]
            layout_cache: std::cell::RefCell::new(LineLayoutCache::new()),
        };

        Ok(instance)
    }

    #[inline]
    pub fn update_font(&mut self, font_library: &FontLibrary) {
        tracing::info!("requested a font change");

        // Clear the global font data cache to ensure fonts are reloaded
        crate::font::clear_font_data_cache();

        self.state.reset();
        self.state.set_fonts_skia(font_library);

        // Update font library reference and clear cache
        #[cfg(target_os = "macos")]
        {
            self.font_library = font_library.inner.clone();
            self.typeface_cache.borrow_mut().clear();
            self.char_font_cache.borrow_mut().clear();
            self.layout_cache.borrow_mut().clear();
        }
    }

    #[inline]
    pub fn get_context(&self) -> &Context<'_> {
        &self.ctx
    }

    #[inline]
    pub fn get_scale(&self) -> f32 {
        self.ctx.scale
    }

    #[inline]
    pub fn style(&self) -> RootStyle {
        self.state.style
    }

    #[inline]
    pub fn style_mut(&mut self) -> &mut RootStyle {
        &mut self.state.style
    }

    #[inline]
    pub fn set_rich_text_font_size_based_on_action(
        &mut self,
        rt_id: &usize,
        operation: u8,
    ) {
        self.state.set_rich_text_font_size_based_on_action_skia(rt_id, operation);
        #[cfg(target_os = "macos")]
        {
            // 更新 self.font_size 以便 macOS Skia 渲染使用
            if let Some(state) = self.state.content.get_state(rt_id) {
                self.font_size = state.layout.font_size;
            }
        }
    }

    #[inline]
    pub fn set_rich_text_font_size(&mut self, rt_id: &usize, font_size: f32) {
        self.state.set_rich_text_font_size_skia(rt_id, font_size);
        #[cfg(target_os = "macos")]
        {
            self.font_size = font_size;
        }
    }

    #[inline]
    pub fn set_rich_text_line_height(&mut self, rt_id: &usize, line_height: f32) {
        self.state.set_rich_text_line_height(rt_id, line_height);
    }

    #[inline]
    pub fn set_background_color(&mut self, color: Option<Color4f>) -> &mut Self {
        self.background_color = color;
        self
    }

    #[inline]
    pub fn set_background_image(&mut self, _image: &ImageProperties) -> &mut Self {
        // TODO: Implement background image rendering with Skia
        // For now, just ignore background images
        self
    }

    #[inline]
    pub fn create_rich_text(&mut self) -> usize {
        self.state.create_rich_text()
    }

    #[inline]
    pub fn remove_rich_text(&mut self, rich_text_id: usize) {
        self.state.content.remove_state(&rich_text_id);
    }

    #[inline]
    pub fn create_temp_rich_text(&mut self) -> usize {
        self.state.create_temp_rich_text()
    }

    #[inline]
    pub fn clear_rich_text(&mut self, id: &usize) {
        self.state.clear_rich_text(id);
    }

    pub fn content(&mut self) -> &mut Content {
        self.state.content()
    }

    /// Check if layout cache contains a specific content hash (macOS only)
    ///
    /// Returns true if the cache has a layout for this hash, false otherwise.
    /// This is used to optimize rendering by skipping extraction of cached lines.
    #[inline]
    #[cfg(target_os = "macos")]
    pub fn has_cached_layout(&self, content_hash: u64) -> bool {
        self.layout_cache.borrow().get(content_hash).is_some()
    }

    #[inline]
    #[cfg(not(target_os = "macos"))]
    pub fn has_cached_layout(&self, _content_hash: u64) -> bool {
        false
    }

    #[inline]
    pub fn set_objects(&mut self, objects: Vec<Object>) {
        self.state.compute_objects(objects);
    }

    #[inline]
    pub fn rich_text_layout(&self, id: &usize) -> RichTextLayout {
        self.state.get_state_layout(id)
    }

    #[inline]
    pub fn get_rich_text_dimensions(&mut self, id: &usize) -> SugarDimensions {
        self.state.get_rich_text_dimensions_skia(id)
    }

    /// 获取 Skia 字体度量（cell_width, cell_height, line_height）
    /// 返回物理像素值
    #[cfg(target_os = "macos")]
    pub fn get_font_metrics_skia(&self) -> (f32, f32, f32) {
        use skia_safe::Font;

        let scale = self.ctx.scale;
        let font_size = self.font_size * scale;
        let line_height_factor = self.state.style.line_height;

        let font_library = self.font_library.read();
        let primary_typeface = self.get_or_create_typeface(&font_library, 0);

        if let Some(ref typeface) = primary_typeface {
            let primary_font = Font::from_typeface(typeface, font_size);
            let (_, metrics) = primary_font.metrics();
            let cell_height = (-metrics.ascent + metrics.descent + metrics.leading) * line_height_factor;
            let (cell_width_raw, _) = primary_font.measure_str("M", None);

            // 🎯 关键修复：Round 到整数像素，避免渲染时的亚像素缝隙
            // 同时确保渲染和坐标转换使用完全相同的值
            let cell_width = cell_width_raw.round();
            let cell_height = cell_height.round();

            (cell_width, cell_height, cell_height)
        } else {
            // Fallback 值
            let cell_width = (font_size * 0.6).round();
            let cell_height = (font_size * 1.2).round();
            (cell_width, cell_height, cell_height)
        }
    }

    // #[cfg(not(target_os = "macos"))]
    // pub fn get_font_metrics_skia(&self) -> (f32, f32, f32) {
    //     let font_size = self.font_size * self.ctx.scale;
    //     let cell_width = font_size * 0.6;
    //     let cell_height = font_size * 1.2;
    //     (cell_width, cell_height, cell_height)
    // }

    #[inline]
    pub fn clear(&mut self) {
        self.state.clean_screen();
    }

    #[inline]
    pub fn window_size(&self) -> SugarloafWindowSize {
        self.ctx.size
    }

    #[inline]
    pub fn scale_factor(&self) -> f32 {
        self.state.style.scale_factor
    }

    #[inline]
    pub fn resize(&mut self, width: u32, height: u32) {
        self.ctx.resize(width, height);
        // TODO: Handle background image resize when implemented
    }

    #[inline]
    pub fn rescale(&mut self, scale: f32) {
        self.ctx.scale = scale;
        self.state.compute_layout_rescale_skia(scale);

        // Clear layout cache when rescaling
        #[cfg(target_os = "macos")]
        {
            self.layout_cache.borrow_mut().clear();
        }

        // TODO: Handle background image rescale when implemented
    }

    #[inline]
    pub fn add_layers(&mut self, _quantity: usize) {}

    #[inline]
    pub fn reset(&mut self) {
        self.state.reset();
    }

    /// 创建 Font 对象（移除了 cache，因为 typeface 地址不稳定导致 cache 无效）
    #[cfg(target_os = "macos")]
    fn get_or_create_font(&self, typeface: &Typeface, font_size: f32) -> Font {
        // 直接创建 Font，不使用 cache
        // 原因：typeface 来自 layout cache 的 Vec<Typeface>，每次 clone 地址都变
        // 使用指针地址作为 cache key 会导致几乎 100% miss
        Font::from_typeface(typeface, font_size)
    }

    #[inline]
    #[cfg(target_os = "macos")]
    pub fn render(&mut self) {
        // Compute dimensions for rich text
        self.state.compute_dimensions_skia();

        // Get frame surface
        let frame = self.ctx.begin_frame();
        if frame.is_none() {
            return;
        }

        let (mut surface, drawable) = frame.unwrap();
        let canvas = surface.canvas();

        // 清理上一帧（必须！否则内容会叠加）
        // 使用背景色，如果没设置则用黑色
        let clear_color = self.background_color.unwrap_or(Color4f::new(0.0, 0.0, 0.0, 1.0));
        canvas.clear(clear_color);

        let scale = self.ctx.scale;

        // Render quads (backgrounds, borders, etc.)
        for quad in &self.state.quads {
            self.render_quad(canvas, quad, scale);
        }

        // Render images (pre-rasterized SkImages)
        let image_count = self.state.images.len();
        for image_obj in &self.state.images {
            self.render_image(canvas, image_obj, scale);
        }

        // 如果有 images，跳过 rich_text 渲染（新架构）
        if image_count > 0 {
            // 直接提交帧，不渲染 rich_texts
            self.ctx.end_frame(drawable);
            return;
        }

        let font_size = self.font_size * scale;

        // 预先创建 Paint 对象，在渲染循环中复用，避免重复创建
        let mut paint = Paint::default();
        paint.set_anti_alias(true);

        let mut bg_paint = Paint::default();

        let mut cursor_paint = Paint::default();
        cursor_paint.set_anti_alias(true);

        let mut deco_paint = Paint::default();
        deco_paint.set_anti_alias(true);

        // Get line height from style
        let line_height = self.state.style.line_height;

        // 获取主字体 (font_id=0) 的度量信息用于行高计算
        let font_library = self.font_library.read();
        let primary_typeface = self.get_or_create_typeface(&font_library, 0);

        if let Some(ref typeface) = primary_typeface {
            let primary_font = Font::from_typeface(typeface, font_size);
            let (_, metrics) = primary_font.metrics();
            let raw_cell_height = (-metrics.ascent + metrics.descent + metrics.leading) * line_height;
            // 🔧 在物理像素层面对齐到整数,避免行间缝隙
            let cell_height = (raw_cell_height * scale).round() / scale;
            let baseline_offset = -metrics.ascent;

            // 计算单个 cell 的宽度（基于主字体的等宽特性）
            // 使用 "M" 作为基准字符来测量 cell 宽度
            let (raw_cell_width, _) = primary_font.measure_str("M", None);
            // 🔧 在物理像素层面对齐到整数,避免子像素渲染导致的字符缝隙
            // scale=1.0: 8.4 → 8.0
            // scale=2.0: 8.4 → 8.5 (物理像素 17.0)
            let cell_width = (raw_cell_width * scale).round() / scale;

            for rich_text in &self.state.rich_texts {
                if let Some(builder_state) = self.state.content.get_state(&rich_text.id) {
                    let base_x = rich_text.position[0] * scale;
                    let base_y = rich_text.position[1] * scale;

                    for (line_idx, line) in builder_state.lines.iter().enumerate() {
                        let y = base_y + (line_idx as f32) * cell_height + baseline_offset;

                        // 🔥 使用 content_hash 查找缓存
                        let content_hash = line.content_hash;

                        let layout = {
                            let cache = self.layout_cache.borrow();
                            if let Some(cached_layout) = cache.get(content_hash) {
                                cached_layout.clone()
                            } else {
                                // 缓存未命中，需要重新计算
                                drop(cache);  // 释放借用，避免冲突

                                let new_layout = self.generate_line_layout(
                                    line,
                                    &font_library,
                                    font_size,
                                    cell_width,
                                    &primary_font,
                                );

                                // 存入缓存
                                self.layout_cache.borrow_mut().set(content_hash, new_layout.clone());
                                new_layout
                            }
                        };

                        // 使用缓存的布局数据渲染
                        let mut char_idx = 0;
                        for fragment in &line.fragments {
                            // 设置颜色
                            let color = skia_safe::Color::from_argb(
                                (fragment.style.color[3] * 255.0) as u8,
                                (fragment.style.color[0] * 255.0) as u8,
                                (fragment.style.color[1] * 255.0) as u8,
                                (fragment.style.color[2] * 255.0) as u8,
                            );
                            paint.set_color(color);

                            // 获取 fragment 的 cell 宽度（1.0 = 单宽，2.0 = 双宽）
                            let fragment_cell_width = fragment.style.width;

                            // 🎯 使用缓存的布局数据渲染，跳过耗时的字体查找
                            let fragment_chars: Vec<char> = fragment.content.chars()
                                .filter(|&c| c != '\u{FE0F}' && c != '\u{FE0E}' && c != '\u{20E3}')
                                .collect();

                            for _ in 0..fragment_chars.len() {
                                if char_idx >= layout.chars.len() {
                                    break;
                                }

                                let ch = layout.chars[char_idx];
                                let typeface = &layout.typefaces[char_idx];
                                let x = base_x + layout.positions[char_idx];

                                // 从缓存获取 Font 对象，避免重复创建
                                let font = self.get_or_create_font(typeface, font_size);

                                // 使用终端 cell 宽度而不是字体 advance
                                let char_cell_advance = cell_width * fragment_cell_width;
                                let ch_str = ch.to_string();
                                let center_offset = 0.0;

                                // 绘制背景（如果有）
                                if let Some(bg) = fragment.style.background_color {
                                    if bg[3] > 0.01 {
                                        bg_paint.set_color(skia_safe::Color::from_argb(
                                            (bg[3] * 255.0) as u8,
                                            (bg[0] * 255.0) as u8,
                                            (bg[1] * 255.0) as u8,
                                            (bg[2] * 255.0) as u8,
                                        ));
                                        canvas.draw_rect(
                                            skia_safe::Rect::from_xywh(x, y - baseline_offset, char_cell_advance, cell_height),
                                            &bg_paint,
                                        );
                                    }
                                }

                                // 绘制光标（如果有）
                                if let Some(cursor) = fragment.style.cursor {
                                    let cell_top = y - baseline_offset;

                                    match cursor {
                                        crate::SugarCursor::Block(color) => {
                                            cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                                            cursor_paint.set_color(skia_safe::Color::from_argb(
                                                (color[3] * 255.0) as u8,
                                                (color[0] * 255.0) as u8,
                                                (color[1] * 255.0) as u8,
                                                (color[2] * 255.0) as u8,
                                            ));
                                            canvas.draw_rect(
                                                skia_safe::Rect::from_xywh(x, cell_top, char_cell_advance, cell_height),
                                                &cursor_paint,
                                            );
                                        }
                                        crate::SugarCursor::HollowBlock(color) => {
                                            cursor_paint.set_style(skia_safe::PaintStyle::Stroke);
                                            cursor_paint.set_stroke_width(1.0);
                                            cursor_paint.set_color(skia_safe::Color::from_argb(
                                                (color[3] * 255.0) as u8,
                                                (color[0] * 255.0) as u8,
                                                (color[1] * 255.0) as u8,
                                                (color[2] * 255.0) as u8,
                                            ));
                                            canvas.draw_rect(
                                                skia_safe::Rect::from_xywh(x + 0.5, cell_top + 0.5, char_cell_advance - 1.0, cell_height - 1.0),
                                                &cursor_paint,
                                            );
                                        }
                                        crate::SugarCursor::Caret(color) => {
                                            cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                                            cursor_paint.set_color(skia_safe::Color::from_argb(
                                                (color[3] * 255.0) as u8,
                                                (color[0] * 255.0) as u8,
                                                (color[1] * 255.0) as u8,
                                                (color[2] * 255.0) as u8,
                                            ));
                                            canvas.draw_rect(
                                                skia_safe::Rect::from_xywh(x, cell_top, 2.0, cell_height),
                                                &cursor_paint,
                                            );
                                        }
                                        crate::SugarCursor::Underline(color) => {
                                            cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                                            cursor_paint.set_color(skia_safe::Color::from_argb(
                                                (color[3] * 255.0) as u8,
                                                (color[0] * 255.0) as u8,
                                                (color[1] * 255.0) as u8,
                                                (color[2] * 255.0) as u8,
                                            ));
                                            let underline_height = 2.0;
                                            canvas.draw_rect(
                                                skia_safe::Rect::from_xywh(x, cell_top + cell_height - underline_height, char_cell_advance, underline_height),
                                                &cursor_paint,
                                            );
                                        }
                                    }
                                }

                                // 绘制字符（居中）
                                canvas.draw_str(&ch_str, Point::new(x + center_offset, y), &font, &paint);

                                // 绘制装饰（下划线、删除线）
                                if let Some(decoration) = fragment.style.decoration {
                                    // 使用 decoration_color 或默认使用前景色
                                    let deco_color = fragment.style.decoration_color.unwrap_or(fragment.style.color);
                                    deco_paint.set_color(skia_safe::Color::from_argb(
                                        (deco_color[3] * 255.0) as u8,
                                        (deco_color[0] * 255.0) as u8,
                                        (deco_color[1] * 255.0) as u8,
                                        (deco_color[2] * 255.0) as u8,
                                    ));
                                    // 重置样式为 Fill，因为某些装饰可能会修改为 Stroke
                                    deco_paint.set_style(skia_safe::PaintStyle::Fill);
                                    deco_paint.set_path_effect(None);

                                    let cell_top = y - baseline_offset;

                                    match decoration {
                                        crate::layout::FragmentStyleDecoration::Underline(info) => {
                                            let underline_thickness = 1.5;
                                            let underline_y = cell_top + cell_height - underline_thickness - 1.0;

                                            match info.shape {
                                                crate::layout::UnderlineShape::Regular => {
                                                    // 普通下划线
                                                    canvas.draw_rect(
                                                        skia_safe::Rect::from_xywh(x, underline_y, char_cell_advance, underline_thickness),
                                                        &deco_paint,
                                                    );
                                                    // 双下划线
                                                    if info.is_doubled {
                                                        canvas.draw_rect(
                                                            skia_safe::Rect::from_xywh(x, underline_y - 3.0, char_cell_advance, underline_thickness),
                                                            &deco_paint,
                                                        );
                                                    }
                                                }
                                                crate::layout::UnderlineShape::Dotted => {
                                                    // 点状下划线
                                                    deco_paint.set_style(skia_safe::PaintStyle::Stroke);
                                                    deco_paint.set_stroke_width(underline_thickness);
                                                    let effect = skia_safe::PathEffect::dash(&[2.0, 2.0], 0.0);
                                                    deco_paint.set_path_effect(effect);
                                                    canvas.draw_line(
                                                        Point::new(x, underline_y + underline_thickness / 2.0),
                                                        Point::new(x + char_cell_advance, underline_y + underline_thickness / 2.0),
                                                        &deco_paint,
                                                    );
                                                }
                                                crate::layout::UnderlineShape::Dashed => {
                                                    // 虚线下划线
                                                    deco_paint.set_style(skia_safe::PaintStyle::Stroke);
                                                    deco_paint.set_stroke_width(underline_thickness);
                                                    let effect = skia_safe::PathEffect::dash(&[4.0, 2.0], 0.0);
                                                    deco_paint.set_path_effect(effect);
                                                    canvas.draw_line(
                                                        Point::new(x, underline_y + underline_thickness / 2.0),
                                                        Point::new(x + char_cell_advance, underline_y + underline_thickness / 2.0),
                                                        &deco_paint,
                                                    );
                                                }
                                                crate::layout::UnderlineShape::Curly => {
                                                    // 波浪线下划线
                                                    deco_paint.set_style(skia_safe::PaintStyle::Stroke);
                                                    deco_paint.set_stroke_width(underline_thickness);

                                                    let mut path = skia_safe::Path::new();
                                                    let wave_height = 2.0;
                                                    let wave_period = 4.0;
                                                    let start_x = x;
                                                    let wave_y = underline_y + underline_thickness / 2.0;

                                                    path.move_to(Point::new(start_x, wave_y));
                                                    let mut cx = start_x;
                                                    let mut up = true;
                                                    while cx < x + char_cell_advance {
                                                        let next_x = (cx + wave_period).min(x + char_cell_advance);
                                                        let dy = if up { -wave_height } else { wave_height };
                                                        path.quad_to(
                                                            Point::new(cx + wave_period / 2.0, wave_y + dy),
                                                            Point::new(next_x, wave_y),
                                                        );
                                                        cx = next_x;
                                                        up = !up;
                                                    }
                                                    canvas.draw_path(&path, &deco_paint);
                                                }
                                            }
                                        }
                                        crate::layout::FragmentStyleDecoration::Strikethrough => {
                                            // 删除线 - 在文字中间
                                            let strikethrough_y = cell_top + cell_height / 2.0;
                                            let strikethrough_thickness = 1.5;
                                            canvas.draw_rect(
                                                skia_safe::Rect::from_xywh(x, strikethrough_y - strikethrough_thickness / 2.0, char_cell_advance, strikethrough_thickness),
                                                &deco_paint,
                                            );
                                        }
                                    }
                                }

                                // 更新字符索引（使用缓存的布局，无需更新 x）
                                char_idx += 1;
                            }
                        }
                    }
                }
            }
        }
        drop(font_library);

        // Render visual bell overlay if present
        if let Some(bell_overlay) = self.state.visual_bell_overlay {
            self.render_quad(canvas, &bell_overlay, scale);
        }

        // End frame and present
        self.ctx.end_frame(drawable);
        self.reset();
    }

    // ========================================================================
    // 🚀 未来优化方向：合并 Image 渲染
    // ========================================================================
    //
    // 当前架构瓶颈分析（2024-12 探索记录）：
    //
    // 现状：
    //   terminal_pool.render_terminal() 为每行生成一个 Image object
    //   → 114 行 = 114 个 objects
    //   → sugarloaf.render() 处理 114 个 objects，耗时约 440μs
    //
    // 问题：
    //   即使 sugarloaf-ffi 的 Renderer 有三级缓存（FullHit 时零开销），
    //   objects 数量不变，GPU 仍需处理 114 次绘制命令。
    //
    // 优化思路：
    //   1. 将 114 个小 Image 合并为 1 个完整终端 Image
    //   2. 使用 off-screen surface 作为持久缓冲区
    //   3. 只重绘 damaged 行到 off-screen surface
    //   4. 每帧只提交 1 个 object
    //
    // 预期收益：
    //   - 光标闪烁：从 440μs 降到 < 10μs（只更新 2 行）
    //   - 打字输入：从 440μs 降到 < 10μs（只更新 1 行）
    //
    // 实现复杂度：
    //   - 需要管理 off-screen surface 生命周期
    //   - 需要处理 resize 时的 surface 重建
    //   - 光标渲染需要特殊处理（不能缓存到 off-screen，每帧重绘）
    //   - 选区/搜索高亮需要考虑擦除和重绘
    //
    // 暂不实现原因：
    //   当前 440μs 的帧时间对于 60Hz 刷新率（16.6ms）完全足够，
    //   优化优先级不高。当需要支持高刷新率或更大终端时再考虑。
    // ========================================================================

    /// 生成单行的布局计算结果（字符、字体、位置）
    /// 这是脏区渲染优化的核心：缓存耗时的字体查找和布局计算
    #[cfg(target_os = "macos")]
    fn generate_line_layout(
        &self,
        line: &crate::layout::BuilderLine,
        font_library: &crate::font::FontLibraryData,
        font_size: f32,
        cell_width: f32,
        primary_font: &Font,
    ) -> CachedLineLayout {
        let mut chars = Vec::new();
        let mut typefaces = Vec::new();
        let mut positions = Vec::new();

        let mut x = 0.0;

        for fragment in &line.fragments {
            let styled_typeface = self.get_or_create_typeface(font_library, fragment.style.font_id);
            let styled_font = styled_typeface
                .as_ref()
                .map(|tf| Font::from_typeface(tf, font_size))
                .unwrap_or_else(|| primary_font.clone());

            let fragment_cell_width = fragment.style.width;
            let chars_vec: Vec<char> = fragment.content.chars().collect();
            let mut i = 0;

            while i < chars_vec.len() {
                let ch = chars_vec[i];

                let next_is_vs16 = chars_vec.get(i + 1) == Some(&'\u{FE0F}');
                let next_is_vs15 = chars_vec.get(i + 1) == Some(&'\u{FE0E}');
                let is_keycap_sequence = next_is_vs16 && chars_vec.get(i + 2) == Some(&'\u{20E3}');

                if ch == '\u{FE0F}' || ch == '\u{FE0E}' || ch == '\u{20E3}' {
                    i += 1;
                    continue;
                }

                let (best_font, _is_emoji) = if is_keycap_sequence || next_is_vs16 {
                    if let Some(emoji_typeface) = self.font_mgr.match_family_style_character(
                        "Apple Color Emoji",
                        FontStyle::normal(),
                        &[],
                        ch as i32,
                    ) {
                        (Font::from_typeface(&emoji_typeface, font_size), true)
                    } else {
                        self.find_font_for_char_styled(font_library, ch, font_size, &styled_font)
                    }
                } else if (ch as u32) >= 0x80 {
                    self.find_font_for_char_styled(font_library, ch, font_size, &styled_font)
                } else {
                    (styled_font.clone(), false)
                };

                chars.push(ch);
                typefaces.push(best_font.typeface());
                positions.push(x);

                x += cell_width * fragment_cell_width;

                if is_keycap_sequence {
                    i += 3;
                } else if next_is_vs16 || next_is_vs15 {
                    i += 2;
                } else {
                    i += 1;
                }
            }
        }

        CachedLineLayout {
            chars,
            typefaces,
            positions,
            font_size,
            cell_width,
        }
    }

    /// 为单个字符找到最佳渲染字体
    /// 使用 Skia 的系统字体匹配机制自动查找支持该字符的字体
    #[allow(dead_code)] // Reserved for future use
    #[cfg(target_os = "macos")]
    fn find_font_for_char(
        &self,
        _font_library: &crate::font::FontLibraryData,
        ch: char,
        font_size: f32,
        fallback_font: &Font,
    ) -> (Font, bool) {
        self.find_font_for_char_styled(_font_library, ch, font_size, fallback_font)
    }

    /// 为单个字符找到最佳渲染字体（带样式支持）
    /// 优先使用主字体，只有主字体不支持时才使用系统 fallback
    #[cfg(target_os = "macos")]
    fn find_font_for_char_styled(
        &self,
        _font_library: &crate::font::FontLibraryData,
        ch: char,
        font_size: f32,
        styled_font: &Font,
    ) -> (Font, bool) {
        // ASCII 字符直接使用样式字体
        if (ch as u32) < 0x80 {
            return (styled_font.clone(), false);
        }

        // 🔧 优先检查主字体(styled_font)是否支持该字符
        // unichar_to_glyph 返回 0 表示字体不支持该字符
        let glyph_id = styled_font.unichar_to_glyph(ch as i32);
        if glyph_id != 0 {
            return (styled_font.clone(), false);
        }

        // 主字体不支持，检查缓存
        {
            let cache = self.char_font_cache.borrow();
            if let Some((typeface, is_emoji)) = cache.get(&ch) {
                return (Font::from_typeface(typeface, font_size), *is_emoji);
            }
        }

        // 主字体不支持且无缓存，使用系统字体匹配（复用成员变量 font_mgr）
        if let Some(typeface) = self.font_mgr.match_family_style_character(
            "",
            FontStyle::normal(),
            &[],
            ch as i32,
        ) {
            // 通过字体 family name 判断是否为 emoji 字体
            let family_name = typeface.family_name();
            let is_emoji = family_name.to_lowercase().contains("emoji");

            // 缓存结果
            self.char_font_cache.borrow_mut().insert(ch, (typeface.clone(), is_emoji));

            return (Font::from_typeface(&typeface, font_size), is_emoji);
        }

        // 如果系统也找不到合适的字体，使用样式字体作为 fallback
        (styled_font.clone(), false)
    }

    /// 从 FontLibrary 获取或创建 Skia Typeface（带缓存）
    /// 复刻原版逻辑：从 FontLibrary 的字体数据创建 Skia Typeface
    #[cfg(target_os = "macos")]
    fn get_or_create_typeface(
        &self,
        font_library: &crate::font::FontLibraryData,
        font_id: usize,
    ) -> Option<Typeface> {
        // 先检查缓存
        {
            let cache = self.typeface_cache.borrow();
            if let Some(typeface) = cache.get(&font_id) {
                return Some(typeface.clone());
            }
        }

        // 获取字体信息
        let font_data_info = font_library.inner.get(&font_id);
        let is_emoji = font_data_info.map(|f| f.is_emoji).unwrap_or(false);

        // 使用成员变量 font_mgr
        let typeface = if is_emoji {
            // 对于 emoji 字体，使用系统字体管理器查找
            // 原因：Apple Color Emoji 使用 SBIX 位图格式，需要系统级支持
            // 从 FontData.path 获取字体名称（加载时存储的是字体 family name）
            let family_name = font_data_info
                .and_then(|f| f.path.as_ref())
                .and_then(|p| p.to_str())
                .unwrap_or("Apple Color Emoji");
            self.font_mgr.match_family_style(family_name, FontStyle::normal())
        } else if let Some((font_data, offset, _key)) = font_library.get_data(&font_id) {
            // 普通字体从数据加载
            let offset_usize = offset as usize;
            let font_bytes = &font_data[offset_usize..];
            let data = skia_safe::Data::new_copy(font_bytes);
            self.font_mgr.new_from_data(&data, None)
        } else {
            // 如果没有找到数据，尝试从系统字体加载
            let family_name = font_data_info
                .and_then(|f| f.path.as_ref())
                .and_then(|p| p.to_str())
                .unwrap_or("Menlo");
            self.font_mgr.match_family_style(family_name, FontStyle::normal())
        };

        // 存入缓存
        if let Some(ref tf) = typeface {
            self.typeface_cache.borrow_mut().insert(font_id, tf.clone());
        }

        typeface
    }

    #[cfg(target_os = "macos")]
    fn render_quad(&self, canvas: &skia_safe::Canvas, quad: &Quad, scale: f32) {
        let mut paint = Paint::default();
        paint.set_anti_alias(true);

        let rect = skia_safe::Rect::from_xywh(
            quad.position[0] * scale,
            quad.position[1] * scale,
            quad.size[0] * scale,
            quad.size[1] * scale,
        );

        // Draw background
        if quad.color[3] > 0.01 {
            let color = skia_safe::Color::from_argb(
                (quad.color[3] * 255.0) as u8,
                (quad.color[0] * 255.0) as u8,
                (quad.color[1] * 255.0) as u8,
                (quad.color[2] * 255.0) as u8,
            );
            paint.set_color(color);

            // Handle border radius
            if quad.border_radius[0] > 0.0 {
                let radii = [
                    quad.border_radius[0] * scale,
                    quad.border_radius[1] * scale,
                    quad.border_radius[2] * scale,
                    quad.border_radius[3] * scale,
                ];
                let rrect = skia_safe::RRect::new_rect_radii(
                    rect,
                    &[
                        skia_safe::Point::new(radii[0], radii[0]),
                        skia_safe::Point::new(radii[1], radii[1]),
                        skia_safe::Point::new(radii[2], radii[2]),
                        skia_safe::Point::new(radii[3], radii[3]),
                    ],
                );
                canvas.draw_rrect(rrect, &paint);
            } else {
                canvas.draw_rect(rect, &paint);
            }
        }

        // Draw border if needed
        if quad.border_width > 0.0 && quad.border_color[3] > 0.01 {
            let border_color = skia_safe::Color::from_argb(
                (quad.border_color[3] * 255.0) as u8,
                (quad.border_color[0] * 255.0) as u8,
                (quad.border_color[1] * 255.0) as u8,
                (quad.border_color[2] * 255.0) as u8,
            );
            paint.set_color(border_color);
            paint.set_style(skia_safe::PaintStyle::Stroke);
            paint.set_stroke_width(quad.border_width * scale);

            if quad.border_radius[0] > 0.0 {
                let radii = [
                    quad.border_radius[0] * scale,
                    quad.border_radius[1] * scale,
                    quad.border_radius[2] * scale,
                    quad.border_radius[3] * scale,
                ];
                let rrect = skia_safe::RRect::new_rect_radii(
                    rect,
                    &[
                        skia_safe::Point::new(radii[0], radii[0]),
                        skia_safe::Point::new(radii[1], radii[1]),
                        skia_safe::Point::new(radii[2], radii[2]),
                        skia_safe::Point::new(radii[3], radii[3]),
                    ],
                );
                canvas.draw_rrect(rrect, &paint);
            } else {
                canvas.draw_rect(rect, &paint);
            }
        }
    }

    /// Render a pre-rasterized image at the specified position
    fn render_image(&self, canvas: &skia_safe::Canvas, image_obj: &crate::sugarloaf::primitives::ImageObject, scale: f32) {
        // 像素对齐：避免亚像素渲染导致的模糊/锯齿
        // 当 Panel 分割后，坐标可能是非整数，直接绘制会导致 Skia 亚像素插值
        let x = (image_obj.position[0] * scale).round();
        let y = (image_obj.position[1] * scale).round();

        canvas.draw_image(&image_obj.image, (x, y), None);
    }

    #[inline]
    pub fn set_visual_bell_overlay(&mut self, overlay: Option<Quad>) {
        self.state.set_visual_bell_overlay(overlay);
    }
}
