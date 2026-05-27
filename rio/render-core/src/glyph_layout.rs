use crate::glyph_info::GlyphInfo;

/// 字形布局（一行的完整渲染数据）
///
/// 只包含字体选择结果，不包含状态信息（光标、选区、搜索）。
/// 状态信息在渲染时由各平台从自己的终端状态动态获取。
#[derive(Debug, Clone)]
pub struct GlyphLayout {
    pub glyphs: Vec<GlyphInfo>,
}
