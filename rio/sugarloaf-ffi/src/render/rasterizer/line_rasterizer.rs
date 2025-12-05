#[cfg(feature = "new_architecture")]
use crate::render::cache::GlyphLayout;
use skia_safe::{Image, Paint, ImageInfo, ColorType, AlphaType, Point, Color4f, Color};

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
    /// - baseline_offset: 基线偏移（y 坐标）
    /// - background_color: 背景色
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
        baseline_offset: f32,
        background_color: Color4f,
    ) -> Option<Image> {
        // ===== 步骤 1: 创建 surface（547-554 行）=====
        // 🎯 关键修复：先 round 再转 i32，避免浮点精度导致截断
        // 例如 20.9999999 as i32 = 20 (错误)，应该 round() 后再转换
        let image_width = line_width.round() as i32;
        let image_height = cell_height.round() as i32;

        eprintln!("🔍 line_rasterizer | line_width={:.6} → {}, cell_height={:.6} → {}",
                  line_width, image_width, cell_height, image_height);

        let image_info = ImageInfo::new(
            (image_width, image_height),
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
                // 🔧 修复：使用 glyph.width（1.0 或 2.0）计算背景矩形宽度
                // 这样中文字符（width=2.0）的背景会是双倍宽度
                let bg_width = cell_width * glyph.width;
                let rect = skia_safe::Rect::from_xywh(glyph.x, 0.0, bg_width, cell_height);
                canvas.draw_rect(rect, &bg_paint);
            }

            // 设置字符颜色（从 glyph.color 获取）
            paint.set_color4f(glyph.color, None);

            // 计算绘制位置（594-596 行）
            let x = glyph.x;
            let y = baseline_offset;

            // 绘制字符（619 行）
            let ch_str = glyph.ch.to_string();
            canvas.draw_str(&ch_str, Point::new(x, y), &glyph.font, &paint);
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
        };

        let image = rasterizer.render(
            &layout,
            800.0,  // line_width
            10.0,   // cell_width
            16.0,   // cell_height
            12.0,   // baseline_offset
            Color4f::new(0.0, 0.0, 0.0, 1.0),  // black background
        );

        assert!(image.is_some());
        let img = image.unwrap();
        assert_eq!(img.width(), 800);
        assert_eq!(img.height(), 16);
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
        };

        let image = rasterizer.render(
            &layout,
            800.0,
            10.0,
            16.0,
            12.0,
            Color4f::new(0.0, 0.0, 0.0, 1.0),
        );

        assert!(image.is_some());
    }
}
