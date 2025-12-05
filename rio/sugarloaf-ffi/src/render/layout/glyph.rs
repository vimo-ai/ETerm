#[cfg(feature = "new_architecture")]
use skia_safe::{Font, Color4f};

/// 单个字形信息（渲染层数据）
#[derive(Debug, Clone)]
pub struct GlyphInfo {
    /// 原始字符
    pub ch: char,
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
}
