
use skia_safe::{Font, Color4f};
use sugarloaf::layout::FragmentStyleDecoration;

/// 单个字形信息（渲染层数据）
#[derive(Debug, Clone)]
pub struct GlyphInfo {
    /// 完整的 grapheme cluster（用于渲染）
    /// - 普通字符: "A", "中", "1"
    /// - VS16 emoji: "❤\u{FE0F}"
    /// - Keycap emoji: "2\u{FE0F}\u{20E3}"
    pub grapheme: String,
    /// 用于渲染此字符的字体
    pub font: Font,
    /// 字符在行内的 x 像素坐标（相对于行左上角）
    /// 注意：这是像素坐标，不是网格列号
    /// y 坐标在渲染时统一处理（所有字符在同一 baseline 上）
    pub x: f32,
    /// 前景色（字符颜色）
    pub color: Color4f,
    /// 背景色（可选，None 表示透明）
    pub background_color: Option<Color4f>,
    /// 字符宽度（单位：cell 个数）
    /// - 单宽字符（ASCII、半角）：1.0
    /// - 双宽字符（中文、全角、emoji）：2.0
    pub width: f32,
    /// 装饰（下划线、删除线）
    pub decoration: Option<FragmentStyleDecoration>,
}

impl GlyphInfo {
    /// 检测是否为需要特殊渲染的 emoji
    ///
    /// 包括：
    /// 1. 多字符序列（VS16 emoji, ZWJ 序列, keycap 等）
    /// 2. 单字符原生 emoji（🗑, ☀, ✳ 等）
    ///
    /// 这些字符需要使用 Paragraph API 渲染，而非 draw_str，
    /// 因为 draw_str 不支持彩色 emoji（COLR/sbix 格式）。
    pub fn is_emoji(&self) -> bool {
        let char_count = self.grapheme.chars().count();

        // 多字符序列：VS16 emoji, ZWJ 序列, keycap 等
        if char_count > 1 {
            return true;
        }

        // 单字符原生 emoji
        if let Some(ch) = self.grapheme.chars().next() {
            return Self::is_native_emoji(ch);
        }

        false
    }

    /// 检测是否为需要垂直居中的符号
    ///
    /// 这些符号的视觉中心不在 baseline 上，需要垂直居中渲染才能看起来对齐。
    /// 包括：数学符号、Dingbats、技术符号等。
    pub fn needs_vertical_center(&self) -> bool {
        if self.grapheme.chars().count() != 1 {
            return false;
        }

        let ch = match self.grapheme.chars().next() {
            Some(c) => c,
            None => return false,
        };

        let code = ch as u32;

        matches!(code,
            // Latin-1 Supplement 中的特殊符号
            0x00B7 |           // · Middle Dot
            0x00D7 |           // × Multiplication Sign
            0x00F7 |           // ÷ Division Sign

            // General Punctuation
            0x2010..=0x2027 |  // 各种破折号、引号
            0x2030..=0x205E |  // 千分号、点等

            // Mathematical Operators
            0x2200..=0x22FF |  // ∴ (U+2234) 等数学符号

            // Miscellaneous Technical
            0x2300..=0x23FF |  // ⏺ (U+23FA) 等技术符号

            // Geometric Shapes
            0x25A0..=0x25FF |  // ■ ● ◆ 等几何图形

            // Miscellaneous Symbols (不含 emoji)
            0x2600..=0x26FF |  // ☀ 等（文本形式）

            // Dingbats
            0x2700..=0x27BF |  // ✢ ✳ ✶ 等

            // Miscellaneous Symbols and Arrows
            0x2B00..=0x2BFF    // ⬛ ⭐ 等

            // 注意：以下范围不在这里，因为它们需要填满 cell：
            // - Box Drawing (0x2500..=0x257F) - 有专门的拉伸处理
            // - Block Elements (0x2580..=0x259F) - █ ▀ ▄ 需要填满 cell
        )
    }

    /// 检测是否为原生 emoji（Emoji_Presentation=Yes，不需要 VS16）
    ///
    /// 只包含默认以 emoji 形式显示的字符范围。
    ///
    /// 注意：Miscellaneous Symbols (0x2600-0x26FF) 和 Dingbats (0x2700-0x27BF)
    /// 中的字符（如 ☀ U+2600、✳ U+2733）默认是文本展示，需要 VS16 才变成 emoji，
    /// 所以不在这里。它们作为多字符序列（带 VS16）会在 char_count > 1 时被识别。
    fn is_native_emoji(ch: char) -> bool {
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
}
