#[cfg(feature = "new_architecture")]
use crate::render::cache::GlyphLayout;
use crate::render::box_drawing::{detect_drawable_character, BoxDrawingConfig};
use rio_backend::ansi::CursorShape;
use skia_safe::{Image, Paint, ImageInfo, ColorType, AlphaType, Point, Color4f};

/// 行光栅化器（渲染 GlyphLayout → SkImage）
/// 复用老代码的 render_line_to_image 逻辑（sugarloaf.rs:535-627 行）
pub struct LineRasterizer {
    // 暂时无需状态，可以是纯函数
}

impl LineRasterizer {
    pub fn new() -> Self {
        Self {}
    }

    /// 渲染一行到 SkImage
    ///
    /// 参数：
    /// - layout: 字形布局（字符 + 字体 + 位置）
    /// - line_width: 行宽度（像素）
    /// - cell_width: 单元格宽度（像素）
    /// - cell_height: 单元格高度（像素）
    /// - line_height: 完整行高（物理像素，= cell_height * line_height_factor）
    /// - baseline_offset: 基线偏移（y 坐标）
    /// - background_color: 背景色
    /// - box_drawing_config: Box-drawing 字符渲染配置
    ///
    /// 复用老代码逻辑：
    /// 1. 创建 Skia surface（行尺寸）
    /// 2. 填充背景色
    /// 3. 遍历所有字形，绘制字符
    /// 4. 返回 Image
    pub fn render(
        &self,
        layout: &GlyphLayout,
        line_width: f32,
        cell_width: f32,
        cell_height: f32,
        line_height: f32,  // 🎯 恢复 line_height 参数
        baseline_offset: f32,
        background_color: Color4f,
        box_drawing_config: &BoxDrawingConfig,
    ) -> Option<Image> {
        // ===== 步骤 1: 创建 surface =====
        // 🎯 Image 高度使用 line_height（= cell_height * line_height_factor）
        // 这样 box-drawing 字符可以拉伸填满整个行高
        let image_info = ImageInfo::new(
            (line_width.round() as i32, line_height.round() as i32),
            ColorType::BGRA8888,
            AlphaType::Premul,
            None,
        );

        let mut surface = skia_safe::surfaces::raster(&image_info, None, None)?;
        let canvas = surface.canvas();

        // ===== 步骤 2: 填充背景色（558 行）=====
        canvas.clear(background_color);

        // ===== 步骤 3: 创建 Paint（561-562 行）=====
        let mut paint = Paint::default();
        paint.set_anti_alias(true);

        // ===== 步骤 4: 遍历字形，绘制字符（567-622 行）=====
        for glyph in &layout.glyphs {
            // 先绘制背景色（如果有）
            if let Some(bg_color) = &glyph.background_color {
                let mut bg_paint = Paint::default();
                bg_paint.set_color4f(*bg_color, None);
                // 使用 glyph.width（1.0 或 2.0）计算背景矩形宽度
                let bg_width = cell_width * glyph.width;
                // 背景填满整个 line_height
                let rect = skia_safe::Rect::from_xywh(glyph.x, 0.0, bg_width, line_height);
                canvas.draw_rect(rect, &bg_paint);
            }

            // 设置字符颜色
            paint.set_color4f(glyph.color, None);

            // 🎯 对 box-drawing 字符进行形变拉伸，填满整个 line_height
            if detect_drawable_character(glyph.ch).is_some() && box_drawing_config.enabled {
                // 计算缩放比例：让字形填满整个 line_height
                let scale_y = line_height / cell_height;

                // 保存画布状态
                canvas.save();

                // 平移到字符位置，应用 Y 轴缩放
                canvas.translate((glyph.x, 0.0));
                canvas.scale((1.0, scale_y));

                // 绘制（缩放后 baseline 也需要调整）
                let ch_str = glyph.ch.to_string();
                canvas.draw_str(&ch_str, Point::new(0.0, baseline_offset / scale_y), &glyph.font, &paint);

                // 恢复画布状态
                canvas.restore();
            } else {
                // 普通字符：正常绘制
                let ch_str = glyph.ch.to_string();
                canvas.draw_str(&ch_str, Point::new(glyph.x, baseline_offset), &glyph.font, &paint);
            }
        }

        // ===== 步骤 4.5: 绘制光标（如果有）=====
        if let Some(cursor) = &layout.cursor_info {
            let cursor_x = cursor.col as f32 * cell_width;
            let cursor_color = Color4f::new(
                cursor.color[0],
                cursor.color[1],
                cursor.color[2],
                cursor.color[3],
            );

            let mut cursor_paint = Paint::default();
            cursor_paint.set_anti_alias(true);
            cursor_paint.set_color4f(cursor_color, None);

            match cursor.shape {
                CursorShape::Block => {
                    // 实心方块，填满整个 line_height
                    cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                    let rect = skia_safe::Rect::from_xywh(cursor_x, 0.0, cell_width, line_height);
                    canvas.draw_rect(rect, &cursor_paint);
                }
                CursorShape::Underline => {
                    // 下划线（底部 2px）
                    cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                    let underline_height = 2.0;
                    let rect = skia_safe::Rect::from_xywh(
                        cursor_x,
                        line_height - underline_height,
                        cell_width,
                        underline_height
                    );
                    canvas.draw_rect(rect, &cursor_paint);
                }
                CursorShape::Beam => {
                    // 竖线，填满整个 line_height
                    cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                    let beam_width = 2.0;
                    let rect = skia_safe::Rect::from_xywh(cursor_x, 0.0, beam_width, line_height);
                    canvas.draw_rect(rect, &cursor_paint);
                }
                CursorShape::Hidden => {
                    // 隐藏，不绘制
                }
            }
        }

        // ===== 步骤 5: 获取 Image（626 行）=====
        surface.image_snapshot().into()
    }
}

impl Default for LineRasterizer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::layout::GlyphInfo;
    use skia_safe::Font;

    #[test]
    fn test_render_empty_line() {
        let rasterizer = LineRasterizer::new();
        let layout = GlyphLayout {
            glyphs: vec![],
            content_hash: 0,
            cursor_info: None,
        };

        let image = rasterizer.render(
            &layout,
            800.0,  // line_width
            10.0,   // cell_width
            16.0,   // cell_height
            19.2,   // line_height (16.0 * 1.2)
            12.0,   // baseline_offset
            Color4f::new(0.0, 0.0, 0.0, 1.0),  // black background
            &BoxDrawingConfig::default(),
        );

        assert!(image.is_some());
        let img = image.unwrap();
        assert_eq!(img.width(), 800);
        // Image 高度 = line_height（19.2 rounded = 19）
        assert_eq!(img.height(), 19);
    }

    #[test]
    fn test_render_single_char() {
        let rasterizer = LineRasterizer::new();
        let font = Font::default();

        let layout = GlyphLayout {
            glyphs: vec![GlyphInfo {
                ch: 'A',
                font,
                x: 0.0,
                color: Color4f::new(1.0, 1.0, 1.0, 1.0),  // 白色
                background_color: None,
                width: 1.0,  // 单宽字符
            }],
            content_hash: 0,
            cursor_info: None,
        };

        let image = rasterizer.render(
            &layout,
            800.0,
            10.0,
            16.0,
            19.2,   // line_height (16.0 * 1.2)
            12.0,
            Color4f::new(0.0, 0.0, 0.0, 1.0),
            &BoxDrawingConfig::default(),
        );

        assert!(image.is_some());
    }
}
