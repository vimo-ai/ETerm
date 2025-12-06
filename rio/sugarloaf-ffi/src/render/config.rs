
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use skia_safe::Color4f;
use crate::domain::primitives::{LogicalPixels, PhysicalPixels};
use rio_backend::config::colors::Colors;
use std::sync::Arc;
use super::box_drawing::BoxDrawingConfig;

/// 渲染配置（不可变值对象）
#[derive(Debug, Clone)]
pub struct RenderConfig {
    /// 字体大小（逻辑像素）
    pub font_size: LogicalPixels,
    /// 行高因子（如 1.0 = 100%，1.2 = 120%）
    pub line_height: f32,
    /// DPI 缩放（如 2.0 for Retina）
    pub scale: f32,
    /// 背景颜色（RGBA，取值范围 0.0-1.0）
    pub background_color: Color4f,
    /// 颜色配置（光标、选区、ANSI 颜色等）
    pub colors: Arc<Colors>,
    /// Box-drawing 字符渲染配置（可选，松耦合）
    pub box_drawing: BoxDrawingConfig,
}

impl RenderConfig {
    pub fn new(font_size: LogicalPixels, line_height: f32, scale: f32, colors: Arc<Colors>) -> Self {
        Self {
            font_size,
            line_height,
            scale,
            background_color: Color4f::new(0.0, 0.0, 0.0, 0.0),  // 默认透明，让窗口磨砂效果显示
            colors,
            box_drawing: BoxDrawingConfig::default(),  // 默认启用 box-drawing
        }
    }

    /// 创建带自定义背景色的配置
    pub fn with_background(
        font_size: LogicalPixels,
        line_height: f32,
        scale: f32,
        background_color: Color4f,
        colors: Arc<Colors>,
    ) -> Self {
        Self {
            font_size,
            line_height,
            scale,
            background_color,
            colors,
            box_drawing: BoxDrawingConfig::default(),  // 默认启用 box-drawing
        }
    }

    /// 创建带自定义 box-drawing 配置的配置
    pub fn with_box_drawing(mut self, box_drawing: BoxDrawingConfig) -> Self {
        self.box_drawing = box_drawing;
        self
    }

    /// 获取物理字体大小（用于 Skia）
    pub fn physical_font_size(&self) -> PhysicalPixels {
        self.font_size.to_physical(self.scale)
    }

    /// 转换物理像素为逻辑像素（辅助方法）
    pub fn to_logical(&self, physical: PhysicalPixels) -> LogicalPixels {
        physical.to_logical(self.scale)
    }

    /// 计算配置的缓存 key（用于快速判断是否需要重新计算）
    pub fn cache_key(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        // 使用 to_bits() 避免浮点数精度问题
        self.font_size.value.to_bits().hash(&mut hasher);
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
        self.font_size.value == other.font_size.value
            && self.line_height == other.line_height
            && self.scale == other.scale
            && colors_equal(self.background_color, other.background_color)
            && Arc::ptr_eq(&self.colors, &other.colors)  // 比较 Arc 指针，如果指向同一个 Colors 则相等
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

/// 字体度量信息（物理像素）
#[derive(Debug, Clone, Copy)]
pub struct FontMetrics {
    /// 单元格宽度（物理像素）
    pub cell_width: PhysicalPixels,
    /// 单元格高度（物理像素）
    pub cell_height: PhysicalPixels,
    /// 基线偏移（物理像素）
    pub baseline_offset: PhysicalPixels,
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
        let physical_font_size = config.physical_font_size();
        let primary_font = font_context.get_primary_font(physical_font_size.value);
        let (_, skia_metrics) = primary_font.metrics();

        // ===== 计算 cell_height =====
        // 🎯 关键修复：cell_height 是基础字形高度，不包含 line_height 因子
        // line_height 因子在 renderer 中单独应用（用于行间距和 box-drawing 拉伸）
        let raw_cell_height = -skia_metrics.ascent
                             + skia_metrics.descent
                             + skia_metrics.leading;
        // Round 到整数像素，避免渲染时的亚像素缝隙
        // 参考：rio/sugarloaf/src/sugarloaf.rs:419-420 (get_font_metrics_skia)
        let cell_height = raw_cell_height.round();

        // ===== 计算 cell_width =====
        let (raw_cell_width, _) = primary_font.measure_str("M", None);
        // 🎯 关键修复：Round 到整数像素，避免子像素渲染导致的字符缝隙
        let cell_width = raw_cell_width.round();

        // ===== 计算 baseline_offset（696 行）=====
        let baseline_offset = -skia_metrics.ascent;

        Self {
            cell_width: PhysicalPixels::new(cell_width),
            cell_height: PhysicalPixels::new(cell_height),
            baseline_offset: PhysicalPixels::new(baseline_offset),
            config_key: config.cache_key(),
        }
    }

    /// 转换为逻辑尺寸（常用操作）
    pub fn to_logical_size(&self, scale: f32) -> crate::domain::primitives::LogicalSize {
        use crate::domain::primitives::LogicalSize;
        LogicalSize::new(
            self.cell_width.to_logical(scale),
            self.cell_height.to_logical(scale),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_default_colors() -> Arc<Colors> {
        Arc::new(Colors::default())
    }

    #[test]
    fn test_render_config_cache_key() {
        use crate::domain::primitives::LogicalPixels;
        let colors = create_default_colors();
        let config1 = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 2.0, colors.clone());
        let config2 = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 2.0, colors.clone());
        let config3 = RenderConfig::new(LogicalPixels::new(16.0), 1.0, 2.0, colors.clone());

        // 相同配置应该有相同的 cache_key
        assert_eq!(config1.cache_key(), config2.cache_key());

        // 不同配置应该有不同的 cache_key
        assert_ne!(config1.cache_key(), config3.cache_key());
    }

    #[test]
    fn test_render_config_equality() {
        use crate::domain::primitives::LogicalPixels;
        let colors = create_default_colors();
        let config1 = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 2.0, colors.clone());
        let config2 = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 2.0, colors.clone());
        let config3 = RenderConfig::new(LogicalPixels::new(16.0), 1.0, 2.0, colors.clone());

        assert_eq!(config1, config2);
        assert_ne!(config1, config3);
    }

    #[test]
    fn test_font_metrics_compute() {
        use crate::render::font::FontContext;
        use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
        use std::sync::Arc;
        use crate::domain::primitives::LogicalPixels;

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));

        let colors = create_default_colors();
        let config = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 1.0, colors);
        let metrics = FontMetrics::compute(&config, &font_context);

        // 验证度量信息的合理性
        assert!(metrics.cell_width.value > 0.0);
        assert!(metrics.cell_height.value > 0.0);
        assert!(metrics.baseline_offset.value > 0.0);

        // 验证 config_key 正确关联
        assert_eq!(metrics.config_key, config.cache_key());
    }

    #[test]
    fn test_font_metrics_to_logical_size() {
        use crate::render::font::FontContext;
        use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
        use std::sync::Arc;
        use crate::domain::primitives::LogicalPixels;

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));

        let colors = create_default_colors();
        let config = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 2.0, colors);
        let metrics = FontMetrics::compute(&config, &font_context);
        let logical_size = metrics.to_logical_size(2.0);

        // 逻辑尺寸应该是物理尺寸的一半
        assert_eq!(logical_size.width.value, metrics.cell_width.value / 2.0);
        assert_eq!(logical_size.height.value, metrics.cell_height.value / 2.0);
    }
}
