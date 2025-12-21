//! IME View - 输入法预编辑视图
//!
//! 职责：存储 IME 预编辑状态用于渲染
//!
//! 设计原则：
//! - 简单的值对象，只存储文本和光标偏移
//! - 不存储坐标（直接在终端光标位置渲染）

/// IME 预编辑视图
///
/// 表示当前 IME 预编辑状态，用于渲染。
///
/// # 设计说明
///
/// 预编辑文本**直接在终端光标位置渲染**，具有以下特点:
/// - 显示带下划线的预编辑文本（如 "nihao"）
/// - 预编辑内光标位置高亮（表示输入焦点）
/// - 中文等宽字符占 2 个单元格宽度
///
/// # 使用场景
///
/// 1. 用户开始输入拼音，Swift 调用 setMarkedText
/// 2. Swift 调用 FFI 设置 ImeView
/// 3. 渲染器检测到 ImeView，在**光标位置**渲染预编辑文本
/// 4. 用户选择候选词，Swift 调用 commitText 并清除 ImeView
#[derive(Debug, Clone, PartialEq)]
pub struct ImeView {
    /// 预编辑文本（如 "nihao"、"你好"）
    pub text: String,

    /// 预编辑内的光标位置（字符索引，0-based）
    /// 用于显示输入焦点位置
    pub cursor_offset: usize,
}

impl ImeView {
    /// 创建新的 ImeView
    pub fn new(text: String, cursor_offset: usize) -> Self {
        Self {
            text,
            cursor_offset,
        }
    }

    /// 是否为空
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    /// 文本长度（字符数）
    pub fn len(&self) -> usize {
        self.text.chars().count()
    }

    /// 计算预编辑文本的显示宽度（单元格数）
    ///
    /// 中文等宽字符占 2 个单元格，ASCII 字符占 1 个单元格
    pub fn display_width(&self) -> usize {
        self.text
            .chars()
            .map(|c| char_width(c))
            .sum()
    }

    /// 计算预编辑内光标的显示位置（单元格数）
    pub fn cursor_display_offset(&self) -> usize {
        self.text
            .chars()
            .take(self.cursor_offset)
            .map(|c| char_width(c))
            .sum()
    }
}

/// 计算字符的显示宽度
///
/// 使用简化规则：
/// - ASCII 字符占 1 个单元格
/// - 宽字符（CJK、emoji 等）占 2 个单元格
#[inline]
fn char_width(c: char) -> usize {
    if c.is_ascii() {
        1
    } else if is_wide_char(c) {
        2
    } else {
        1
    }
}

/// 判断是否为宽字符
fn is_wide_char(c: char) -> bool {
    let cp = c as u32;
    // CJK Unified Ideographs
    (0x4E00..=0x9FFF).contains(&cp)
        // CJK Extension A
        || (0x3400..=0x4DBF).contains(&cp)
        // CJK Extension B-G
        || (0x20000..=0x3134F).contains(&cp)
        // CJK Compatibility Ideographs
        || (0xF900..=0xFAFF).contains(&cp)
        // Halfwidth and Fullwidth Forms (fullwidth part)
        || (0xFF00..=0xFF60).contains(&cp)
        || (0xFFE0..=0xFFE6).contains(&cp)
        // Hangul Syllables
        || (0xAC00..=0xD7AF).contains(&cp)
        // Hiragana, Katakana
        || (0x3040..=0x30FF).contains(&cp)
        // Emoji (common ranges)
        || (0x1F300..=0x1F9FF).contains(&cp)
        || (0x2600..=0x26FF).contains(&cp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ime_view_creation() {
        let ime = ImeView::new("nihao".to_string(), 2);
        assert_eq!(ime.text, "nihao");
        assert_eq!(ime.cursor_offset, 2);
        assert!(!ime.is_empty());
        assert_eq!(ime.len(), 5);
    }

    #[test]
    fn test_display_width_ascii() {
        let ime = ImeView::new("hello".to_string(), 0);
        assert_eq!(ime.display_width(), 5);
    }

    #[test]
    fn test_display_width_cjk() {
        let ime = ImeView::new("你好".to_string(), 0);
        assert_eq!(ime.display_width(), 4); // 2 chars * 2 width
    }

    #[test]
    fn test_display_width_mixed() {
        let ime = ImeView::new("你好world".to_string(), 0);
        assert_eq!(ime.display_width(), 9); // 2*2 + 5
    }

    #[test]
    fn test_cursor_display_offset() {
        // ASCII only
        let ime = ImeView::new("hello".to_string(), 2);
        assert_eq!(ime.cursor_display_offset(), 2);

        // CJK: cursor after first char
        let ime_cjk = ImeView::new("你好".to_string(), 1);
        assert_eq!(ime_cjk.cursor_display_offset(), 2); // "你" = 2 width

        // Mixed: cursor after "你好"
        let ime_mixed = ImeView::new("你好world".to_string(), 2);
        assert_eq!(ime_mixed.cursor_display_offset(), 4); // "你好" = 4 width
    }
}
