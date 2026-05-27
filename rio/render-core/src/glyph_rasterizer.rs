//! GlyphRasterizer - 单字形光栅化器

use crate::glyph_atlas::{GlyphBitmap, GlyphKey};
use crate::glyph_info::GlyphInfo;
use skia_safe::{Color, Color4f, Paint, Point, surfaces};

pub struct GlyphRasterizer {
    max_size: i32,
}

impl GlyphRasterizer {
    const DEFAULT_MAX_SIZE: i32 = 256;

    pub fn new() -> Self {
        Self {
            max_size: Self::DEFAULT_MAX_SIZE,
        }
    }

    pub fn rasterize(
        &self,
        glyph: &GlyphInfo,
        cell_width: f32,
        cell_height: f32,
        baseline_offset: f32,
    ) -> Option<GlyphBitmap> {
        let char_count = glyph.grapheme.chars().count();
        let is_emoji_sequence = char_count > 1;
        let is_native_emoji = char_count == 1 && Self::is_native_emoji(&glyph.grapheme);
        let is_emoji = is_emoji_sequence || is_native_emoji;

        let (width, height) = if is_emoji {
            let (emoji_width, emoji_height) = self.measure_emoji(glyph);
            let min_width = (cell_width * 2.0).ceil();
            let min_height = cell_height.ceil();
            let w = (emoji_width.ceil() as i32).max(min_width as i32).min(self.max_size);
            let h = (emoji_height.ceil() as i32).max(min_height as i32).min(self.max_size);
            (w, h)
        } else {
            let base_width = cell_width * glyph.width;
            let (_, bounds) = glyph.font.measure_str(&glyph.grapheme, None);
            let glyph_width = bounds.width() + 2.0;
            let total_width = base_width.max(glyph_width);
            let (_, metrics) = glyph.font.metrics();
            let font_height = -metrics.ascent + metrics.descent;
            let total_height = cell_height.max(font_height);
            let w = (total_width.ceil() as i32).min(self.max_size);
            let h = (total_height.ceil() as i32).min(self.max_size);
            (w, h)
        };

        if width <= 0 || height <= 0 {
            return None;
        }

        let mut surface = surfaces::raster_n32_premul((width, height))?;
        let canvas = surface.canvas();
        canvas.clear(Color::TRANSPARENT);

        let mut paint = Paint::default();
        paint.set_anti_alias(true);
        paint.set_color4f(Color4f::new(1.0, 1.0, 1.0, 1.0), None);

        if is_emoji {
            self.rasterize_emoji(canvas, glyph, width as f32, height as f32);
        } else if glyph.needs_vertical_center() {
            self.rasterize_centered(canvas, glyph, cell_width, cell_height, &paint);
        } else {
            self.rasterize_normal(canvas, glyph, baseline_offset, &paint);
        }

        let image = surface.image_snapshot();
        let info = image.image_info();
        let row_bytes = info.min_row_bytes();
        let data_size = row_bytes * height as usize;

        let mut data = vec![0u8; data_size];
        if !image.read_pixels(
            &info,
            &mut data,
            row_bytes,
            (0, 0),
            skia_safe::image::CachingHint::Allow,
        ) {
            return None;
        }

        Some(GlyphBitmap {
            width: width as u16,
            height: height as u16,
            data,
            row_bytes,
        })
    }

    fn rasterize_normal(
        &self,
        canvas: &skia_safe::Canvas,
        glyph: &GlyphInfo,
        baseline_offset: f32,
        paint: &Paint,
    ) {
        let (_, bounds) = glyph.font.measure_str(&glyph.grapheme, None);
        let x_offset = if bounds.left < 0.0 { -bounds.left + 1.0 } else { 1.0 };
        let y_offset = baseline_offset;

        canvas.draw_str(
            &glyph.grapheme,
            Point::new(x_offset, y_offset),
            &glyph.font,
            paint,
        );
    }

    fn rasterize_centered(
        &self,
        canvas: &skia_safe::Canvas,
        glyph: &GlyphInfo,
        _cell_width: f32,
        cell_height: f32,
        paint: &Paint,
    ) {
        let (_advance, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

        if bounds.height() <= 0.0 || bounds.width() <= 0.0 {
            let (_, metrics) = glyph.font.metrics();
            let baseline = -metrics.ascent;
            canvas.draw_str(
                &glyph.grapheme,
                Point::new(0.0, baseline),
                &glyph.font,
                paint,
            );
            return;
        }

        let target_height = cell_height;
        let left_overflow = if bounds.left < 0.0 { -bounds.left + 1.0 } else { 1.0 };
        let glyph_visual_center = (bounds.top + bounds.bottom) / 2.0;
        let cell_center = target_height / 2.0;
        let y = cell_center - glyph_visual_center;
        let x = left_overflow;

        canvas.draw_str(
            &glyph.grapheme,
            Point::new(x, y),
            &glyph.font,
            paint,
        );
    }

    fn measure_emoji(&self, glyph: &GlyphInfo) -> (f32, f32) {
        let (_advance, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

        let width = bounds.width();
        let height = bounds.height();

        if width <= 0.0 || height <= 0.0 {
            let (_, metrics) = glyph.font.metrics();
            let fallback_height = metrics.descent - metrics.ascent;
            return (fallback_height, fallback_height);
        }

        (width + 2.0, height + 2.0)
    }

    fn is_native_emoji(grapheme: &str) -> bool {
        let ch = match grapheme.chars().next() {
            Some(c) => c,
            None => return false,
        };

        let code = ch as u32;

        matches!(code,
            0x1F300..=0x1F5FF |
            0x1F600..=0x1F64F |
            0x1F680..=0x1F6FF |
            0x1F900..=0x1F9FF |
            0x1FA00..=0x1FA6F |
            0x1FA70..=0x1FAFF
        )
    }

    fn rasterize_emoji(
        &self,
        canvas: &skia_safe::Canvas,
        glyph: &GlyphInfo,
        _cell_width: f32,
        _cell_height: f32,
    ) {
        let mut paint = Paint::default();
        paint.set_anti_alias(true);
        paint.set_color4f(Color4f::new(1.0, 1.0, 1.0, 1.0), None);

        let (_advance, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

        let offset_x = -bounds.left + 1.0;
        let offset_y = -bounds.top + 1.0;

        if bounds.width() <= 0.0 || bounds.height() <= 0.0 {
            let (_, metrics) = glyph.font.metrics();
            let baseline = -metrics.ascent;
            canvas.draw_str(
                &glyph.grapheme,
                Point::new(0.0, baseline),
                &glyph.font,
                &paint,
            );
            return;
        }

        canvas.draw_str(
            &glyph.grapheme,
            Point::new(offset_x, offset_y),
            &glyph.font,
            &paint,
        );
    }

    pub fn make_key(glyph: &GlyphInfo, font_size: f32) -> GlyphKey {
        let mut flags = 0u8;

        let typeface = glyph.font.typeface();

        if typeface.is_bold() {
            flags |= GlyphKey::FLAG_BOLD;
        }
        if typeface.is_italic() {
            flags |= GlyphKey::FLAG_ITALIC;
        }
        if glyph.font.is_embolden() {
            flags |= GlyphKey::FLAG_SYNTHETIC_BOLD;
        }
        if glyph.font.skew_x() != 0.0 {
            flags |= GlyphKey::FLAG_SYNTHETIC_ITALIC;
        }

        let glyph_id = {
            use std::hash::{Hash, Hasher};
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            glyph.grapheme.hash(&mut hasher);
            hasher.finish()
        };

        let font_index = (typeface.unique_id() % 65536) as u16;
        let width = glyph.width;

        GlyphKey::new(glyph_id, font_index, font_size, width, flags)
    }
}

impl Default for GlyphRasterizer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skia_safe::Font;

    fn create_test_glyph(grapheme: &str) -> GlyphInfo {
        GlyphInfo {
            grapheme: grapheme.to_string(),
            font: Font::default(),
            x: 0.0,
            color: Color4f::new(1.0, 1.0, 1.0, 1.0),
            background_color: None,
            width: 1.0,
            decoration: None,
        }
    }

    #[test]
    fn test_rasterize_single_char() {
        let rasterizer = GlyphRasterizer::new();
        let glyph = create_test_glyph("A");

        let bitmap = rasterizer.rasterize(&glyph, 10.0, 20.0, 15.0);
        assert!(bitmap.is_some());
        let bm = bitmap.unwrap();
        assert_eq!(bm.width, 10);
        assert_eq!(bm.height, 20);
    }

    #[test]
    fn test_make_key() {
        let glyph = create_test_glyph("A");
        let key = GlyphRasterizer::make_key(&glyph, 14.0);
        assert_eq!(key.size, 140);
    }

    #[test]
    fn test_same_glyph_same_key() {
        let glyph1 = create_test_glyph("A");
        let glyph2 = create_test_glyph("A");
        let key1 = GlyphRasterizer::make_key(&glyph1, 14.0);
        let key2 = GlyphRasterizer::make_key(&glyph2, 14.0);
        assert_eq!(key1, key2);
    }

    #[test]
    fn test_different_glyph_different_key() {
        let glyph1 = create_test_glyph("A");
        let glyph2 = create_test_glyph("B");
        let key1 = GlyphRasterizer::make_key(&glyph1, 14.0);
        let key2 = GlyphRasterizer::make_key(&glyph2, 14.0);
        assert_ne!(key1, key2);
    }

    #[test]
    fn test_rasterize_wide_char() {
        let rasterizer = GlyphRasterizer::new();
        let mut glyph = create_test_glyph("中");
        glyph.width = 2.0;  // 双宽字符

        let bitmap = rasterizer.rasterize(&glyph, 10.0, 20.0, 15.0);

        assert!(bitmap.is_some());
        let bm = bitmap.unwrap();
        assert_eq!(bm.width, 20);  // 2 * 10
        assert_eq!(bm.height, 20);
    }

    #[test]
    fn test_rasterize_emoji_sequence() {
        let rasterizer = GlyphRasterizer::new();
        // Family emoji: ZWJ sequence
        let glyph = create_test_glyph("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}");

        let bitmap = rasterizer.rasterize(&glyph, 10.0, 20.0, 15.0);

        // Emoji 可能需要特殊字体，测试环境可能不支持
        // 但不应该 panic
        if let Some(bm) = bitmap {
            assert!(bm.width > 0);
            assert!(bm.height > 0);
        }
    }

    #[test]
    fn test_different_size_different_key() {
        let glyph = create_test_glyph("A");

        let key1 = GlyphRasterizer::make_key(&glyph, 14.0);
        let key2 = GlyphRasterizer::make_key(&glyph, 16.0);

        assert_ne!(key1, key2);
    }

    /// 验证 measure_str 返回的 bounds vs advance 的差异
    #[test]
    fn test_measure_str_bounds_vs_advance() {
        use skia_safe::{Font, FontMgr, FontStyle};

        // 测试字符列表
        let test_chars = vec![
            ("A", "普通字符"),
            ("中", "中文字符"),
            ("\u{2600}\u{FE0F}", "太阳 emoji (VS16)"),
            ("\u{1F5D1}", "垃圾桶 emoji"),
            ("\u{2722}", "四角星"),
            ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", "家庭 ZWJ 序列"),
        ];

        // 尝试加载 emoji 字体
        let font_mgr = FontMgr::new();
        let emoji_typeface = font_mgr
            .match_family_style("Apple Color Emoji", FontStyle::default())
            .or_else(|| font_mgr.match_family_style("Noto Color Emoji", FontStyle::default()));

        let default_font = Font::default();
        let emoji_font = emoji_typeface
            .map(|tf| Font::from_typeface(tf, 14.0))
            .unwrap_or_else(|| default_font.clone());

        println!("\n========== measure_str bounds 验证 ==========\n");

        for (ch, desc) in &test_chars {
            // 使用 emoji 字体测量 emoji
            let font = if ch.chars().count() > 1 || ch.contains('\u{FE0F}') {
                &emoji_font
            } else {
                &default_font
            };

            // measure_str 返回 (advance, bounds) - bounds 是 Rect 不是 Option
            let (advance, bounds) = font.measure_str(ch, None);
            let (_, metrics) = font.metrics();

            println!("[{}] {}", desc, ch);
            println!("  advance width: {:.2}", advance);
            println!("  bounds: left={:.2}, top={:.2}, right={:.2}, bottom={:.2}",
                bounds.left, bounds.top, bounds.right, bounds.bottom);
            println!("  bounds size: {:.2} x {:.2}", bounds.width(), bounds.height());

            // 检查溢出
            let left_overflow = if bounds.left < 0.0 { -bounds.left } else { 0.0 };
            let right_overflow = if bounds.right > advance { bounds.right - advance } else { 0.0 };
            let top_overflow = if bounds.top < metrics.ascent { metrics.ascent - bounds.top } else { 0.0 };
            let bottom_overflow = if bounds.bottom > metrics.descent { bounds.bottom - metrics.descent } else { 0.0 };

            if left_overflow > 0.0 || right_overflow > 0.0 || top_overflow > 0.0 || bottom_overflow > 0.0 {
                println!("  overflow: left={:.2}, right={:.2}, top={:.2}, bottom={:.2}",
                    left_overflow, right_overflow, top_overflow, bottom_overflow);
            }

            println!("  font metrics: ascent={:.2}, descent={:.2}",
                metrics.ascent, metrics.descent);
            println!();
        }

        // 断言：emoji 字体的 bounds 应该包含溢出信息
        let (advance, bounds) = emoji_font.measure_str("\u{2600}\u{FE0F}", None);
        println!("=== verify assertion ===");
        println!("sun advance={}, bounds.left={}, bounds.right={}", advance, bounds.left, bounds.right);

        // 验证 emoji 存在左溢出（bounds.left < 0）
        assert!(bounds.left < 0.0, "emoji should have left overflow (bounds.left < 0)");
        // 验证 emoji 存在右溢出（bounds.right > advance）
        assert!(bounds.right > advance, "emoji should have right overflow (bounds.right > advance)");
    }

    /// 验证斜体字符的 bounds 溢出情况
    #[test]
    fn test_italic_bounds_overflow() {
        use skia_safe::{Font, FontMgr, FontStyle};

        println!("\n========== italic bounds overflow verification ==========\n");

        let font_mgr = FontMgr::new();

        // 尝试获取斜体字体
        let italic_typeface = font_mgr
            .match_family_style("Menlo", FontStyle::italic())
            .or_else(|| font_mgr.match_family_style("SF Mono", FontStyle::italic()))
            .or_else(|| font_mgr.match_family_style("Monaco", FontStyle::italic()));

        let normal_typeface = font_mgr
            .match_family_style("Menlo", FontStyle::normal())
            .or_else(|| font_mgr.match_family_style("SF Mono", FontStyle::normal()));

        // 如果没有找到字体，跳过测试
        let (italic_typeface, normal_typeface) = match (italic_typeface, normal_typeface) {
            (Some(i), Some(n)) => (i, n),
            _ => {
                println!("font not found, skipping test");
                return;
            }
        };

        let italic_font = Font::from_typeface(italic_typeface, 14.0);
        let normal_font = Font::from_typeface(normal_typeface, 14.0);

        // 测试字符
        let test_chars = vec!["A", "M", "W", "f", "j", "y"];

        println!("font: {} (italic={})",
            italic_font.typeface().family_name(),
            italic_font.typeface().is_italic());

        for ch in &test_chars {
            let (normal_advance, normal_bounds) = normal_font.measure_str(ch, None);
            let (italic_advance, italic_bounds) = italic_font.measure_str(ch, None);

            println!("\n[{}]", ch);
            println!("  normal: advance={:.2}, bounds.right={:.2}, overflow={:.2}",
                normal_advance, normal_bounds.right,
                if normal_bounds.right > normal_advance { normal_bounds.right - normal_advance } else { 0.0 });
            println!("  italic: advance={:.2}, bounds.right={:.2}, overflow={:.2}",
                italic_advance, italic_bounds.right,
                if italic_bounds.right > italic_advance { italic_bounds.right - italic_advance } else { 0.0 });

            if italic_bounds.right > italic_advance {
                println!("  italic right overflow: {:.2}px", italic_bounds.right - italic_advance);
            }
        }

        // 验证斜体确实有右溢出
        let (advance, bounds) = italic_font.measure_str("M", None);
        println!("\n=== verify ===");
        println!("italic 'M': advance={:.2}, bounds.right={:.2}", advance, bounds.right);

        if italic_font.typeface().is_italic() {
            println!("using real italic font");
        } else {
            println!("not using italic font, may be synthetic italic");
        }
    }

    /// 验证需要垂直居中的符号的缩放行为
    #[test]
    fn test_centered_symbols_scaling() {
        use skia_safe::{Font, FontMgr, FontStyle};

        println!("\n========== centered symbols scaling verification ==========\n");

        let font_mgr = FontMgr::new();
        let typeface = match font_mgr
            .match_family_style("Menlo", FontStyle::normal())
            .or_else(|| font_mgr.match_family_style("SF Mono", FontStyle::normal()))
        {
            Some(tf) => tf,
            None => {
                println!("font not found, using default");
                Font::default().typeface()
            }
        };

        let font = Font::from_typeface(typeface, 14.0);

        // 模拟 cell 尺寸
        let cell_width = 8.4;
        let cell_height = 17.0;

        // 测试符号
        let symbols = vec![
            ("\u{2234}", "Therefore"),
            ("\u{00B7}", "Middle Dot"),
            ("\u{2722}", "Four Teardrop"),
            ("\u{2733}", "Eight Spoked"),
            ("\u{2736}", "Six Pointed"),
            ("\u{23FA}", "Record"),
            ("\u{2588}", "Full Block"),
        ];

        println!("Cell size: {:.1} x {:.1}", cell_width, cell_height);
        println!();

        for (sym, name) in &symbols {
            let (advance, bounds) = font.measure_str(sym, None);

            let left_overflow = if bounds.left < 0.0 { -bounds.left } else { 0.0 };
            let right_overflow = if bounds.right > advance && advance > 0.0 {
                bounds.right - advance
            } else {
                0.0
            };
            let bitmap_width = cell_width + left_overflow + right_overflow;

            let glyph_visual_center = (bounds.top + bounds.bottom) / 2.0;
            let cell_center = cell_height / 2.0;
            let y_offset = cell_center - glyph_visual_center;

            println!("[{}] {} (U+{:04X})", sym, name, sym.chars().next().unwrap() as u32);
            println!("  bounds: left={:.2}, top={:.2}, right={:.2}, bottom={:.2}",
                bounds.left, bounds.top, bounds.right, bounds.bottom);
            println!("  advance={:.2}, bounds.size={:.2}x{:.2}",
                advance, bounds.width(), bounds.height());
            println!("  overflow: left={:.2}, right={:.2} -> bitmap_width={:.2}",
                left_overflow, right_overflow, bitmap_width);
            println!("  vertical center: glyph_center={:.2}, cell_center={:.2}, y_offset={:.2}",
                glyph_visual_center, cell_center, y_offset);
            println!();
        }
    }

    /// 验证合成斜体（skew）的溢出情况
    #[test]
    fn test_synthetic_italic_overflow() {
        use skia_safe::{Font, FontMgr, FontStyle};

        println!("\n========== synthetic italic overflow verification ==========\n");

        let font_mgr = FontMgr::new();
        let typeface = match font_mgr.match_family_style("Menlo", FontStyle::normal()) {
            Some(tf) => tf,
            None => Font::default().typeface(),
        };

        let normal_font = Font::from_typeface(typeface.clone(), 14.0);
        let mut skewed_font = Font::from_typeface(typeface, 14.0);

        // 合成斜体：设置 skew_x
        skewed_font.set_skew_x(-0.25);

        println!("normal font skew_x: {}", normal_font.skew_x());
        println!("synthetic italic skew_x: {}", skewed_font.skew_x());
        println!();

        let test_chars = vec!["A", "M", "W", "H"];

        for ch in &test_chars {
            let (normal_advance, normal_bounds) = normal_font.measure_str(ch, None);
            let (skewed_advance, skewed_bounds) = skewed_font.measure_str(ch, None);

            println!("[{}]", ch);
            println!("  normal: advance={:.2}, bounds=[{:.2}, {:.2}], width={:.2}",
                normal_advance, normal_bounds.left, normal_bounds.right, normal_bounds.width());
            println!("  italic: advance={:.2}, bounds=[{:.2}, {:.2}], width={:.2}",
                skewed_advance, skewed_bounds.left, skewed_bounds.right, skewed_bounds.width());

            if skewed_bounds.right > normal_bounds.right {
                println!("  italic right shift: +{:.2}px", skewed_bounds.right - normal_bounds.right);
            }
            println!();
        }
    }

    /// 验证 CJK 字符使用字体自己的 baseline 而不是主字体的 baseline
    #[test]
    fn test_cjk_uses_own_font_baseline() {
        use skia_safe::{Font, FontMgr, FontStyle};

        let font_mgr = FontMgr::new();

        // 尝试加载 CJK 字体
        let cjk_typeface = font_mgr
            .match_family_style("PingFang SC", FontStyle::default())
            .or_else(|| font_mgr.match_family_style("Hiragino Sans GB", FontStyle::default()))
            .or_else(|| font_mgr.match_family_style("STHeiti", FontStyle::default()))
            .or_else(|| font_mgr.match_family_style("Noto Sans CJK SC", FontStyle::default()));

        // 加载拉丁字体
        let latin_typeface = font_mgr
            .match_family_style("Menlo", FontStyle::default())
            .or_else(|| font_mgr.match_family_style("SF Mono", FontStyle::default()));

        let (cjk_typeface, latin_typeface) = match (cjk_typeface, latin_typeface) {
            (Some(c), Some(l)) => (c, l),
            _ => {
                println!("CJK or Latin font not found, skipping test");
                return;
            }
        };

        let font_size = 14.0;
        let cjk_font = Font::from_typeface(cjk_typeface, font_size);
        let latin_font = Font::from_typeface(latin_typeface, font_size);

        let (_, cjk_metrics) = cjk_font.metrics();
        let (_, latin_metrics) = latin_font.metrics();

        println!("\n========== CJK Baseline alignment verification ==========\n");
        println!("Latin font: ascent={:.2}, descent={:.2}", latin_metrics.ascent, latin_metrics.descent);
        println!("CJK font: ascent={:.2}, descent={:.2}", cjk_metrics.ascent, cjk_metrics.descent);

        let primary_baseline_offset = -latin_metrics.ascent;
        let cjk_own_baseline = -cjk_metrics.ascent;

        println!("\nprimary baseline_offset: {:.2}", primary_baseline_offset);
        println!("CJK own baseline: {:.2}", cjk_own_baseline);

        let rasterizer = GlyphRasterizer::new();

        // 创建 CJK 字形
        let cjk_glyph = GlyphInfo {
            grapheme: "中".to_string(),
            font: cjk_font.clone(),
            x: 0.0,
            color: Color4f::new(1.0, 1.0, 1.0, 1.0),
            background_color: None,
            width: 2.0,
            decoration: None,
        };

        let cell_width = 8.0;
        let cell_height = -latin_metrics.ascent + latin_metrics.descent + latin_metrics.leading;

        println!("\nprimary cell_height: {:.2}", cell_height);

        let bitmap = rasterizer.rasterize(&cjk_glyph, cell_width, cell_height, primary_baseline_offset);

        assert!(bitmap.is_some(), "CJK glyph should be rasterizable");
        let bm = bitmap.unwrap();

        println!("CJK bitmap size: {}x{}", bm.width, bm.height);

        let cjk_font_height = -cjk_metrics.ascent + cjk_metrics.descent;
        println!("CJK font height: {:.2}", cjk_font_height);

        let expected_min_height = cell_height.max(cjk_font_height).ceil() as u16;
        assert!(
            bm.height >= expected_min_height,
            "bitmap height ({}) should be at least {} to contain CJK glyph",
            bm.height, expected_min_height
        );

        // 验证像素数据中顶部区域有内容
        let row_bytes = bm.row_bytes;
        let top_quarter_rows = (bm.height / 4) as usize;
        let mut top_has_content = false;

        for row in 0..top_quarter_rows {
            let row_start = row * row_bytes;
            let row_end = row_start + (bm.width as usize * 4);
            if row_end <= bm.data.len() {
                for pixel in bm.data[row_start..row_end].chunks(4) {
                    if pixel.len() == 4 && pixel[3] > 0 {
                        top_has_content = true;
                        break;
                    }
                }
            }
            if top_has_content {
                break;
            }
        }

        println!("\ntop 1/4 area has content: {}", top_has_content);
        assert!(
            top_has_content,
            "CJK glyph should start from bitmap top, not vertically centered"
        );
    }
}
