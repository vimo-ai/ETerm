//! Box-Drawing Character Detection
//!
//! 职责：检测需要拉伸填充的特殊字符（box-drawing, powerlines, brailles 等）
//!
//! 设计原则：
//! - 只做检测，不做绘制（绘制由 canvas.scale 完成）
//! - 松耦合：通过配置控制启用/禁用
//! - 参考老代码：rio/sugarloaf/src/sugarloaf/primitives.rs

/// 检测字符是否需要拉伸（box-drawing 字符）
///
/// 参考：`rio/sugarloaf/src/sugarloaf/primitives.rs:57-77`
///
/// 范围包括：
/// - Box-drawing characters (U+2500-U+257F) - 包括 │─┌┐└┘├┤┬┴┼ 等
/// - Block elements (U+2580-U+259F) - 包括 ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟
/// - Unicode Legacy Computing (U+1FB00-U+1FB3B)
/// - Powerline symbols (U+E0B0-U+E0BF) - 包括  等
/// - Braille patterns (U+2800-U+28FF) - 包括 ⠀⠁⠂⠃⠄⠅⠆⠇ 等
///
/// 返回 `true` 表示该字符需要垂直拉伸以填满整个 line_height
pub fn detect_drawable_character(ch: char) -> Option<()> {
    match ch {
        // Box-drawing characters (U+2500-U+257F)
        '\u{2500}'..='\u{257f}' |
        // Block elements (U+2580-U+259F) - ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟
        '\u{2580}'..='\u{259f}' |
        // Unicode Legacy Computing (U+1FB00-U+1FB3B)
        '\u{1fb00}'..='\u{1fb3b}' |
        // Powerline symbols (U+E0B0-U+E0BF)
        '\u{e0b0}'..='\u{e0bf}' |
        // Braille patterns (U+2800-U+28FF)
        '\u{2800}'..='\u{28FF}' => Some(()),
        _ => None,
    }
}

/// Box-drawing 字符渲染配置
#[derive(Debug, Clone)]
pub struct BoxDrawingConfig {
    /// 是否启用 box-drawing 字符拉伸渲染
    pub enabled: bool,
}

impl Default for BoxDrawingConfig {
    fn default() -> Self {
        Self {
            enabled: false,  // 调试用：暂时禁用
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_box_drawing_characters() {
        // Box-drawing 字符应该被检测（需要拉伸）
        assert!(detect_drawable_character('│').is_some(), "vertical line");
        assert!(detect_drawable_character('─').is_some(), "horizontal line");
        assert!(detect_drawable_character('┌').is_some(), "corner");
        assert!(detect_drawable_character('┘').is_some(), "corner");
    }

    #[test]
    fn test_detect_block_elements() {
        // Block 元素应该被检测（需要拉伸）
        assert!(detect_drawable_character('█').is_some(), "full block");
        assert!(detect_drawable_character('▌').is_some(), "left half");
        assert!(detect_drawable_character('▐').is_some(), "right half");
        assert!(detect_drawable_character('▀').is_some(), "top half");
        assert!(detect_drawable_character('▄').is_some(), "bottom half");
        assert!(detect_drawable_character('▛').is_some(), "quadrant");
        assert!(detect_drawable_character('▜').is_some(), "quadrant");
    }

    #[test]
    fn test_detect_non_drawable() {
        // 普通字符不应该被检测
        assert_eq!(detect_drawable_character('A'), None);
        assert_eq!(detect_drawable_character('中'), None);
        assert_eq!(detect_drawable_character('1'), None);
        assert_eq!(detect_drawable_character(' '), None);
    }

    #[test]
    fn test_powerline_symbols() {
        // Powerline 符号应该被检测
        assert!(detect_drawable_character('\u{e0b0}').is_some());
        assert!(detect_drawable_character('\u{e0b2}').is_some());
    }

    #[test]
    fn test_braille_patterns() {
        // Braille 符号应该被检测
        assert!(detect_drawable_character('\u{2800}').is_some());
        assert!(detect_drawable_character('\u{28FF}').is_some());
    }
}
