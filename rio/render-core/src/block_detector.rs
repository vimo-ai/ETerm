//! Block Character Detection

/// Block 字符类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockCharType {
    BlockElement,
    BoxDrawing,
    Shade,
    LegacyComputing,
    Powerline,
    Braille,
}

#[inline]
pub fn is_block_element(ch: char) -> bool {
    matches!(ch, '\u{2580}'..='\u{259F}')
}

#[inline]
pub fn is_box_drawing(ch: char) -> bool {
    matches!(ch, '\u{2500}'..='\u{257F}')
}

#[inline]
pub fn is_shade(ch: char) -> bool {
    matches!(ch, '░' | '▒' | '▓')
}

#[inline]
pub fn detect_block_char_type(ch: char) -> Option<BlockCharType> {
    match ch {
        '\u{2580}'..='\u{259F}' => {
            if is_shade(ch) {
                Some(BlockCharType::Shade)
            } else {
                Some(BlockCharType::BlockElement)
            }
        }
        '\u{2500}'..='\u{257F}' => Some(BlockCharType::BoxDrawing),
        '\u{1FB00}'..='\u{1FB3B}' => Some(BlockCharType::LegacyComputing),
        '\u{E0B0}'..='\u{E0BF}' => Some(BlockCharType::Powerline),
        '\u{2800}'..='\u{28FF}' => Some(BlockCharType::Braille),
        _ => None,
    }
}

#[inline]
pub fn is_drawable_block_char(ch: char) -> bool {
    is_block_element(ch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_block_elements() {
        assert!(is_block_element('█'));
        assert!(is_block_element('▀'));
        assert!(is_block_element('▄'));
        assert!(is_block_element('░'));
        assert!(is_block_element('▛'));
    }

    #[test]
    fn test_box_drawing() {
        assert!(is_box_drawing('─'));
        assert!(is_box_drawing('│'));
        assert!(is_box_drawing('┌'));
        assert!(is_box_drawing('═'));
    }

    #[test]
    fn test_not_block_chars() {
        assert!(!is_block_element('A'));
        assert!(!is_box_drawing('█'));
    }

    #[test]
    fn test_detect_type() {
        assert_eq!(detect_block_char_type('█'), Some(BlockCharType::BlockElement));
        assert_eq!(detect_block_char_type('░'), Some(BlockCharType::Shade));
        assert_eq!(detect_block_char_type('─'), Some(BlockCharType::BoxDrawing));
        assert_eq!(detect_block_char_type('A'), None);
    }

    #[test]
    fn test_shade_detection() {
        assert!(is_shade('░'));
        assert!(is_shade('▒'));
        assert!(is_shade('▓'));
        assert!(!is_shade('█'));
        assert!(!is_shade('▀'));
    }
}
