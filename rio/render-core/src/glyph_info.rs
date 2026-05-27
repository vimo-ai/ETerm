
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
    pub fn is_emoji(&self) -> bool {
        let char_count = self.grapheme.chars().count();

        if char_count > 1 {
            return true;
        }

        if let Some(ch) = self.grapheme.chars().next() {
            return Self::is_native_emoji(ch);
        }

        false
    }

    /// 检测是否需要垂直居中的符号
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
            0x00B7 |
            0x00D7 |
            0x00F7 |
            0x2010..=0x2015 |
            0x2020..=0x2027 |
            0x2030..=0x205E |
            0x2200..=0x22FF |
            0x2300..=0x23FF |
            0x25A0..=0x25FF |
            0x2600..=0x26FF |
            0x2700..=0x27BF |
            0x2B00..=0x2BFF
        )
    }

    fn is_native_emoji(ch: char) -> bool {
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
}
