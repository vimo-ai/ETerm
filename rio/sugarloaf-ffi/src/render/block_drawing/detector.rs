//! Block Character Detection
//!
//! 检测需要自定义绘制的特殊字符类型。

/// Block 字符类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockCharType {
    /// Block Elements (U+2580-U+259F) - 方块填充字符
    BlockElement,
    /// Box Drawing (U+2500-U+257F) - 线条绘制字符
    BoxDrawing,
    /// Shade characters (░▒▓) - 阴影字符（属于 Block Elements）
    Shade,
    /// Legacy Computing (U+1FB00-U+1FB3B)
    LegacyComputing,
    /// Powerline symbols (U+E0B0-U+E0BF)
    Powerline,
    /// Braille patterns (U+2800-U+28FF)
    Braille,
}

/// 检测字符是否是 Block Element (U+2580-U+259F)
///
/// 包括：
/// - 垂直分割: ▀▁▂▃▄▅▆▇█
/// - 水平分割: ▉▊▋▌▍▎▏▐
/// - 阴影: ░▒▓
/// - 上/右条: ▔▕
/// - 象限: ▖▗▘▙▚▛▜▝▞▟
#[inline]
pub fn is_block_element(ch: char) -> bool {
    matches!(ch, '\u{2580}'..='\u{259F}')
}

/// 检测字符是否是 Box Drawing (U+2500-U+257F)
///
/// 包括：
/// - 水平/垂直线: ─│
/// - 角落: ┌┐└┘
/// - 交叉: ├┤┬┴┼
/// - 双线变体: ═║╔╗╚╝
#[inline]
pub fn is_box_drawing(ch: char) -> bool {
    matches!(ch, '\u{2500}'..='\u{257F}')
}

/// 检测字符是否是阴影字符 (░▒▓)
#[inline]
pub fn is_shade(ch: char) -> bool {
    matches!(ch, '░' | '▒' | '▓')
}

/// 检测字符是否需要自定义绘制，返回字符类型
///
/// 优先级：Block Elements > Box Drawing > 其他
#[inline]
pub fn detect_block_char_type(ch: char) -> Option<BlockCharType> {
    match ch {
        // Block Elements (包含 Shade)
        '\u{2580}'..='\u{259F}' => {
            if is_shade(ch) {
                Some(BlockCharType::Shade)
            } else {
                Some(BlockCharType::BlockElement)
            }
        }
        // Box Drawing
        '\u{2500}'..='\u{257F}' => Some(BlockCharType::BoxDrawing),
        // Legacy Computing
        '\u{1FB00}'..='\u{1FB3B}' => Some(BlockCharType::LegacyComputing),
        // Powerline
        '\u{E0B0}'..='\u{E0BF}' => Some(BlockCharType::Powerline),
        // Braille
        '\u{2800}'..='\u{28FF}' => Some(BlockCharType::Braille),
        _ => None,
    }
}

/// 检测字符是否需要自定义绘制（简化版本）
///
/// 目前只支持 Block Elements，后续可扩展 Box Drawing
#[inline]
pub fn is_drawable_block_char(ch: char) -> bool {
    is_block_element(ch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_block_elements() {
        // 全填充
        assert!(is_block_element('█'));

        // 垂直分割
        assert!(is_block_element('▀')); // upper half
        assert!(is_block_element('▄')); // lower half
        assert!(is_block_element('▁')); // lower 1/8
        assert!(is_block_element('▇')); // lower 7/8

        // 水平分割
        assert!(is_block_element('▌')); // left half
        assert!(is_block_element('▐')); // right half
        assert!(is_block_element('▎')); // left 1/4
        assert!(is_block_element('▊')); // left 3/4

        // 阴影
        assert!(is_block_element('░'));
        assert!(is_block_element('▒'));
        assert!(is_block_element('▓'));

        // 象限
        assert!(is_block_element('▛'));
        assert!(is_block_element('▜'));
        assert!(is_block_element('▟'));
        assert!(is_block_element('▙'));
    }

    #[test]
    fn test_box_drawing() {
        assert!(is_box_drawing('─'));
        assert!(is_box_drawing('│'));
        assert!(is_box_drawing('┌'));
        assert!(is_box_drawing('┘'));
        assert!(is_box_drawing('├'));
        assert!(is_box_drawing('┼'));
        assert!(is_box_drawing('═'));
        assert!(is_box_drawing('║'));
    }

    #[test]
    fn test_not_block_chars() {
        assert!(!is_block_element('A'));
        assert!(!is_block_element('中'));
        assert!(!is_block_element(' '));
        assert!(!is_block_element('1'));

        assert!(!is_box_drawing('A'));
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
