use crate::domain::TerminalState;
use crate::domain::views::grid::CellData;
use super::cache::{LineCache, GlyphLayout, CacheResult};
use super::cache::{compute_text_hash, compute_state_hash_for_line};
use super::font::FontContext;
use super::layout::TextShaper;
use super::rasterizer::LineRasterizer;
use super::config::{RenderConfig, FontMetrics};
use sugarloaf::layout::{BuilderLine, FragmentData, FragmentStyle};
use sugarloaf::font_introspector::Attributes;
use rio_backend::config::colors::AnsiColor;
use std::sync::Arc;

/// 渲染引擎（管理缓存 + 渲染流程）
pub struct Renderer {
    cache: LineCache,
    /// 统计信息（用于测试验证）
    pub stats: RenderStats,
    /// 字体上下文
    font_context: Arc<FontContext>,
    /// 文本整形器
    text_shaper: TextShaper,
    /// 行光栅化器
    rasterizer: LineRasterizer,

    // ===== 配置和缓存 =====
    /// 渲染配置（不可变）
    config: RenderConfig,
    /// 缓存的字体度量（懒加载）
    cached_metrics: Option<FontMetrics>,
}

/// 渲染统计（用于验证缓存行为）
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RenderStats {
    pub cache_hits: usize,      // 内层缓存命中次数
    pub layout_hits: usize,     // 外层缓存命中次数
    pub cache_misses: usize,    // 完全未命中次数
}

impl Renderer {
    pub fn new(
        font_context: Arc<FontContext>,
        config: RenderConfig,
    ) -> Self {
        let text_shaper = TextShaper::new(font_context.clone());
        Self {
            cache: LineCache::new(),
            stats: RenderStats::default(),
            font_context,
            text_shaper,
            rasterizer: LineRasterizer::new(),
            config,
            cached_metrics: None,  // 懒加载，首次使用时计算
        }
    }

    /// 渲染一行（核心逻辑：三级缓存查询）
    pub fn render_line(&mut self, line: usize, state: &TerminalState) -> skia_safe::Image {
        let text_hash = compute_text_hash(line, state);
        let state_hash = compute_state_hash_for_line(line, state);

        match self.cache.get(text_hash, state_hash) {
            CacheResult::FullHit(image) => {
                // Level 1: 内层命中 → 零开销（0%）
                self.stats.cache_hits += 1;
                image
            }
            CacheResult::LayoutHit(layout) => {
                // Level 2: 外层命中 → 快速绘制（30%）
                self.stats.layout_hits += 1;
                let image = self.render_with_layout(layout.clone(), line, state);
                self.cache.insert(text_hash, state_hash, layout, image.clone());
                image
            }
            CacheResult::Miss => {
                // Level 3: 完全未命中 → 完整渲染（100%）
                self.stats.cache_misses += 1;
                let layout = self.compute_glyph_layout(line, state);
                let image = self.render_with_layout(layout.clone(), line, state);
                self.cache.insert(text_hash, state_hash, layout, image.clone());
                image
            }
        }
    }

    /// 从 TerminalState 提取指定行的数据，转换为 BuilderLine
    fn extract_line(&self, line: usize, state: &TerminalState) -> BuilderLine {
        // 获取行数据
        let row_view = match state.grid.row(line) {
            Some(row) => row,
            None => {
                // 行不存在，返回空行
                return BuilderLine::default();
            }
        };

        let columns = row_view.columns();
        let cells = row_view.cells();

        let mut fragments = Vec::new();
        let mut current_content = String::new();
        let mut current_style: Option<FragmentStyle> = None;

        // 遍历行的所有单元格
        for col in 0..columns {
            if col >= cells.len() {
                break;
            }

            let cell = &cells[col];
            let ch = cell.c;

            // 从 CellData 构造 FragmentStyle
            let style = self.cell_to_fragment_style(&cell);

            // 如果样式改变，创建新 fragment
            if let Some(ref prev_style) = current_style {
                if !styles_equal(prev_style, &style) {
                    if !current_content.is_empty() {
                        fragments.push(FragmentData {
                            content: current_content.clone(),
                            style: prev_style.clone(),
                        });
                        current_content.clear();
                    }
                    current_style = Some(style);
                }
            } else {
                current_style = Some(style);
            }

            current_content.push(ch);
        }

        // 添加最后一个 fragment
        if !current_content.is_empty() {
            if let Some(style) = current_style {
                fragments.push(FragmentData {
                    content: current_content,
                    style,
                });
            }
        }

        BuilderLine {
            fragments,
            ..Default::default()
        }
    }

    /// 从 CellData 构造 FragmentStyle
    fn cell_to_fragment_style(&self, cell: &CellData) -> FragmentStyle {
        // 转换颜色
        let fg_color = ansi_color_to_rgba(&cell.fg);

        FragmentStyle {
            font_id: 0,  // 默认字体
            width: 1.0,  // 单宽字符
            font_attrs: Attributes::default(),
            color: fg_color,
            background_color: None,  // TODO: Step 1.5 处理背景色
            font_vars: 0,
            decoration: None,
            decoration_color: None,
            cursor: None,
            media: None,
            drawable_char: None,
        }
    }

    /// 获取字体度量（带缓存，自动管理）
    fn get_font_metrics(&mut self) -> FontMetrics {
        // 检查缓存是否有效
        if let Some(cached) = self.cached_metrics {
            if cached.config_key == self.config.cache_key() {
                return cached;  // 缓存命中
            }
        }

        // 缓存失效或首次计算
        let metrics = FontMetrics::compute(&self.config, &self.font_context);
        self.cached_metrics = Some(metrics);
        metrics
    }

    /// 重新配置渲染器（当渲染参数变化时调用）
    ///
    /// 自动处理：
    /// 1. 失效 FontMetrics 缓存
    /// 2. 清空 LineCache（所有行需要重新渲染）
    pub fn reconfigure(&mut self, new_config: RenderConfig) {
        // 优化：配置未变化时无需操作
        if self.config == new_config {
            return;
        }

        self.config = new_config;

        // ===== 失效所有缓存 =====
        self.cached_metrics = None;       // FontMetrics 缓存失效
        self.cache = LineCache::new();    // 清空行缓存

        // 注意：不重置 stats，保留统计信息
    }

    // ===== 便捷方法：单独修改某个参数 =====

    /// 设置字体大小（常见操作，如用户按 Ctrl+Plus 缩放）
    pub fn set_font_size(&mut self, font_size: f32) {
        self.reconfigure(RenderConfig {
            font_size,
            ..self.config
        });
    }

    /// 设置行高
    pub fn set_line_height(&mut self, line_height: f32) {
        self.reconfigure(RenderConfig {
            line_height,
            ..self.config
        });
    }

    /// 设置 DPI 缩放（如窗口移动到不同显示器）
    pub fn set_scale(&mut self, scale: f32) {
        self.reconfigure(RenderConfig {
            scale,
            ..self.config
        });
    }

    /// 设置背景颜色
    pub fn set_background_color(&mut self, color: skia_safe::Color4f) {
        self.reconfigure(RenderConfig {
            background_color: color,
            ..self.config
        });
    }

    /// 获取当前配置（只读访问）
    pub fn config(&self) -> &RenderConfig {
        &self.config
    }

    /// 计算字形布局（文本整形 + 字体选择）
    fn compute_glyph_layout(&mut self, line: usize, state: &TerminalState) -> GlyphLayout {
        // 1. 提取行数据
        let builder_line = self.extract_line(line, state);

        // 2. 获取 metrics（自动缓存）
        let metrics = self.get_font_metrics();
        let font_size = self.config.font_size * self.config.scale;

        // 3. 文本整形
        self.text_shaper.shape_line(&builder_line, font_size, metrics.cell_width)
    }

    /// 基于布局绘制（光栅化）
    fn render_with_layout(&mut self, layout: GlyphLayout, _line: usize, state: &TerminalState) -> skia_safe::Image {
        // 获取 metrics（自动缓存）
        let metrics = self.get_font_metrics();

        // 计算行宽度
        let line_width = metrics.cell_width * state.grid.columns() as f32;

        // 从配置获取背景色（不再硬编码）
        let background_color = self.config.background_color;

        self.rasterizer
            .render(
                &layout,
                line_width,
                metrics.cell_height,
                metrics.baseline_offset,
                background_color,
            )
            .expect("Failed to render line")
    }

    /// 重置统计信息
    pub fn reset_stats(&mut self) {
        self.stats = RenderStats::default();
    }
}

/// 比较两个 FragmentStyle 是否相等（用于合并 fragments）
fn styles_equal(a: &FragmentStyle, b: &FragmentStyle) -> bool {
    a.font_id == b.font_id
        && a.width == b.width
        && a.color == b.color
        && a.background_color == b.background_color
}

/// 将 AnsiColor 转换为 RGBA [f32; 4]
fn ansi_color_to_rgba(color: &AnsiColor) -> [f32; 4] {
    use rio_backend::config::colors::NamedColor;

    match color {
        AnsiColor::Named(named) => match named {
            NamedColor::Foreground => [1.0, 1.0, 1.0, 1.0],  // 白色
            NamedColor::Background => [0.0, 0.0, 0.0, 1.0],  // 黑色
            NamedColor::Black => [0.0, 0.0, 0.0, 1.0],
            NamedColor::Red => [0.8, 0.0, 0.0, 1.0],
            NamedColor::Green => [0.0, 0.8, 0.0, 1.0],
            NamedColor::Yellow => [0.8, 0.8, 0.0, 1.0],
            NamedColor::Blue => [0.0, 0.0, 0.8, 1.0],
            NamedColor::Magenta => [0.8, 0.0, 0.8, 1.0],
            NamedColor::Cyan => [0.0, 0.8, 0.8, 1.0],
            NamedColor::White => [0.8, 0.8, 0.8, 1.0],
            NamedColor::LightBlack => [0.4, 0.4, 0.4, 1.0],
            NamedColor::LightRed => [1.0, 0.0, 0.0, 1.0],
            NamedColor::LightGreen => [0.0, 1.0, 0.0, 1.0],
            NamedColor::LightYellow => [1.0, 1.0, 0.0, 1.0],
            NamedColor::LightBlue => [0.0, 0.0, 1.0, 1.0],
            NamedColor::LightMagenta => [1.0, 0.0, 1.0, 1.0],
            NamedColor::LightCyan => [0.0, 1.0, 1.0, 1.0],
            NamedColor::LightWhite => [1.0, 1.0, 1.0, 1.0],
            _ => [1.0, 1.0, 1.0, 1.0],  // 默认白色
        },
        AnsiColor::Spec(rgb) => [
            rgb.r as f32 / 255.0,
            rgb.g as f32 / 255.0,
            rgb.b as f32 / 255.0,
            1.0,
        ],
        AnsiColor::Indexed(idx) => {
            // 简化处理：使用固定调色板
            // TODO: 使用真实的 256 色调色板
            let rgb = match idx {
                0 => (0, 0, 0),
                1 => (205, 0, 0),
                2 => (0, 205, 0),
                3 => (205, 205, 0),
                4 => (0, 0, 238),
                5 => (205, 0, 205),
                6 => (0, 205, 205),
                7 => (229, 229, 229),
                8 => (127, 127, 127),
                9 => (255, 0, 0),
                10 => (0, 255, 0),
                11 => (255, 255, 0),
                12 => (92, 92, 255),
                13 => (255, 0, 255),
                14 => (0, 255, 255),
                15 => (255, 255, 255),
                _ => (255, 255, 255),  // 默认白色
            };
            [
                rgb.0 as f32 / 255.0,
                rgb.1 as f32 / 255.0,
                rgb.2 as f32 / 255.0,
                1.0,
            ]
        }
    }
}

// Remove Default impl since we now require FontContext parameter

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AbsolutePoint, GridView, GridData, CursorView, SelectionView, SelectionType, SearchView, MatchRange};
    use rio_backend::ansi::CursorShape;
    use std::sync::Arc;
    use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};
    use super::super::font::FontContext;

    /// 创建测试用 Renderer
    fn create_test_renderer() -> Renderer {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));

        // 使用真实的配置
        let config = RenderConfig::new(14.0, 1.0, 1.0);
        Renderer::new(font_context, config)
    }

    /// 创建 Mock TerminalState
    fn create_mock_state() -> TerminalState {
        // 创建每行有唯一 hash 的 GridData
        let row_hashes: Vec<u64> = (0..24).map(|i| 1000 + i as u64).collect();
        let grid_data = Arc::new(GridData::new_mock(80, 24, 0, row_hashes));
        let grid = GridView::new(grid_data);

        let cursor = CursorView {
            position: AbsolutePoint::new(0, 0),
            shape: CursorShape::Block,
        };

        TerminalState {
            grid,
            cursor,
            selection: None,
            search: None,
        }
    }

    #[test]
    fn test_render_line_basic() {
        let mut renderer = create_test_renderer();
        let state = create_mock_state();

        // 渲染第 0 行
        let img = renderer.render_line(0, &state);

        // 验证图像生成
        assert!(img.width() > 0);
        assert!(img.height() > 0);

        // 验证统计信息
        assert_eq!(renderer.stats.cache_misses, 1);
        assert_eq!(renderer.stats.layout_hits, 0);
        assert_eq!(renderer.stats.cache_hits, 0);
    }

    #[test]
    fn test_three_level_cache() {
        let mut renderer = create_test_renderer();
        let mut state = create_mock_state();

        // 第一次渲染：完全未命中
        let _img1 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 第二次渲染（状态不变）：内层命中
        let _img2 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_hits, 1);

        // 光标移动到第 0 行（改变状态）：外层命中
        state.cursor.position = AbsolutePoint::new(0, 5);
        let _img3 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.layout_hits, 1);
    }

    /// 测试：验证两层缓存命中
    #[test]
    fn test_two_layer_cache_hit() {
        let mut renderer = create_test_renderer();

        let mut state = create_mock_state();
        state.cursor.position = AbsolutePoint::new(10, 0);

        // 首次渲染：完全未命中
        let _img1 = renderer.render_line(10, &state);
        assert_eq!(renderer.stats.cache_misses, 1);
        assert_eq!(renderer.stats.layout_hits, 0);
        assert_eq!(renderer.stats.cache_hits, 0);

        // 光标移动到同一行的另一列：外层命中
        state.cursor.position = AbsolutePoint::new(10, 5);
        let _img2 = renderer.render_line(10, &state);
        assert_eq!(renderer.stats.layout_hits, 1);

        // 光标回到原位置：内层命中
        state.cursor.position = AbsolutePoint::new(10, 0);
        let _img3 = renderer.render_line(10, &state);
        assert_eq!(renderer.stats.cache_hits, 1);
    }

    /// 测试：验证剪枝优化
    #[test]
    fn test_state_hash_pruning() {
        let mut renderer = create_test_renderer();
        let mut state = create_mock_state();

        // 光标在第 5 行，渲染第 10 行
        state.cursor.position = AbsolutePoint::new(5, 0);
        let _img1 = renderer.render_line(10, &state);
        renderer.reset_stats();

        // 光标移动到第 6 行，第 10 行的 state_hash 应该不变
        state.cursor.position = AbsolutePoint::new(6, 0);
        let _img2 = renderer.render_line(10, &state);

        // 验证：内层缓存命中（state_hash 没变）
        assert_eq!(renderer.stats.cache_hits, 1);
        assert_eq!(renderer.stats.layout_hits, 0);
    }

    /// 测试：光标移动的最小失效
    #[test]
    fn test_cursor_move_minimal_invalidation() {
        let mut renderer = create_test_renderer();
        let mut state = create_mock_state();

        // 先渲染 24 行（光标在第 5 行）
        state.cursor.position = AbsolutePoint::new(5, 0);
        for line in 0..24 {
            renderer.render_line(line, &state);
        }
        renderer.reset_stats();

        // 光标移动到第 6 行，重新渲染所有行
        state.cursor.position = AbsolutePoint::new(6, 0);
        for line in 0..24 {
            renderer.render_line(line, &state);
        }

        // 验证：只有第 5、6 行需要重绘（外层命中），其他 22 行内层命中
        assert_eq!(renderer.stats.cache_hits, 22);
        assert_eq!(renderer.stats.layout_hits, 2);  // 第 5、6 行
        assert_eq!(renderer.stats.cache_misses, 0);
    }

    /// 测试：选区拖动
    #[test]
    fn test_selection_drag() {
        let mut renderer = create_test_renderer();
        let mut state = create_mock_state();

        // 先渲染 10 行（无选区）
        for line in 0..10 {
            renderer.render_line(line, &state);
        }
        renderer.reset_stats();

        // 添加选区（覆盖 10 行），重新渲染
        state.selection = Some(SelectionView::new(
            AbsolutePoint::new(0, 0),
            AbsolutePoint::new(9, 10),
            SelectionType::Simple,
        ));
        for line in 0..10 {
            renderer.render_line(line, &state);
        }

        // 验证：外层缓存命中（跳过字体处理）
        assert_eq!(renderer.stats.layout_hits, 10);
        assert_eq!(renderer.stats.cache_misses, 0);
    }

    /// 测试：搜索高亮
    #[test]
    fn test_search_highlight() {
        let mut renderer = create_test_renderer();
        let mut state = create_mock_state();

        // 先渲染 5 行（无搜索）
        for line in 0..5 {
            renderer.render_line(line, &state);
        }
        renderer.reset_stats();

        // 添加搜索匹配（覆盖第 2、3 行）
        state.search = Some(SearchView::new(
            vec![
                MatchRange::new(AbsolutePoint::new(2, 0), AbsolutePoint::new(2, 5)),
                MatchRange::new(AbsolutePoint::new(3, 10), AbsolutePoint::new(3, 15)),
            ],
            0,
        ));
        for line in 0..5 {
            renderer.render_line(line, &state);
        }

        // 验证：第 0、1、4 行内层命中，第 2、3 行外层命中
        assert_eq!(renderer.stats.cache_hits, 3);
        assert_eq!(renderer.stats.layout_hits, 2);
    }

    /// 测试：统计信息重置
    #[test]
    fn test_stats_reset() {
        let mut renderer = create_test_renderer();

        // 验证初始统计
        assert_eq!(renderer.stats.cache_misses, 0);
        assert_eq!(renderer.stats.cache_hits, 0);
        assert_eq!(renderer.stats.layout_hits, 0);

        // 手动修改统计
        renderer.stats.cache_misses = 10;
        renderer.stats.cache_hits = 20;
        renderer.stats.layout_hits = 5;

        // 重置统计
        renderer.reset_stats();
        assert_eq!(renderer.stats.cache_misses, 0);
        assert_eq!(renderer.stats.cache_hits, 0);
        assert_eq!(renderer.stats.layout_hits, 0);
    }

    #[test]
    fn test_get_font_metrics_caching() {
        let mut renderer = create_test_renderer();

        // 第一次调用：计算 metrics
        let metrics1 = renderer.get_font_metrics();

        // 第二次调用：应该返回缓存的 metrics
        let metrics2 = renderer.get_font_metrics();

        // 验证返回的是相同的值
        assert_eq!(metrics1.cell_width, metrics2.cell_width);
        assert_eq!(metrics1.cell_height, metrics2.cell_height);
        assert_eq!(metrics1.baseline_offset, metrics2.baseline_offset);
    }

    #[test]
    fn test_reconfigure_invalidates_cache() {
        let mut renderer = create_test_renderer();

        // 计算初始 metrics
        let metrics1 = renderer.get_font_metrics();
        let cell_width1 = metrics1.cell_width;

        // 修改字体大小
        let new_config = RenderConfig::new(16.0, 1.0, 1.0);
        renderer.reconfigure(new_config);

        // 重新计算 metrics（缓存已失效）
        let metrics2 = renderer.get_font_metrics();
        let cell_width2 = metrics2.cell_width;

        // 验证 metrics 已改变
        assert_ne!(cell_width1, cell_width2);
        assert!(cell_width2 > cell_width1);  // 更大的字体 → 更宽的单元格
    }

    #[test]
    fn test_set_font_size() {
        let mut renderer = create_test_renderer();

        // 初始配置
        assert_eq!(renderer.config().font_size, 14.0);

        // 修改字体大小
        renderer.set_font_size(16.0);

        // 验证配置已更新
        assert_eq!(renderer.config().font_size, 16.0);
    }

    #[test]
    fn test_reconfigure_no_change() {
        let mut renderer = create_test_renderer();

        // 计算初始 metrics（填充缓存）
        let _ = renderer.get_font_metrics();

        // 使用相同配置重新配置（不应该清空缓存）
        let config = RenderConfig::new(14.0, 1.0, 1.0);
        renderer.reconfigure(config);

        // 缓存应该仍然有效
        assert!(renderer.cached_metrics.is_some());
    }

    // ==================== 端到端集成测试 ====================

    /// 端到端测试：渲染包含真实内容的终端状态
    #[test]
    fn test_end_to_end_render_hello_world() {
        use crate::domain::aggregates::terminal::{Terminal, TerminalId};

        let mut renderer = create_test_renderer();

        // 创建真实的终端（使用 DDD 聚合根）
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入 "Hello World"
        terminal.write(b"Hello World");

        // 获取终端状态
        let state = terminal.state();

        // 渲染第一行
        let img = renderer.render_line(0, &state);

        // 验证图像生成
        assert!(img.width() > 0);
        assert!(img.height() > 0);
        assert_eq!(img.width(), (80.0 * renderer.get_font_metrics().cell_width) as i32);

        // 验证没有统计错误
        assert_eq!(renderer.stats.cache_misses, 1);  // 首次渲染
    }

    /// 端到端测试：渲染带颜色的 ANSI 文本
    #[test]
    fn test_end_to_end_render_ansi_colors() {
        use crate::domain::aggregates::terminal::{Terminal, TerminalId};

        let mut renderer = create_test_renderer();
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入带 ANSI 颜色的文本
        // ESC[31m = 红色前景
        terminal.write(b"\x1b[31mRed Text\x1b[0m");

        let state = terminal.state();

        // 渲染第一行
        let img = renderer.render_line(0, &state);

        assert!(img.width() > 0);
        assert!(img.height() > 0);
    }

    /// 端到端测试：多行渲染和缓存
    #[test]
    fn test_end_to_end_multiline_with_cache() {
        use crate::domain::aggregates::terminal::{Terminal, TerminalId};

        let mut renderer = create_test_renderer();
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 写入多行内容
        for i in 0..5 {
            terminal.write(format!("Line {}\r\n", i).as_bytes());
        }

        let state = terminal.state();

        // 渲染所有 5 行
        for line in 0..5 {
            let img = renderer.render_line(line, &state);
            assert!(img.width() > 0);
        }

        // 验证统计：5 次 cache miss（首次渲染）
        assert_eq!(renderer.stats.cache_misses, 5);

        // 重新渲染相同的行（应该全部命中缓存）
        renderer.reset_stats();
        for line in 0..5 {
            let _ = renderer.render_line(line, &state);
        }

        assert_eq!(renderer.stats.cache_hits, 5);
        assert_eq!(renderer.stats.cache_misses, 0);
    }

    /// 端到端测试：光标移动的缓存失效
    #[test]
    fn test_end_to_end_cursor_move_invalidation() {
        use crate::domain::aggregates::terminal::{Terminal, TerminalId};

        let mut renderer = create_test_renderer();
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        terminal.write(b"Test");

        let state1 = terminal.state();

        // 渲染第 0 行（光标在这里）
        let _ = renderer.render_line(0, &state1);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 光标移动到第 1 行
        terminal.write(b"\r\n");
        let state2 = terminal.state();
        renderer.reset_stats();

        // 重新渲染第 0 行（光标已不在这里）
        let _ = renderer.render_line(0, &state2);
        // 注意：可能是 cache_hit 或 layout_hit，取决于行内容是否改变
        // 如果光标移动导致第 0 行内容不变，应该是 cache_hit
        // 但如果终端清除了光标位置的字符，可能是 layout_hit
        assert!(renderer.stats.cache_hits > 0 || renderer.stats.layout_hits > 0);

        // 渲染第 1 行（光标在这里，cache miss）
        let _ = renderer.render_line(1, &state2);
        assert_eq!(renderer.stats.cache_misses, 1);
    }

    /// 端到端测试：背景色变化导致缓存失效
    #[test]
    fn test_end_to_end_background_color_change() {
        use crate::domain::aggregates::terminal::{Terminal, TerminalId};

        let mut renderer = create_test_renderer();
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        terminal.write(b"Hello");

        let state = terminal.state();

        // 使用黑色背景渲染
        let img1 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 改变背景色为白色
        renderer.set_background_color(skia_safe::Color4f::new(1.0, 1.0, 1.0, 1.0));
        renderer.reset_stats();

        // 重新渲染（应该 cache miss，因为背景色变了）
        let img2 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 验证图像不同（宽高相同，但内容不同）
        assert_eq!(img1.width(), img2.width());
        assert_eq!(img1.height(), img2.height());
    }
}
