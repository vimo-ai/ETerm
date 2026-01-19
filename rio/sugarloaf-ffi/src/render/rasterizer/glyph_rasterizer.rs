//! GlyphRasterizer - 单字形光栅化器
//!
//! 将单个字形光栅化为 GlyphBitmap，用于填充 GlyphAtlas。
//! 只负责纯字形渲染，不含背景、装饰、光标等动态元素。

use crate::render::cache::{GlyphBitmap, GlyphKey};
use crate::render::layout::GlyphInfo;
use skia_safe::{Color, Color4f, Paint, Point, surfaces};

/// 单字形光栅化器
pub struct GlyphRasterizer {
    /// 最大字形尺寸（超过会截断）
    max_size: i32,
}

impl GlyphRasterizer {
    /// 默认最大尺寸 256×256（足够大多数字形）
    const DEFAULT_MAX_SIZE: i32 = 256;

    pub fn new() -> Self {
        Self {
            max_size: Self::DEFAULT_MAX_SIZE,
        }
    }

    /// 光栅化单个字形
    ///
    /// # 参数
    /// - `glyph`: 字形信息
    /// - `cell_width`: 单元格宽度
    /// - `cell_height`: 单元格高度
    /// - `baseline_offset`: 基线偏移
    ///
    /// # 返回
    /// - `Some(GlyphBitmap)`: 光栅化成功
    /// - `None`: 空字形（空格等）或失败
    pub fn rasterize(
        &self,
        glyph: &GlyphInfo,
        cell_width: f32,
        cell_height: f32,
        baseline_offset: f32,
    ) -> Option<GlyphBitmap> {
        // 检查是否需要使用 emoji 渲染路径
        // 1. 多字符序列（VS16 emoji, ZWJ 序列等）
        // 2. 单字符原生 emoji（🗑, ✢, ✳ 等不需要 VS16 的 emoji）
        let char_count = glyph.grapheme.chars().count();
        let is_emoji_sequence = char_count > 1;
        let is_native_emoji = char_count == 1 && Self::is_native_emoji(&glyph.grapheme);
        let is_emoji = is_emoji_sequence || is_native_emoji;

        // 计算 bitmap 尺寸
        let (width, height) = if is_emoji {
            // 🔧 Emoji：先测量实际尺寸，确保 bitmap 足够大
            let (emoji_width, emoji_height) = self.measure_emoji(glyph);

            // 取 (测量尺寸, 2 cell 尺寸) 的较大值
            let min_width = (cell_width * 2.0).ceil();
            let min_height = cell_height.ceil();

            let w = (emoji_width.ceil() as i32).max(min_width as i32).min(self.max_size);
            let h = (emoji_height.ceil() as i32).max(min_height as i32).min(self.max_size);
            (w, h)
        } else {
            // 普通字符：计算 bounds 以处理斜体/特殊符号溢出
            let base_width = cell_width * glyph.width;
            let (_, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

            // bitmap 宽度 = max(cell 宽度, 字形实际宽度) + 2px padding
            // +2 是为了抗锯齿边缘和浮点精度
            let glyph_width = bounds.width() + 2.0;
            let total_width = base_width.max(glyph_width);

            // 计算 bitmap 高度：使用当前字体的度量来确保能容纳字形
            // 这对于 CJK 等 fallback 字体特别重要，它们可能比主字体更高
            let (_, metrics) = glyph.font.metrics();
            let font_height = -metrics.ascent + metrics.descent;
            let total_height = cell_height.max(font_height);

            let w = (total_width.ceil() as i32).min(self.max_size);
            let h = (total_height.ceil() as i32).min(self.max_size);
            (w, h)
        };

        // 空字形检查
        if width <= 0 || height <= 0 {
            return None;
        }

        // 创建透明背景的 Surface
        let mut surface = surfaces::raster_n32_premul((width, height))?;
        let canvas = surface.canvas();
        canvas.clear(Color::TRANSPARENT);

        // 创建 Paint
        let mut paint = Paint::default();
        paint.set_anti_alias(true);
        // 使用白色绘制（实际颜色在组合时应用）
        paint.set_color4f(Color4f::new(1.0, 1.0, 1.0, 1.0), None);

        if is_emoji {
            // Emoji：靠左 + 垂直居中
            self.rasterize_emoji(canvas, glyph, width as f32, height as f32);
        } else if glyph.needs_vertical_center() {
            // 特殊符号：垂直居中 + 超宽缩放
            self.rasterize_centered(canvas, glyph, cell_width, cell_height, &paint);
        } else {
            // 普通字符：baseline 对齐
            self.rasterize_normal(canvas, glyph, baseline_offset, &paint);
        }

        // 提取像素数据
        let image = surface.image_snapshot();
        let info = image.image_info();
        let row_bytes = info.min_row_bytes();
        let data_size = row_bytes * height as usize;

        // 读取像素
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

    /// 光栅化普通字符（baseline 对齐）
    ///
    /// 处理斜体等字符的左/右溢出：
    /// - 如果有左溢出（bounds.left < 0），向右偏移以避免被切
    /// - 加 1px padding 配合 bitmap 尺寸计算中的 +2
    ///
    /// 注意：使用当前字体自己的 ascent 来计算 baseline 位置，
    /// 而不是使用基于主字体计算的 baseline_offset。
    /// 这确保 CJK 等 fallback 字体的字形能够正确地在 bitmap 中顶部对齐。
    fn rasterize_normal(
        &self,
        canvas: &skia_safe::Canvas,
        glyph: &GlyphInfo,
        _baseline_offset: f32, // 保留参数签名兼容性，但使用字体自己的 ascent
        paint: &Paint,
    ) {
        // 检查是否有左溢出，+1 是 padding
        let (_, bounds) = glyph.font.measure_str(&glyph.grapheme, None);
        let x_offset = if bounds.left < 0.0 { -bounds.left + 1.0 } else { 1.0 };

        // 使用当前字体自己的 ascent 计算 baseline
        // 这样 CJK 字体的字形会在 bitmap 顶部对齐，而不是垂直居中
        let (_, metrics) = glyph.font.metrics();
        let font_baseline = -metrics.ascent;

        canvas.draw_str(
            &glyph.grapheme,
            Point::new(x_offset, font_baseline),
            &glyph.font,
            paint,
        );
    }

    /// 光栅化需要垂直居中的符号
    ///
    /// 这些符号（如 ∴ · ✳ ⏺）的视觉中心不在 baseline 上，
    /// 需要基于 ink bounds 计算垂直居中位置。
    ///
    /// 注意：不缩放符号，允许溢出到相邻 cell（终端常见做法）。
    /// bitmap 尺寸已经在 rasterize() 中扩大以容纳溢出。
    fn rasterize_centered(
        &self,
        canvas: &skia_safe::Canvas,
        glyph: &GlyphInfo,
        _cell_width: f32,
        cell_height: f32,
        paint: &Paint,
    ) {
        // 获取字形的 ink bounds
        let (_advance, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

        // 如果 bounds 无效，回退到 baseline 渲染
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

        // 计算目标尺寸
        let target_height = cell_height;

        // 计算左溢出偏移 +1 padding（与 bitmap 尺寸计算一致）
        let left_overflow = if bounds.left < 0.0 { -bounds.left + 1.0 } else { 1.0 };

        // 垂直居中
        let glyph_visual_center = (bounds.top + bounds.bottom) / 2.0;
        let cell_center = target_height / 2.0;
        let y = cell_center - glyph_visual_center;

        // 水平：靠左对齐 + 左溢出补偿
        let x = left_overflow;

        canvas.draw_str(
            &glyph.grapheme,
            Point::new(x, y),
            &glyph.font,
            paint,
        );
    }

    /// 测量 emoji 的实际渲染尺寸
    ///
    /// 使用 ink bounds（墨迹边界）而非 advance width
    /// 这是正确渲染 emoji 的关键：bounds 包含了完整的视觉边界
    fn measure_emoji(&self, glyph: &GlyphInfo) -> (f32, f32) {
        // measure_str 返回 (advance, bounds)
        // - advance: 排版前进宽度（不含溢出）
        // - bounds: 墨迹边界（包含左右上下溢出）
        let (_advance, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

        // 使用 bounds 的实际尺寸
        let width = bounds.width();
        let height = bounds.height();

        // 如果 bounds 为空（字体不支持），回退到 metrics
        if width <= 0.0 || height <= 0.0 {
            let (_, metrics) = glyph.font.metrics();
            let fallback_height = metrics.descent - metrics.ascent;
            return (fallback_height, fallback_height);  // 假设 emoji 是方形的
        }

        // 加 2px padding（比 20% 更精确，因为已经用了 bounds）
        (width + 2.0, height + 2.0)
    }

    /// 检测是否为原生 emoji（Emoji_Presentation=Yes，不需要 VS16）
    ///
    /// 只包含默认以 emoji 形式显示的字符范围。
    ///
    /// 注意：Miscellaneous Symbols (0x2600-0x26FF) 和 Dingbats (0x2700-0x27BF)
    /// 中的字符（如 ☀ U+2600、✳ U+2733）默认是文本展示，需要 VS16 才变成 emoji，
    /// 所以不在这里。它们作为多字符序列（带 VS16）会在 char_count > 1 时被识别。
    fn is_native_emoji(grapheme: &str) -> bool {
        let ch = match grapheme.chars().next() {
            Some(c) => c,
            None => return false,
        };

        let code = ch as u32;

        // 只包含 Emoji_Presentation=Yes 的范围（默认 emoji 展示）
        matches!(code,
            // Miscellaneous Symbols and Pictographs (🗑 U+1F5D1 在这里)
            0x1F300..=0x1F5FF |
            // Emoticons (😀 等)
            0x1F600..=0x1F64F |
            // Transport and Map Symbols (🚀 等)
            0x1F680..=0x1F6FF |
            // Supplemental Symbols and Pictographs
            0x1F900..=0x1F9FF |
            // Symbols and Pictographs Extended-A
            0x1FA00..=0x1FA6F |
            // Symbols and Pictographs Extended-B
            0x1FA70..=0x1FAFF
        )
    }

    /// 光栅化 Emoji
    ///
    /// 使用 ink bounds 偏移来确保完整渲染，不被裁剪
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

        // 获取 ink bounds
        let (_advance, bounds) = glyph.font.measure_str(&glyph.grapheme, None);

        // 计算绘制偏移：补偿 bounds 的左/上溢出
        // - bounds.left < 0 表示左溢出，需要右移 (-bounds.left)
        // - bounds.top < 0 表示上溢出（相对于 baseline），需要下移
        let offset_x = -bounds.left + 1.0;  // +1 是 padding 的一半
        let offset_y = -bounds.top + 1.0;

        // 如果 bounds 无效，回退到原来的 baseline 计算
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

    /// 从 GlyphInfo 创建 GlyphKey
    pub fn make_key(glyph: &GlyphInfo, font_size: f32) -> GlyphKey {
        let mut flags = 0u8;

        // 检测 bold/italic
        let typeface = glyph.font.typeface();

        // 原生粗体（typeface 自带）
        if typeface.is_bold() {
            flags |= GlyphKey::FLAG_BOLD;
        }
        // 原生斜体（typeface 自带）
        if typeface.is_italic() {
            flags |= GlyphKey::FLAG_ITALIC;
        }

        // 合成粗体（通过 font.set_embolden(true) 设置）
        if glyph.font.is_embolden() {
            flags |= GlyphKey::FLAG_SYNTHETIC_BOLD;
        }
        // 合成斜体（通过 font.set_skew_x(-0.25) 设置）
        // skew_x != 0 表示有倾斜
        if glyph.font.skew_x() != 0.0 {
            flags |= GlyphKey::FLAG_SYNTHETIC_ITALIC;
        }

        // 字形 ID（使用 grapheme 的完整 64 位 hash，避免冲突）
        let glyph_id = {
            use std::hash::{Hash, Hasher};
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            glyph.grapheme.hash(&mut hasher);
            hasher.finish()  // 完整 64 位，不截断
        };

        // 字体索引（暂时用 0，后续从 FontContext 获取）
        let font_index = 0u16;

        // 字符宽度（1=单宽, 2=双宽 emoji/中文）
        let width = glyph.width;

        GlyphKey::new(glyph_id, font_index, font_size, width, flags)
    }
}

impl Default for GlyphRasterizer {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// Tests
// ============================================================================

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
        assert!(!bm.data.is_empty());
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
        // Family emoji: 👨‍👩‍👧‍👦 (ZWJ sequence)
        let glyph = create_test_glyph("👨‍👩‍👧‍👦");

        let bitmap = rasterizer.rasterize(&glyph, 10.0, 20.0, 15.0);

        // Emoji 可能需要特殊字体，测试环境可能不支持
        // 但不应该 panic
        if let Some(bm) = bitmap {
            assert!(bm.width > 0);
            assert!(bm.height > 0);
        }
    }

    #[test]
    fn test_make_key() {
        let glyph = create_test_glyph("A");
        let key = GlyphRasterizer::make_key(&glyph, 14.0);

        assert_eq!(key.size, 140);  // 14.0 * 10
        assert_eq!(key.font_index, 0);
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
            ("☀️", "太阳 emoji (VS16)"),
            ("🗑", "垃圾桶 emoji"),
            ("✢", "四角星"),
            ("👨‍👩‍👧‍👦", "家庭 ZWJ 序列"),
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

            println!("【{}】 {}", desc, ch);
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
                println!("  ⚠️ 溢出: left={:.2}, right={:.2}, top={:.2}, bottom={:.2}",
                    left_overflow, right_overflow, top_overflow, bottom_overflow);
            }

            println!("  font metrics: ascent={:.2}, descent={:.2}",
                metrics.ascent, metrics.descent);
            println!();
        }

        // 断言：emoji 字体的 bounds 应该包含溢出信息
        // 用 emoji 字体测量一个已知会溢出的 emoji
        let (advance, bounds) = emoji_font.measure_str("☀️", None);
        println!("=== 验证断言 ===");
        println!("☀️ advance={}, bounds.left={}, bounds.right={}", advance, bounds.left, bounds.right);

        // 验证 emoji 存在左溢出（bounds.left < 0）
        assert!(bounds.left < 0.0, "emoji 应该有左溢出 (bounds.left < 0)");
        // 验证 emoji 存在右溢出（bounds.right > advance）
        assert!(bounds.right > advance, "emoji 应该有右溢出 (bounds.right > advance)");

        println!("\n✅ 验证通过：emoji 确实存在超出 advance 的溢出！");
        println!("   这就是新方案用 advance + metrics 导致裁剪的根本原因。");
        println!("   解决方案：用 bounds 代替 advance 来计算 bitmap 尺寸。");
    }

    /// 验证斜体字符的 bounds 溢出情况
    /// 斜体会向右倾斜，导致 bounds.right > advance
    #[test]
    fn test_italic_bounds_overflow() {
        use skia_safe::{Font, FontMgr, FontStyle};

        println!("\n========== 斜体 bounds 溢出验证 ==========\n");

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
                println!("⚠️ 未找到 Menlo/SF Mono 字体，跳过测试");
                return;
            }
        };

        let italic_font = Font::from_typeface(italic_typeface, 14.0);
        let normal_font = Font::from_typeface(normal_typeface, 14.0);

        // 测试字符
        let test_chars = vec!["A", "M", "W", "f", "j", "y"];

        println!("字体: {} (italic={})",
            italic_font.typeface().family_name(),
            italic_font.typeface().is_italic());

        for ch in &test_chars {
            let (normal_advance, normal_bounds) = normal_font.measure_str(ch, None);
            let (italic_advance, italic_bounds) = italic_font.measure_str(ch, None);

            println!("\n【{}】", ch);
            println!("  正常: advance={:.2}, bounds.right={:.2}, 溢出={:.2}",
                normal_advance, normal_bounds.right,
                if normal_bounds.right > normal_advance { normal_bounds.right - normal_advance } else { 0.0 });
            println!("  斜体: advance={:.2}, bounds.right={:.2}, 溢出={:.2}",
                italic_advance, italic_bounds.right,
                if italic_bounds.right > italic_advance { italic_bounds.right - italic_advance } else { 0.0 });

            // 斜体的右边界通常会超出 advance
            if italic_bounds.right > italic_advance {
                println!("  ⚠️ 斜体右溢出: {:.2}px", italic_bounds.right - italic_advance);
            }
        }

        // 验证斜体确实有右溢出
        let (advance, bounds) = italic_font.measure_str("M", None);
        println!("\n=== 验证 ===");
        println!("斜体 'M': advance={:.2}, bounds.right={:.2}", advance, bounds.right);

        // 斜体字符通常会有右溢出，但如果字体不支持斜体可能不会
        if italic_font.typeface().is_italic() {
            println!("✅ 使用了真正的斜体字体");
        } else {
            println!("⚠️ 未使用斜体字体，可能是合成斜体");
        }
    }

    /// 验证需要垂直居中的符号的缩放行为
    #[test]
    fn test_centered_symbols_scaling() {
        use skia_safe::{Font, FontMgr, FontStyle};

        println!("\n========== 居中符号缩放验证 ==========\n");

        let font_mgr = FontMgr::new();
        let typeface = match font_mgr
            .match_family_style("Menlo", FontStyle::normal())
            .or_else(|| font_mgr.match_family_style("SF Mono", FontStyle::normal()))
        {
            Some(tf) => tf,
            None => {
                println!("⚠️ 未找到 Menlo/SF Mono 字体，使用默认字体");
                // 使用默认 Font 的 typeface
                Font::default().typeface()
            }
        };

        let font = Font::from_typeface(typeface, 14.0);

        // 模拟 cell 尺寸
        let cell_width = 8.4;  // 典型的 14pt 等宽字体单 cell 宽度
        let cell_height = 17.0;

        // 测试符号
        let symbols = vec![
            ("∴", "Therefore"),
            ("·", "Middle Dot"),
            ("✢", "Four Teardrop"),
            ("✳", "Eight Spoked"),
            ("✶", "Six Pointed"),
            ("⏺", "Record"),
            ("█", "Full Block"),
        ];

        println!("Cell 尺寸: {:.1} x {:.1}", cell_width, cell_height);
        println!();

        for (sym, name) in &symbols {
            let (advance, bounds) = font.measure_str(sym, None);

            // 计算实际渲染位置（模拟 rasterize_centered 逻辑）
            let left_overflow = if bounds.left < 0.0 { -bounds.left } else { 0.0 };
            let right_overflow = if bounds.right > advance && advance > 0.0 {
                bounds.right - advance
            } else {
                0.0
            };
            let bitmap_width = cell_width + left_overflow + right_overflow;

            // 垂直居中计算
            let glyph_visual_center = (bounds.top + bounds.bottom) / 2.0;
            let cell_center = cell_height / 2.0;
            let y_offset = cell_center - glyph_visual_center;

            println!("【{}】 {} (U+{:04X})", sym, name, sym.chars().next().unwrap() as u32);
            println!("  bounds: left={:.2}, top={:.2}, right={:.2}, bottom={:.2}",
                bounds.left, bounds.top, bounds.right, bounds.bottom);
            println!("  advance={:.2}, bounds.size={:.2}x{:.2}",
                advance, bounds.width(), bounds.height());
            println!("  溢出: left={:.2}, right={:.2} → bitmap_width={:.2}",
                left_overflow, right_overflow, bitmap_width);
            println!("  垂直居中: glyph_center={:.2}, cell_center={:.2}, y_offset={:.2}",
                glyph_visual_center, cell_center, y_offset);
            println!();
        }
    }

    /// 验证合成斜体（skew）的溢出情况
    #[test]
    fn test_synthetic_italic_overflow() {
        use skia_safe::{Font, FontMgr, FontStyle};

        println!("\n========== 合成斜体溢出验证 ==========\n");

        let font_mgr = FontMgr::new();
        let typeface = match font_mgr.match_family_style("Menlo", FontStyle::normal()) {
            Some(tf) => tf,
            None => Font::default().typeface(),
        };

        let normal_font = Font::from_typeface(typeface.clone(), 14.0);
        let mut skewed_font = Font::from_typeface(typeface, 14.0);

        // 合成斜体：设置 skew_x
        skewed_font.set_skew_x(-0.25);  // 典型的斜体倾斜值

        println!("正常字体 skew_x: {}", normal_font.skew_x());
        println!("合成斜体 skew_x: {}", skewed_font.skew_x());
        println!();

        let test_chars = vec!["A", "M", "W", "H"];

        for ch in &test_chars {
            let (normal_advance, normal_bounds) = normal_font.measure_str(ch, None);
            let (skewed_advance, skewed_bounds) = skewed_font.measure_str(ch, None);

            println!("【{}】", ch);
            println!("  正常: advance={:.2}, bounds=[{:.2}, {:.2}], width={:.2}",
                normal_advance, normal_bounds.left, normal_bounds.right, normal_bounds.width());
            println!("  斜体: advance={:.2}, bounds=[{:.2}, {:.2}], width={:.2}",
                skewed_advance, skewed_bounds.left, skewed_bounds.right, skewed_bounds.width());

            // 合成斜体的右边界应该更大
            if skewed_bounds.right > normal_bounds.right {
                println!("  ⚠️ 斜体右移: +{:.2}px", skewed_bounds.right - normal_bounds.right);
            }
            println!();
        }
    }

    /// 验证 CJK 字符使用字体自己的 baseline 而不是主字体的 baseline
    /// 这确保 CJK 字符顶部对齐而不是垂直居中
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
                println!("⚠️ 未找到 CJK 或 Latin 字体，跳过测试");
                return;
            }
        };

        let font_size = 14.0;
        let cjk_font = Font::from_typeface(cjk_typeface, font_size);
        let latin_font = Font::from_typeface(latin_typeface, font_size);

        // 获取两种字体的 metrics
        let (_, cjk_metrics) = cjk_font.metrics();
        let (_, latin_metrics) = latin_font.metrics();

        println!("\n========== CJK Baseline 对齐验证 ==========\n");
        println!("Latin 字体: ascent={:.2}, descent={:.2}", latin_metrics.ascent, latin_metrics.descent);
        println!("CJK 字体: ascent={:.2}, descent={:.2}", cjk_metrics.ascent, cjk_metrics.descent);

        // 主字体的 baseline_offset（模拟 renderer 中的计算）
        let primary_baseline_offset = -latin_metrics.ascent;

        // CJK 字体自己的 baseline
        let cjk_own_baseline = -cjk_metrics.ascent;

        println!("\n主字体 baseline_offset: {:.2}", primary_baseline_offset);
        println!("CJK 字体自己的 baseline: {:.2}", cjk_own_baseline);

        // 验证修复：rasterize_normal 现在使用字体自己的 baseline
        // 而不是传入的 baseline_offset
        let rasterizer = GlyphRasterizer::new();

        // 创建 CJK 字形
        let mut cjk_glyph = GlyphInfo {
            grapheme: "中".to_string(),
            font: cjk_font.clone(),
            x: 0.0,
            color: Color4f::new(1.0, 1.0, 1.0, 1.0),
            background_color: None,
            width: 2.0,
            decoration: None,
        };

        // 模拟主字体的 cell 尺寸
        let cell_width = 8.0;
        let cell_height = -latin_metrics.ascent + latin_metrics.descent + latin_metrics.leading;

        println!("\n主字体 cell_height: {:.2}", cell_height);

        // 光栅化 CJK 字形
        let bitmap = rasterizer.rasterize(&cjk_glyph, cell_width, cell_height, primary_baseline_offset);

        assert!(bitmap.is_some(), "CJK 字形应该能够光栅化");
        let bm = bitmap.unwrap();

        println!("CJK bitmap 尺寸: {}x{}", bm.width, bm.height);

        // 关键验证：bitmap 高度应该至少能容纳 CJK 字体的完整高度
        let cjk_font_height = -cjk_metrics.ascent + cjk_metrics.descent;
        println!("CJK 字体高度: {:.2}", cjk_font_height);

        // 修复后，bitmap 高度应该是 max(cell_height, cjk_font_height)
        let expected_min_height = cell_height.max(cjk_font_height).ceil() as u16;
        assert!(
            bm.height >= expected_min_height,
            "bitmap 高度 ({}) 应该至少为 {} 以容纳 CJK 字形",
            bm.height, expected_min_height
        );

        // 验证像素数据中顶部区域有内容（字形从顶部开始，而不是居中）
        // 检查 bitmap 顶部 1/4 区域是否有非零像素
        let row_bytes = bm.row_bytes;
        let top_quarter_rows = (bm.height / 4) as usize;
        let mut top_has_content = false;

        for row in 0..top_quarter_rows {
            let row_start = row * row_bytes;
            let row_end = row_start + (bm.width as usize * 4); // RGBA
            if row_end <= bm.data.len() {
                for pixel in bm.data[row_start..row_end].chunks(4) {
                    // 检查 alpha 通道是否非零
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

        println!("\n顶部 1/4 区域有内容: {}", top_has_content);
        assert!(
            top_has_content,
            "CJK 字形应该从 bitmap 顶部开始绘制，而不是垂直居中"
        );

        println!("\n✅ 验证通过：CJK 字符使用字体自己的 baseline，顶部对齐正确");
    }
}
