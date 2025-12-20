
use crate::domain::views::grid::UrlRange;
use crate::render::cache::GlyphLayout;
use crate::render::cache::{CursorInfo, SearchMatchInfo, HyperlinkHoverInfo};
use crate::render::box_drawing::{detect_drawable_character, BoxDrawingConfig};
use rio_backend::ansi::CursorShape;
use skia_safe::{Image, Paint, ImageInfo, ColorType, AlphaType, Point, Color4f, FontMgr, Color};
use skia_safe::textlayout::{FontCollection, ParagraphBuilder, ParagraphStyle, TextStyle};
use sugarloaf::layout::{FragmentStyleDecoration, UnderlineShape};
use std::cell::RefCell;

thread_local! {
    /// 线程本地 FontCollection（用于 emoji shaping）
    static FONT_COLLECTION: RefCell<FontCollection> = RefCell::new({
        let mut fc = FontCollection::new();
        fc.set_default_font_manager(FontMgr::new(), None);
        fc
    });
}

/// Color4f 转 Color
fn color4f_to_color(c: Color4f) -> Color {
    Color::from_argb(
        (c.a * 255.0) as u8,
        (c.r * 255.0) as u8,
        (c.g * 255.0) as u8,
        (c.b * 255.0) as u8,
    )
}

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
    /// - cursor_info: 光标信息（从 TerminalState 动态计算，不从 layout 缓存读取）
    /// - search_info: 搜索匹配信息（从 TerminalState 动态计算）
    /// - hyperlink_hover_info: 超链接悬停信息（Cmd+hover 时显示下划线）
    /// - url_ranges: 自动检测的 URL 范围（始终显示下划线）
    /// - line_width: 行宽度（像素）
    /// - cell_width: 单元格宽度（像素）
    /// - cell_height: 单元格高度（像素）
    /// - line_height: 完整行高（物理像素，= cell_height * line_height_factor）
    /// - baseline_offset: 基线偏移（y 坐标）
    /// - background_color: 背景色
    /// - box_drawing_config: Box-drawing 字符渲染配置
    ///
    /// 注意：IME 渲染已移到独立的 overlay 层（draw_ime_overlay）
    pub fn render(
        &self,
        layout: &GlyphLayout,
        cursor_info: Option<&CursorInfo>,
        search_info: Option<&SearchMatchInfo>,
        hyperlink_hover_info: Option<&HyperlinkHoverInfo>,
        url_ranges: &[UrlRange],
        line_width: f32,
        cell_width: f32,
        cell_height: f32,
        line_height: f32,
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

        // ===== 步骤 2: 填充背景色 =====
        canvas.clear(background_color);

        // ===== 步骤 3: 创建 Paint =====
        let mut paint = Paint::default();
        paint.set_anti_alias(true);

        // ===== 步骤 4: 遍历字形，绘制字符 =====
        // 跟踪当前列号（用于选区/搜索检测）
        let mut current_col: usize = 0;

        for glyph in &layout.glyphs {
            // 检查当前字符是否在搜索匹配内
            // 返回 Some(is_focused) 表示在匹配内
            let search_match = search_info.and_then(|info| {
                info.ranges.iter().find_map(|&(start, end, is_focused)| {
                    if current_col >= start && current_col <= end {
                        Some(is_focused)
                    } else {
                        None
                    }
                })
            });

            // 检查当前字符是否在超链接悬停范围内
            let in_hyperlink_hover = hyperlink_hover_info.map_or(false, |info| {
                current_col >= info.start_col && current_col <= info.end_col
            });

            // 检查当前字符是否在自动检测的 URL 范围内
            let in_url = url_ranges.iter().any(|url| {
                current_col >= url.start_col && current_col <= url.end_col
            });

            // 确定背景色优先级：搜索 > 原始
            let effective_bg_color = if let Some(is_focused) = search_match {
                // 搜索匹配内
                let info = search_info.unwrap();
                let bg = if is_focused { info.focused_bg_color } else { info.bg_color };
                Some(Color4f::new(bg[0], bg[1], bg[2], bg[3]))
            } else {
                // 非搜索：使用字形原有背景色
                glyph.background_color
            };

            // 先绘制背景色（如果有）
            if let Some(bg_color) = effective_bg_color {
                let mut bg_paint = Paint::default();
                bg_paint.set_color4f(bg_color, None);
                // 使用 glyph.width（1.0 或 2.0）计算背景矩形宽度
                let bg_width = cell_width * glyph.width;
                // 背景填满整个 line_height
                let rect = skia_safe::Rect::from_xywh(glyph.x, 0.0, bg_width, line_height);
                canvas.draw_rect(rect, &bg_paint);
            }

            // 确定前景色优先级：搜索 > 超链接悬停 > 原始
            let effective_fg_color = if let Some(is_focused) = search_match {
                let info = search_info.unwrap();
                let fg = if is_focused { info.focused_fg_color } else { info.fg_color };
                Color4f::new(fg[0], fg[1], fg[2], fg[3])
            } else if in_hyperlink_hover {
                // 超链接悬停：使用蓝色
                let info = hyperlink_hover_info.unwrap();
                Color4f::new(info.fg_color[0], info.fg_color[1], info.fg_color[2], info.fg_color[3])
            } else {
                glyph.color
            };

            // 设置字符颜色
            paint.set_color4f(effective_fg_color, None);

            // 检查是否是多字符 grapheme（emoji 序列）
            let char_count = glyph.grapheme.chars().count();
            let is_emoji_sequence = char_count > 1;

            // 🎯 对 box-drawing 字符进行形变拉伸，填满整个 line_height
            // 只有单字符的 grapheme 才可能是 box-drawing 字符
            let is_box_drawing = char_count == 1
                && detect_drawable_character(glyph.grapheme.chars().next().unwrap()).is_some()
                && box_drawing_config.enabled;

            if is_box_drawing {
                // 计算缩放比例：让字形填满整个 line_height
                let scale_y = line_height / cell_height;

                // 保存画布状态
                canvas.save();

                // 平移到字符位置，应用 Y 轴缩放
                canvas.translate((glyph.x, 0.0));
                canvas.scale((1.0, scale_y));

                // 绘制（缩放后 baseline 也需要调整）
                canvas.draw_str(&glyph.grapheme, Point::new(0.0, baseline_offset / scale_y), &glyph.font, &paint);

                // 恢复画布状态
                canvas.restore();
            } else if is_emoji_sequence {
                // 🎯 Emoji 序列：使用 Paragraph 进行 HarfBuzz shaping
                // 这样才能正确渲染 keycap、ZWJ 序列等复杂 emoji
                FONT_COLLECTION.with(|fc| {
                    let font_collection = fc.borrow();

                    let mut paragraph_style = ParagraphStyle::new();
                    let mut text_style = TextStyle::new();
                    text_style.set_font_size(glyph.font.size());
                    text_style.set_color(color4f_to_color(effective_fg_color));
                    // 使用 emoji 字体
                    text_style.set_font_families(&["Apple Color Emoji"]);
                    paragraph_style.set_text_style(&text_style);

                    let mut builder = ParagraphBuilder::new(&paragraph_style, font_collection.clone());
                    builder.add_text(&glyph.grapheme);

                    let mut paragraph = builder.build();
                    paragraph.layout(cell_width * glyph.width + 10.0);

                    // Paragraph 从左上角开始绘制，对齐基线
                    let para_baseline = paragraph.alphabetic_baseline();
                    let y_offset = baseline_offset - para_baseline;
                    paragraph.paint(canvas, Point::new(glyph.x, y_offset));
                });
            } else {
                // 普通字符：正常绘制（使用完整 grapheme cluster）
                canvas.draw_str(&glyph.grapheme, Point::new(glyph.x, baseline_offset), &glyph.font, &paint);
            }

            // ===== 绘制装饰（下划线、删除线）=====
            if let Some(decoration) = &glyph.decoration {
                let glyph_width = cell_width * glyph.width;
                let decoration_paint = &paint;  // 复用字符颜色

                match decoration {
                    FragmentStyleDecoration::Strikethrough => {
                        // 删除线：在字符中间位置
                        let strike_y = baseline_offset - cell_height * 0.3;  // 大约在字符中间
                        let stroke_width = 1.0;
                        let mut strike_paint = decoration_paint.clone();
                        strike_paint.set_stroke_width(stroke_width);
                        strike_paint.set_style(skia_safe::PaintStyle::Stroke);
                        canvas.draw_line(
                            Point::new(glyph.x, strike_y),
                            Point::new(glyph.x + glyph_width, strike_y),
                            &strike_paint,
                        );
                    }
                    FragmentStyleDecoration::Underline(info) => {
                        // 下划线：在基线下方，但不能超出 line_height
                        let underline_y = (baseline_offset + 2.0).min(line_height - 2.0);
                        let stroke_width = if info.is_doubled { 1.0 } else { 1.5 };

                        let mut underline_paint = decoration_paint.clone();
                        underline_paint.set_stroke_width(stroke_width);
                        underline_paint.set_style(skia_safe::PaintStyle::Stroke);

                        match info.shape {
                            UnderlineShape::Regular => {
                                // 普通下划线
                                canvas.draw_line(
                                    Point::new(glyph.x, underline_y),
                                    Point::new(glyph.x + glyph_width, underline_y),
                                    &underline_paint,
                                );
                                // 双下划线
                                if info.is_doubled {
                                    canvas.draw_line(
                                        Point::new(glyph.x, underline_y + 3.0),
                                        Point::new(glyph.x + glyph_width, underline_y + 3.0),
                                        &underline_paint,
                                    );
                                }
                            }
                            UnderlineShape::Dotted => {
                                // 点状下划线
                                underline_paint.set_path_effect(skia_safe::PathEffect::dash(&[2.0, 2.0], 0.0));
                                canvas.draw_line(
                                    Point::new(glyph.x, underline_y),
                                    Point::new(glyph.x + glyph_width, underline_y),
                                    &underline_paint,
                                );
                            }
                            UnderlineShape::Dashed => {
                                // 虚线下划线
                                underline_paint.set_path_effect(skia_safe::PathEffect::dash(&[4.0, 2.0], 0.0));
                                canvas.draw_line(
                                    Point::new(glyph.x, underline_y),
                                    Point::new(glyph.x + glyph_width, underline_y),
                                    &underline_paint,
                                );
                            }
                            UnderlineShape::Curly => {
                                // 波浪下划线（undercurl）- 确保不超出 line_height
                                let wave_amplitude = 1.5;
                                let wave_length = 4.0;
                                let mut path = skia_safe::Path::new();

                                // 波浪中心线在 underline_y 上方，留出 stroke_width 余量
                                // 这样波浪的最低点 + stroke_width/2 不会超出 line_height
                                let max_bottom = line_height - stroke_width;
                                let center_y = (max_bottom - wave_amplitude).min(underline_y);
                                let top_y = center_y - wave_amplitude;
                                let bottom_y = center_y + wave_amplitude;

                                path.move_to(Point::new(glyph.x, center_y));

                                let mut x = glyph.x;
                                let mut up = true;
                                while x < glyph.x + glyph_width {
                                    let next_x = (x + wave_length).min(glyph.x + glyph_width);
                                    let ctrl_y = if up { top_y } else { bottom_y };
                                    path.quad_to(
                                        Point::new(x + wave_length / 2.0, ctrl_y),
                                        Point::new(next_x, center_y),
                                    );
                                    x = next_x;
                                    up = !up;
                                }

                                canvas.draw_path(&path, &underline_paint);
                            }
                        }
                    }
                }
            }

            // ===== 绘制超链接下划线（如果在悬停范围内）=====
            if in_hyperlink_hover {
                let glyph_width = cell_width * glyph.width;
                let underline_y = (baseline_offset + 2.0).min(line_height - 2.0);
                let stroke_width = 1.5;

                let info = hyperlink_hover_info.unwrap();
                let mut underline_paint = Paint::default();
                underline_paint.set_color4f(
                    Color4f::new(info.fg_color[0], info.fg_color[1], info.fg_color[2], info.fg_color[3]),
                    None,
                );
                underline_paint.set_stroke_width(stroke_width);
                underline_paint.set_style(skia_safe::PaintStyle::Stroke);
                underline_paint.set_anti_alias(true);

                canvas.draw_line(
                    Point::new(glyph.x, underline_y),
                    Point::new(glyph.x + glyph_width, underline_y),
                    &underline_paint,
                );
            }

            // ===== 绘制 URL 下划线（自动检测的 URL，始终显示）=====
            // 如果已经在超链接悬停范围内，不重复绘制下划线
            if in_url && !in_hyperlink_hover {
                let glyph_width = cell_width * glyph.width;
                let underline_y = (baseline_offset + 2.0).min(line_height - 2.0);
                let stroke_width = 1.0;

                // URL 使用蓝色下划线
                let url_color = Color4f::new(0.4, 0.6, 1.0, 1.0);
                let mut underline_paint = Paint::default();
                underline_paint.set_color4f(url_color, None);
                underline_paint.set_stroke_width(stroke_width);
                underline_paint.set_style(skia_safe::PaintStyle::Stroke);
                underline_paint.set_anti_alias(true);

                canvas.draw_line(
                    Point::new(glyph.x, underline_y),
                    Point::new(glyph.x + glyph_width, underline_y),
                    &underline_paint,
                );
            }

            // 更新列号（用于下一个字符的选区检测）
            current_col += glyph.width as usize;
        }

        // ===== 步骤 4.5: 绘制光标（如果有）=====
        if let Some(cursor) = cursor_info {
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
        // ===== 步骤 5: 获取 Image =====
        // 注意：IME 渲染已移到独立的 overlay 层（类似 SelectionOverlay）
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
        };

        let image = rasterizer.render(
            &layout,
            None,   // cursor_info
            None,   // search_info
            None,   // hyperlink_hover_info
            None,   // ime_info
            &[],    // url_ranges
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
                grapheme: "A".to_string(),
                font,
                x: 0.0,
                color: Color4f::new(1.0, 1.0, 1.0, 1.0),  // 白色
                background_color: None,
                width: 1.0,  // 单宽字符
                decoration: None,
            }],
        };

        let image = rasterizer.render(
            &layout,
            None,   // cursor_info
            None,   // search_info
            None,   // hyperlink_hover_info
            None,   // ime_info
            &[],    // url_ranges
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
