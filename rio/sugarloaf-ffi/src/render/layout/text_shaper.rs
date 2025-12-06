#[cfg(feature = "new_architecture")]
use super::GlyphInfo;
use crate::render::font::FontContext;
use crate::render::cache::GlyphLayout;
use crate::domain::state::TerminalState;
use sugarloaf::layout::BuilderLine;
use skia_safe::{Font, Color4f};
use std::sync::Arc;

/// 文本整形器（Text Shaper）
/// 复用老代码的 generate_line_layout 逻辑（1364-1441 行）
pub struct TextShaper {
    font_context: Arc<FontContext>,
}

impl TextShaper {
    pub fn new(font_context: Arc<FontContext>) -> Self {
        Self { font_context }
    }

    /// 为一行生成字形布局
    ///
    /// 完整复用老代码逻辑：
    /// - VS16/VS15/Keycap sequence 处理（1392-1399 行）
    /// - 字体选择优先级（1401-1416 行）
    /// - 索引增量（1424-1430 行）
    pub fn shape_line(
        &self,
        line: &BuilderLine,
        font_size: f32,
        cell_width: f32,
        _line_number: usize,
        _state: &TerminalState,
    ) -> GlyphLayout {
        let mut glyphs = Vec::new();
        let mut x = 0.0;

        for fragment in &line.fragments {
            // 1. 获取 fragment 的样式字体（基于 fragment.style.font_id）
            let styled_typeface = self.font_context.get_typeface_for_font_id(fragment.style.font_id);
            let styled_font = styled_typeface
                .as_ref()
                .map(|tf| Font::from_typeface(tf, font_size))
                .unwrap_or_else(|| self.font_context.get_primary_font(font_size));

            let fragment_cell_width = fragment.style.width;
            let chars_vec: Vec<char> = fragment.content.chars().collect();
            let mut i = 0;

            // 2. 遍历字符（完整复用 1389-1431 行逻辑）
            while i < chars_vec.len() {
                let ch = chars_vec[i];

                // ===== VS16/VS15/Keycap 检测（1392-1394 行）=====
                let next_is_vs16 = chars_vec.get(i + 1) == Some(&'\u{FE0F}');
                let next_is_vs15 = chars_vec.get(i + 1) == Some(&'\u{FE0E}');
                let is_keycap_sequence = next_is_vs16 && chars_vec.get(i + 2) == Some(&'\u{20E3}');

                // ===== 跳过 selector 本身（1396-1399 行）=====
                if ch == '\u{FE0F}' || ch == '\u{FE0E}' || ch == '\u{20E3}' {
                    i += 1;
                    continue;
                }

                // ===== 字体选择优先级（1401-1416 行）=====
                let (best_font, _is_emoji) = if is_keycap_sequence || next_is_vs16 {
                    // 优先级 1: Keycap/VS16 → 强制使用 emoji 字体
                    if let Some(emoji_font) = self.font_context.find_emoji_font(ch, font_size) {
                        (emoji_font, true)
                    } else {
                        self.font_context.find_font_for_char(ch, font_size, &styled_font)
                    }
                } else if (ch as u32) >= 0x80 {
                    // 优先级 2: 非 ASCII → 使用 fallback 查找
                    self.font_context.find_font_for_char(ch, font_size, &styled_font)
                } else {
                    // 优先级 3: ASCII → 直接使用 styled_font
                    (styled_font.clone(), false)
                };

                // ===== 记录字形（1418-1422 行）=====
                // 从 fragment.style 获取颜色
                let color = Color4f::new(
                    fragment.style.color[0],
                    fragment.style.color[1],
                    fragment.style.color[2],
                    fragment.style.color[3],
                );
                let background_color = fragment.style.background_color.map(|c| {
                    Color4f::new(c[0], c[1], c[2], c[3])
                });

                // ===== 根据 font_attrs 选择正确的字体变体 =====
                let final_font = self.font_context.apply_font_attrs(&best_font, &fragment.style.font_attrs, font_size);

                glyphs.push(GlyphInfo {
                    ch,
                    font: final_font,
                    x,
                    color,
                    background_color,
                    width: fragment_cell_width,
                    decoration: fragment.style.decoration,  // 传递装饰信息
                });

                x += cell_width * fragment_cell_width;

                // ===== 索引增量（1424-1430 行）=====
                if is_keycap_sequence {
                    i += 3;  // 跳过 ch + VS16 + keycap
                } else if next_is_vs16 || next_is_vs15 {
                    i += 2;  // 跳过 ch + selector
                } else {
                    i += 1;  // 普通字符
                }
            }
        }

        // 注意：光标/选区/搜索等状态信息不在这里计算
        // 它们在 Renderer.render_with_layout() 时从 TerminalState 动态获取

        GlyphLayout {
            glyphs,
            content_hash: 0,  // TODO: 计算实际 hash
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
    use sugarloaf::layout::BuilderLine;

    fn create_test_shaper() -> TextShaper {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));
        TextShaper::new(font_context)
    }

    fn create_test_line(_content: &str) -> BuilderLine {
        // TODO: 因为 FragmentData 不是公开类型，暂时跳过测试
        // 等 Step 1.4 实现 TerminalState -> BuilderLine 转换时，使用真实数据
        BuilderLine::default()
    }

    // 创建测试用的 TerminalState（光标在指定位置）
    // 注意：这是 mock 函数，仅用于被 #[ignore] 的测试
    #[allow(dead_code)]
    fn create_test_state(_cursor_line: usize, _cursor_col: usize) -> TerminalState {
        // 需要真实的 GridData 构造方法
        unimplemented!("create_test_state requires real GridData construction")
    }

    #[test]
    #[ignore] // TODO: Step 1.4 移除 - FragmentData 不是公开类型，无法创建测试数据
    fn test_shape_ascii_line() {
        let shaper = create_test_shaper();
        let line = create_test_line("Hello");

        // 创建测试用的 TerminalState（光标不在第 0 行）
        let state = create_test_state(5, 10);

        let layout = shaper.shape_line(&line, 14.0, 8.0, 0, &state);

        // 验证字形数量
        assert_eq!(layout.glyphs.len(), 5);

        // 验证字符
        let chars: Vec<char> = layout.glyphs.iter().map(|g| g.ch).collect();
        assert_eq!(chars, vec!['H', 'e', 'l', 'l', 'o']);

        // 验证 x 坐标（等宽布局）
        assert_eq!(layout.glyphs[0].x, 0.0);
        assert_eq!(layout.glyphs[1].x, 8.0);
        assert_eq!(layout.glyphs[2].x, 16.0);

        // 注意：cursor_info 已从 GlyphLayout 移除
        // 光标信息在 render_with_layout 时从 state 动态计算
    }

    #[test]
    #[ignore] // TODO: Step 1.4 移除 - FragmentData 不是公开类型，无法创建测试数据
    fn test_shape_mixed_line() {
        let shaper = create_test_shaper();
        let line = create_test_line("Hello世界");

        let state = create_test_state(5, 10);

        let layout = shaper.shape_line(&line, 14.0, 8.0, 0, &state);

        // 验证字形数量
        assert_eq!(layout.glyphs.len(), 7);

        // 验证字符
        let chars: Vec<char> = layout.glyphs.iter().map(|g| g.ch).collect();
        assert_eq!(chars, vec!['H', 'e', 'l', 'l', 'o', '世', '界']);
    }

    #[test]
    #[ignore] // TODO: Step 1.4 移除 - FragmentData 不是公开类型，无法创建测试数据
    fn test_vs16_emoji_selector() {
        let shaper = create_test_shaper();
        // ❤️ = ❤ (U+2764) + VS16 (U+FE0F)
        let line = create_test_line("❤️");

        let state = create_test_state(5, 10);

        let layout = shaper.shape_line(&line, 14.0, 8.0, 0, &state);

        // 验证只有一个字形（VS16 被跳过）
        assert_eq!(layout.glyphs.len(), 1);
        assert_eq!(layout.glyphs[0].ch, '❤');
    }

    #[test]
    #[ignore] // TODO: Step 1.4 移除 - FragmentData 不是公开类型，无法创建测试数据
    fn test_keycap_sequence() {
        let shaper = create_test_shaper();
        // 1️⃣ = 1 (U+0031) + VS16 (U+FE0F) + Keycap (U+20E3)
        let line = create_test_line("1️⃣");

        let state = create_test_state(5, 10);

        let layout = shaper.shape_line(&line, 14.0, 8.0, 0, &state);

        // 验证只有一个字形（VS16 和 Keycap 被跳过）
        assert_eq!(layout.glyphs.len(), 1);
        assert_eq!(layout.glyphs[0].ch, '1');
    }

    #[test]
    #[ignore] // TODO: Step 1.4 移除 - FragmentData 不是公开类型，无法创建测试数据
    fn test_mixed_selectors() {
        let shaper = create_test_shaper();
        // 混合：普通字符 + emoji + keycap
        let line = create_test_line("A❤️1️⃣B");

        let state = create_test_state(5, 10);

        let layout = shaper.shape_line(&line, 14.0, 8.0, 0, &state);

        // 验证字形（selector 被跳过）
        let chars: Vec<char> = layout.glyphs.iter().map(|g| g.ch).collect();
        assert_eq!(chars, vec!['A', '❤', '1', 'B']);

        // 验证 x 坐标连续
        assert_eq!(layout.glyphs[0].x, 0.0);
        assert_eq!(layout.glyphs[1].x, 8.0);
        assert_eq!(layout.glyphs[2].x, 16.0);
        assert_eq!(layout.glyphs[3].x, 24.0);
    }
}
