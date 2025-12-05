#[cfg(feature = "new_architecture")]
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use skia_safe::Color4f;

/// 渲染配置（不可变值对象）
#[derive(Debug, Clone, Copy)]
pub struct RenderConfig {
    /// 字体大小（逻辑像素）
    pub font_size: f32,
    /// 行高因子（如 1.0 = 100%，1.2 = 120%）
    pub line_height: f32,
    /// DPI 缩放（如 2.0 for Retina）
    pub scale: f32,
    /// 背景颜色（RGBA，取值范围 0.0-1.0）
    pub background_color: Color4f,
}

impl RenderConfig {
    pub fn new(font_size: f32, line_height: f32, scale: f32) -> Self {
        Self {
            font_size,
            line_height,
            scale,
            background_color: Color4f::new(0.0, 0.0, 0.0, 0.0),  // 默认透明，让窗口磨砂效果显示
        }
    }

    /// 创建带自定义背景色的配置
    pub fn with_background(
        font_size: f32,
        line_height: f32,
        scale: f32,
        background_color: Color4f,
    ) -> Self {
        Self {
            font_size,
            line_height,
            scale,
            background_color,
        }
    }

    /// 计算配置的缓存 key（用于快速判断是否需要重新计算）
    pub fn cache_key(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        // 使用 to_bits() 避免浮点数精度问题
        self.font_size.to_bits().hash(&mut hasher);
        self.line_height.to_bits().hash(&mut hasher);
        self.scale.to_bits().hash(&mut hasher);
        // 背景色也影响缓存 key
        self.background_color.r.to_bits().hash(&mut hasher);
        self.background_color.g.to_bits().hash(&mut hasher);
        self.background_color.b.to_bits().hash(&mut hasher);
        self.background_color.a.to_bits().hash(&mut hasher);
        hasher.finish()
    }
}

impl PartialEq for RenderConfig {
    fn eq(&self, other: &Self) -> bool {
        self.font_size == other.font_size
            && self.line_height == other.line_height
            && self.scale == other.scale
            && colors_equal(self.background_color, other.background_color)
    }
}

/// 比较两个 Color4f 是否相等（使用 epsilon 避免浮点数精度问题）
fn colors_equal(a: Color4f, b: Color4f) -> bool {
    const EPSILON: f32 = 1e-6;
    (a.r - b.r).abs() < EPSILON
        && (a.g - b.g).abs() < EPSILON
        && (a.b - b.b).abs() < EPSILON
        && (a.a - b.a).abs() < EPSILON
}

/// 字体度量信息（计算结果，可缓存）
#[derive(Debug, Clone, Copy)]
pub struct FontMetrics {
    /// 单元格宽度（物理像素对齐）
    pub cell_width: f32,
    /// 单元格高度（物理像素对齐）
    pub cell_height: f32,
    /// 基线偏移（从单元格顶部到基线的距离）
    pub baseline_offset: f32,
    /// 用于验证的配置 key（内部使用）
    pub config_key: u64,
}

impl FontMetrics {
    /// 从字体计算度量信息
    ///
    /// 完整复用老代码逻辑：
    /// - rio/sugarloaf/src/sugarloaf.rs:398-429 (get_font_metrics_skia)
    /// - rio/sugarloaf/src/sugarloaf.rs:686-704 (render 中的计算)
    pub fn compute(
        config: &RenderConfig,
        font_context: &crate::render::font::FontContext,
    ) -> Self {
        let font_size = config.font_size * config.scale;
        let primary_font = font_context.get_primary_font(font_size);
        let (_, skia_metrics) = primary_font.metrics();

        // ===== 计算 cell_height（693-695 行）=====
        let raw_cell_height = (-skia_metrics.ascent
                             + skia_metrics.descent
                             + skia_metrics.leading) * config.line_height;
        // 物理像素对齐，避免行间缝隙（704 行）
        let cell_height = (raw_cell_height * config.scale).round() / config.scale;

        // ===== 计算 cell_width（700-704 行）=====
        let (raw_cell_width, _) = primary_font.measure_str("M", None);
        // 物理像素对齐，避免子像素渲染导致的字符缝隙
        let cell_width = (raw_cell_width * config.scale).round() / config.scale;

        // ===== 计算 baseline_offset（696 行）=====
        let baseline_offset = -skia_metrics.ascent;

        Self {
            cell_width,
            cell_height,
            baseline_offset,
            config_key: config.cache_key(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_config_cache_key() {
        let config1 = RenderConfig::new(14.0, 1.0, 2.0);
        let config2 = RenderConfig::new(14.0, 1.0, 2.0);
        let config3 = RenderConfig::new(16.0, 1.0, 2.0);

        // 相同配置应该有相同的 cache_key
        assert_eq!(config1.cache_key(), config2.cache_key());

        // 不同配置应该有不同的 cache_key
        assert_ne!(config1.cache_key(), config3.cache_key());
    }

    #[test]
    fn test_render_config_equality() {
        let config1 = RenderConfig::new(14.0, 1.0, 2.0);
        let config2 = RenderConfig::new(14.0, 1.0, 2.0);
        let config3 = RenderConfig::new(16.0, 1.0, 2.0);

        assert_eq!(config1, config2);
        assert_ne!(config1, config3);
    }

    #[test]
    fn test_font_metrics_compute() {
        use crate::render::font::FontContext;
        use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
        use std::sync::Arc;

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));

        let config = RenderConfig::new(14.0, 1.0, 1.0);
        let metrics = FontMetrics::compute(&config, &font_context);

        // 验证度量信息的合理性
        assert!(metrics.cell_width > 0.0);
        assert!(metrics.cell_height > 0.0);
        assert!(metrics.baseline_offset > 0.0);

        // 验证 config_key 正确关联
        assert_eq!(metrics.config_key, config.cache_key());
    }

    #[test]
    fn test_font_metrics_pixel_alignment() {
        use crate::render::font::FontContext;
        use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
        use std::sync::Arc;

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));

        // 使用 scale = 2.0 测试物理像素对齐
        let config = RenderConfig::new(14.0, 1.0, 2.0);
        let metrics = FontMetrics::compute(&config, &font_context);

        // 验证物理像素对齐：(value * scale).round() / scale
        // 结果应该是可以被 0.5 整除的（对于 scale = 2.0）
        let cell_width_scaled = metrics.cell_width * config.scale;
        let cell_height_scaled = metrics.cell_height * config.scale;

        // 四舍五入后应该是整数（物理像素）
        assert_eq!(cell_width_scaled, cell_width_scaled.round());
        assert_eq!(cell_height_scaled, cell_height_scaled.round());
    }
}
