
use crate::glyph_info::GlyphInfo;
use crate::font_context::FontContext;
use crate::glyph_layout::GlyphLayout;
use sugarloaf::layout::BuilderLine;
use skia_safe::{Font, Color4f};
use std::sync::Arc;

pub struct TextShaper {
    font_context: Arc<FontContext>,
}

impl TextShaper {
    pub fn new(font_context: Arc<FontContext>) -> Self {
        Self { font_context }
    }

    pub fn shape_line(
        &self,
        line: &BuilderLine,
        font_size: f32,
        cell_width: f32,
    ) -> GlyphLayout {
        let mut glyphs = Vec::new();
        let mut x = 0.0;

        for fragment in &line.fragments {
            let styled_typeface = self.font_context.get_typeface_for_font_id(fragment.style.font_id);
            let styled_font = styled_typeface
                .as_ref()
                .map(|tf| Font::from_typeface(tf, font_size))
                .unwrap_or_else(|| self.font_context.get_primary_font(font_size));

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

                let (best_font, _is_emoji) = if is_keycap_sequence {
                    if let Some(emoji_font) = self.font_context.get_emoji_font(font_size) {
                        (emoji_font, true)
                    } else {
                        self.font_context.find_font_for_char(ch, font_size, &styled_font)
                    }
                } else if next_is_vs16 {
                    if let Some(emoji_font) = self.font_context.find_emoji_font(ch, font_size) {
                        (emoji_font, true)
                    } else {
                        self.font_context.find_font_for_char(ch, font_size, &styled_font)
                    }
                } else if (ch as u32) >= 0x80 {
                    self.font_context.find_font_for_char(ch, font_size, &styled_font)
                } else {
                    (styled_font.clone(), false)
                };

                let grapheme = if is_keycap_sequence {
                    format!("{}\u{FE0F}\u{20E3}", ch)
                } else if next_is_vs16 {
                    format!("{}\u{FE0F}", ch)
                } else {
                    ch.to_string()
                };

                let color = Color4f::new(
                    fragment.style.color[0],
                    fragment.style.color[1],
                    fragment.style.color[2],
                    fragment.style.color[3],
                );
                let background_color = fragment.style.background_color.map(|c| {
                    Color4f::new(c[0], c[1], c[2], c[3])
                });

                let final_font = self.font_context.apply_font_attrs(&best_font, &fragment.style.font_attrs, font_size);

                glyphs.push(GlyphInfo {
                    grapheme,
                    font: final_font,
                    x,
                    color,
                    background_color,
                    width: fragment_cell_width,
                    decoration: fragment.style.decoration,
                });

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

        GlyphLayout { glyphs }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
    use sugarloaf::layout::{BuilderLine, FragmentData, FragmentStyle};

    fn create_test_shaper() -> TextShaper {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));
        TextShaper::new(font_context)
    }

    fn create_test_line(content: &str) -> BuilderLine {
        BuilderLine {
            fragments: vec![FragmentData {
                content: content.to_string(),
                style: FragmentStyle::default(),
            }],
            ..Default::default()
        }
    }

    #[test]
    fn test_shape_ascii_line() {
        let shaper = create_test_shaper();
        let line = create_test_line("Hello");

        let layout = shaper.shape_line(&line, 14.0, 8.0);

        assert_eq!(layout.glyphs.len(), 5);
        let graphemes: Vec<&str> = layout.glyphs.iter().map(|g| g.grapheme.as_str()).collect();
        assert_eq!(graphemes, vec!["H", "e", "l", "l", "o"]);
        assert_eq!(layout.glyphs[0].x, 0.0);
        assert_eq!(layout.glyphs[1].x, 8.0);
        assert_eq!(layout.glyphs[2].x, 16.0);
    }

    #[test]
    fn test_shape_mixed_line() {
        let shaper = create_test_shaper();
        let line = create_test_line("Hello世界");

        let layout = shaper.shape_line(&line, 14.0, 8.0);

        assert_eq!(layout.glyphs.len(), 7);
    }

    #[test]
    fn test_vs16_emoji_selector() {
        let shaper = create_test_shaper();
        let line = create_test_line("❤️");

        let layout = shaper.shape_line(&line, 14.0, 8.0);

        assert_eq!(layout.glyphs.len(), 1);
        assert_eq!(layout.glyphs[0].grapheme, "❤\u{FE0F}");
    }

    #[test]
    fn test_keycap_sequence() {
        let shaper = create_test_shaper();
        let line = create_test_line("1️⃣");

        let layout = shaper.shape_line(&line, 14.0, 8.0);

        assert_eq!(layout.glyphs.len(), 1);
        assert_eq!(layout.glyphs[0].grapheme, "1\u{FE0F}\u{20E3}");
    }

    #[test]
    fn test_mixed_selectors() {
        let shaper = create_test_shaper();
        // 混合：普通字符 + emoji + keycap
        let line = create_test_line("A❤️1️⃣B");

        let layout = shaper.shape_line(&line, 14.0, 8.0);

        // 验证字形（每个逻辑字符一个 glyph，完整序列存储在 grapheme 中）
        assert_eq!(layout.glyphs.len(), 4);
        let graphemes: Vec<&str> = layout.glyphs.iter().map(|g| g.grapheme.as_str()).collect();
        assert_eq!(graphemes, vec!["A", "❤\u{FE0F}", "1\u{FE0F}\u{20E3}", "B"]);

        // 验证 x 坐标连续
        assert_eq!(layout.glyphs[0].x, 0.0);
        assert_eq!(layout.glyphs[1].x, 8.0);
        assert_eq!(layout.glyphs[2].x, 16.0);
        assert_eq!(layout.glyphs[3].x, 24.0);
    }
}
