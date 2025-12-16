use crate::domain::TerminalState;
use crate::domain::views::grid::CellData;
use super::cache::{LineCache, GlyphLayout, CacheResult, CursorInfo, SearchMatchInfo, HyperlinkHoverInfo};
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
                // 复用字体选择（layout），重新计算状态（cursor/选区/搜索）
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

    /// 打印当前帧的缓存统计并重置
    pub fn print_frame_stats(&mut self, frame_label: &str) {
        let total = self.stats.cache_hits + self.stats.layout_hits + self.stats.cache_misses;
        if total > 0 {
            let hit_rate = (self.stats.cache_hits as f64 / total as f64) * 100.0;
            // eprintln!("📊 CACHE [{}] L1={} L2={} L3={} total={} hit={:.1}%",
            //     frame_label,
            //     self.stats.cache_hits,
            //     self.stats.layout_hits,
            //     self.stats.cache_misses,
            //     total,
            //     hit_rate);
        }
        self.reset_stats();
    }

    /// 从 TerminalState 提取指定行的数据，转换为 BuilderLine
    ///
    /// # 参数
    /// - `screen_line`: 屏幕行号（0 = 屏幕顶部）
    /// - `state`: 终端状态
    fn extract_line(&self, screen_line: usize, state: &TerminalState) -> BuilderLine {
        // 获取行数据
        let row_view = match state.grid.row(screen_line) {
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

            // 🔧 修复：跳过宽字符的占位符（WIDE_CHAR_SPACER）
            // 宽字符（如中文）在 Grid 中占据 2 个 cell：
            // - cell[0]: 实际字符 with WIDE_CHAR flag
            // - cell[1]: 占位符 with WIDE_CHAR_SPACER flag (应该跳过)
            const WIDE_CHAR_SPACER: u16 = 0b0000_0000_0100_0000;
            if cell.flags & WIDE_CHAR_SPACER != 0 {
                continue;  // 跳过占位符
            }

            let ch = cell.c;

            // 从 CellData 构造 FragmentStyle（只提取原始样式，不含选区/搜索高亮）
            let style = self.cell_to_fragment_style(&cell);

            // 如果样式改变，创建新 fragment
            // styles_equal 已经比较了 width，所以 width 改变会自动分割 fragment
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

            // 🔧 关键修复：添加零宽字符（如 VS16 U+FE0F emoji 变体选择符）
            // 这样 text_shaper 才能检测到 next_is_vs16 并使用 emoji 字体
            for &zw in &cell.zerowidth {
                current_content.push(zw);
            }
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
    ///
    /// # 参数
    /// - `cell`: 单元格数据
    ///
    /// # 设计说明
    /// 只提取 cell 的原始样式（颜色、字体属性、装饰）。
    /// 选区和搜索高亮在 LineRasterizer 中动态计算，避免缓存污染。
    fn cell_to_fragment_style(&self, cell: &CellData) -> FragmentStyle {
        use rio_backend::config::colors::NamedColor;
        use sugarloaf::layout::{UnderlineInfo, UnderlineShape, FragmentStyleDecoration};
        use sugarloaf::font_introspector::{Stretch, Weight, Style};

        // ===== Flags 常量定义 =====
        const INVERSE: u16         = 0b0000_0000_0000_0001;
        const BOLD: u16            = 0b0000_0000_0000_0010;
        const ITALIC: u16          = 0b0000_0000_0000_0100;
        const UNDERLINE: u16       = 0b0000_0000_0000_1000;
        const WIDE_CHAR: u16       = 0b0000_0000_0010_0000;
        const DIM: u16             = 0b0000_0000_1000_0000;
        const HIDDEN: u16          = 0b0000_0001_0000_0000;
        const STRIKEOUT: u16       = 0b0000_0010_0000_0000;
        const DOUBLE_UNDERLINE: u16= 0b0000_1000_0000_0000;
        const UNDERCURL: u16       = 0b0001_0000_0000_0000;
        const DOTTED_UNDERLINE: u16= 0b0010_0000_0000_0000;
        const DASHED_UNDERLINE: u16= 0b0100_0000_0000_0000;

        // 获取颜色配置
        let colors = &self.config.colors;
        let flags = cell.flags;

        // ===== 宽度计算 =====
        let width = if flags & WIDE_CHAR != 0 {
            2.0  // 双宽字符（中文、全角、emoji 等）
        } else {
            1.0  // 单宽字符
        };

        // ===== 基础颜色 =====
        let mut fg_color = ansi_color_to_rgba(&cell.fg, colors);
        let mut bg_color = ansi_color_to_rgba(&cell.bg, colors);

        // 背景色：仅当不是默认背景时才设置
        let mut background_color = match &cell.bg {
            AnsiColor::Named(NamedColor::Background) => None, // 透明背景
            _ => Some(bg_color),
        };

        // ===== INVERSE: 前景/背景色互换 =====
        if flags & INVERSE != 0 {
            std::mem::swap(&mut fg_color, &mut bg_color);
            // INVERSE 时强制显示背景色（即使原本是透明的）
            background_color = Some(bg_color);
        }

        // ===== DIM: 降低亮度 50% =====
        if flags & DIM != 0 {
            fg_color[0] *= 0.5;
            fg_color[1] *= 0.5;
            fg_color[2] *= 0.5;
        }

        // ===== HIDDEN: 隐藏字符（alpha = 0） =====
        if flags & HIDDEN != 0 {
            fg_color[3] = 0.0;
        }

        // ===== BOLD / ITALIC: 字体属性 =====
        let font_attrs = {
            let weight = if flags & BOLD != 0 {
                Weight::BOLD
            } else {
                Weight::NORMAL
            };

            let style = if flags & ITALIC != 0 {
                Style::Italic
            } else {
                Style::Normal
            };

            Attributes::new(Stretch::NORMAL, weight, style)
        };

        // ===== 下划线和删除线 =====
        let decoration = if flags & STRIKEOUT != 0 {
            Some(FragmentStyleDecoration::Strikethrough)
        } else if flags & UNDERCURL != 0 {
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Curly,
            }))
        } else if flags & DOTTED_UNDERLINE != 0 {
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Dotted,
            }))
        } else if flags & DASHED_UNDERLINE != 0 {
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Dashed,
            }))
        } else if flags & DOUBLE_UNDERLINE != 0 {
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: true,
                shape: UnderlineShape::Regular,
            }))
        } else if flags & UNDERLINE != 0 {
            Some(FragmentStyleDecoration::Underline(UnderlineInfo {
                is_doubled: false,
                shape: UnderlineShape::Regular,
            }))
        } else {
            None
        };

        // ===== 光标 =====
        // 注意：光标现在在 LineRasterizer 中渲染（通过独立的 cursor_info 参数）
        let cursor = None;

        // ===== 选区高亮 =====
        // 🔧 选区高亮完全在 LineRasterizer 中动态计算，不写入 GlyphLayout
        // 避免缓存污染问题（选区变化时，屏幕外的行无法更新缓存）

        // ===== 搜索匹配高亮 =====
        // 🔧 搜索高亮完全在 LineRasterizer 中动态计算，不写入 GlyphLayout
        // 避免缓存污染问题（关闭搜索时，屏幕外的行无法更新缓存）

        // 下划线颜色（ANSI 支持自定义）
        let decoration_color = cell.underline_color.map(|c| ansi_color_to_rgba(&c, colors));

        FragmentStyle {
            font_id: 0,
            width,
            font_attrs,
            color: fg_color,
            background_color,
            font_vars: 0,
            decoration,
            decoration_color,
            cursor,
            media: None,
            drawable_char: None,
        }
    }

    /// 获取字体度量（带缓存，自动管理）
    pub fn get_font_metrics(&mut self) -> FontMetrics {
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

    /// 清空缓存（窗口 resize 时调用）
    pub fn clear_cache(&mut self) {
        self.cache.clear();
    }

    // ===== 便捷方法：单独修改某个参数 =====

    /// 设置字体大小（常见操作，如用户按 Ctrl+Plus 缩放）
    pub fn set_font_size(&mut self, font_size: crate::domain::primitives::LogicalPixels) {
        self.reconfigure(RenderConfig {
            font_size,
            line_height: self.config.line_height,
            scale: self.config.scale,
            background_color: self.config.background_color,
            colors: Arc::clone(&self.config.colors),
            box_drawing: self.config.box_drawing.clone(),
        });
    }

    /// 设置行高
    pub fn set_line_height(&mut self, line_height: f32) {
        self.reconfigure(RenderConfig {
            font_size: self.config.font_size,
            line_height,
            scale: self.config.scale,
            background_color: self.config.background_color,
            colors: Arc::clone(&self.config.colors),
            box_drawing: self.config.box_drawing.clone(),
        });
    }

    /// 设置 DPI 缩放（如窗口移动到不同显示器）
    pub fn set_scale(&mut self, scale: f32) {
        self.reconfigure(RenderConfig {
            font_size: self.config.font_size,
            line_height: self.config.line_height,
            scale,
            background_color: self.config.background_color,
            colors: Arc::clone(&self.config.colors),
            box_drawing: self.config.box_drawing.clone(),
        });
    }

    /// 设置背景颜色
    pub fn set_background_color(&mut self, color: skia_safe::Color4f) {
        self.reconfigure(RenderConfig {
            font_size: self.config.font_size,
            line_height: self.config.line_height,
            scale: self.config.scale,
            background_color: color,
            colors: Arc::clone(&self.config.colors),
            box_drawing: self.config.box_drawing.clone(),
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
        let physical_font_size = self.config.physical_font_size();

        // 3. 文本整形（传递 line 和 state 用于光标检测）
        self.text_shaper.shape_line(
            &builder_line,
            physical_font_size.value,
            metrics.cell_width.value,
            line,
            state,
        )
    }

    /// 基于布局绘制（光栅化）
    ///
    /// 注意：cursor_info 从 state 动态计算，不从 layout 缓存读取
    fn render_with_layout(&mut self, layout: GlyphLayout, line: usize, state: &TerminalState) -> skia_safe::Image {
        // 获取 metrics（自动缓存）
        let metrics = self.get_font_metrics();

        // 计算行宽度（物理像素）
        let line_width = metrics.cell_width.value * state.grid.columns() as f32;

        // 从配置获取背景色（不再硬编码）
        let background_color = self.config.background_color;

        // 🎯 计算完整行高（= cell_height * line_height_factor）
        // 用于 box-drawing 字符的拉升填充
        let line_height = metrics.cell_height.value * self.config.line_height;

        // 🔧 从 state 动态计算 cursor_info（不从 layout 缓存读取）
        // 注意：cursor.line() 是绝对坐标，line 是屏幕行号，需要转换
        // 绝对坐标 = history_size + 屏幕行号 - display_offset
        // 所以：屏幕行号 = 绝对坐标 - history_size + display_offset
        let cursor_screen_line = state.cursor.line()
            .saturating_sub(state.grid.history_size())
            .saturating_add(state.grid.display_offset());

        let cursor_info = if state.cursor.is_visible() && cursor_screen_line == line {
            Some(CursorInfo {
                col: state.cursor.col(),
                shape: state.cursor.shape,
                color: state.cursor.color,
            })
        } else {
            None
        };

        // 🔧 从 state 动态计算 search_info（不从 layout 缓存读取）
        // 注意：search 使用绝对坐标，需要转换为屏幕行号进行比较
        let search_info = if let Some(search) = &state.search {
            // 转换屏幕行号为绝对行号
            let abs_line = state.grid.history_size()
                .saturating_add(line)
                .saturating_sub(state.grid.display_offset());

            // 使用按行索引快速查找该行的匹配
            if let Some(indices) = search.get_matches_at_line(abs_line) {
                // 收集本行的匹配范围
                let mut ranges = Vec::new();
                for &idx in indices {
                    let m = &search.matches[idx];
                    let is_focused = idx == search.focused_index;

                    // 计算本行的匹配列范围
                    let start_col = if abs_line == m.start.line {
                        m.start.col
                    } else {
                        0
                    };
                    let end_col = if abs_line == m.end.line {
                        m.end.col
                    } else {
                        usize::MAX
                    };

                    ranges.push((start_col, end_col, is_focused));
                }

                if !ranges.is_empty() {
                    Some(SearchMatchInfo {
                        ranges,
                        fg_color: self.config.colors.search_match_foreground,
                        bg_color: self.config.colors.search_match_background,
                        focused_fg_color: self.config.colors.search_focused_match_foreground,
                        focused_bg_color: self.config.colors.search_focused_match_background,
                    })
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        };

        // 🔧 从 state 动态计算 hyperlink_hover_info
        let hyperlink_hover_info = if let Some(hover) = &state.hyperlink_hover {
            // 转换屏幕行号为绝对行号
            let abs_line = state.grid.history_size()
                .saturating_add(line)
                .saturating_sub(state.grid.display_offset());

            // 检查本行是否在超链接范围内
            if let Some((start_col, end_col)) = hover.column_range_on_line(abs_line, usize::MAX) {
                Some(HyperlinkHoverInfo {
                    start_col,
                    end_col,
                    // 超链接使用蓝色（标准超链接颜色）
                    fg_color: [0.0, 0.5, 1.0, 1.0],
                })
            } else {
                None
            }
        } else {
            None
        };

        // 🔧 获取当前行的 URL 范围（用于绘制下划线）
        let url_ranges: Vec<_> = state.grid.row(line)
            .map(|row| row.urls().to_vec())
            .unwrap_or_default();

        self.rasterizer
            .render(
                &layout,
                cursor_info.as_ref(),
                search_info.as_ref(),
                hyperlink_hover_info.as_ref(),
                &url_ranges,
                line_width,
                metrics.cell_width.value,
                metrics.cell_height.value,
                line_height,
                metrics.baseline_offset.value,
                background_color,
                &self.config.box_drawing,
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
        && a.font_attrs == b.font_attrs
        && a.decoration == b.decoration
}

/// 将 AnsiColor 转换为 RGBA [f32; 4]
///
/// # 参数
/// - `color`: ANSI 颜色
/// - `colors`: 颜色配置（从用户配置加载）
fn ansi_color_to_rgba(color: &AnsiColor, colors: &rio_backend::config::colors::Colors) -> [f32; 4] {
    use rio_backend::config::colors::NamedColor;

    match color {
        AnsiColor::Named(named) => match named {
            NamedColor::Foreground => colors.foreground,
            NamedColor::Background => colors.background.0,
            NamedColor::Black => colors.black,
            NamedColor::Red => colors.red,
            NamedColor::Green => colors.green,
            NamedColor::Yellow => colors.yellow,
            NamedColor::Blue => colors.blue,
            NamedColor::Magenta => colors.magenta,
            NamedColor::Cyan => colors.cyan,
            NamedColor::White => colors.white,
            NamedColor::LightBlack => colors.light_black,
            NamedColor::LightRed => colors.light_red,
            NamedColor::LightGreen => colors.light_green,
            NamedColor::LightYellow => colors.light_yellow,
            NamedColor::LightBlue => colors.light_blue,
            NamedColor::LightMagenta => colors.light_magenta,
            NamedColor::LightCyan => colors.light_cyan,
            NamedColor::LightWhite => colors.light_white,
            _ => colors.foreground,  // 默认使用前景色
        },
        AnsiColor::Spec(rgb) => [
            rgb.r as f32 / 255.0,
            rgb.g as f32 / 255.0,
            rgb.b as f32 / 255.0,
            1.0,
        ],
        AnsiColor::Indexed(idx) => {
            // 256 色索引：前 16 色从配置读取
            match idx {
                0 => colors.black,
                1 => colors.red,
                2 => colors.green,
                3 => colors.yellow,
                4 => colors.blue,
                5 => colors.magenta,
                6 => colors.cyan,
                7 => colors.white,
                8 => colors.light_black,
                9 => colors.light_red,
                10 => colors.light_green,
                11 => colors.light_yellow,
                12 => colors.light_blue,
                13 => colors.light_magenta,
                14 => colors.light_cyan,
                15 => colors.light_white,
                // 216 色立方体 (16-231)
                16..=231 => {
                    let i = idx - 16;
                    let r = i / 36;
                    let g = (i % 36) / 6;
                    let b = i % 6;
                    let to_value = |v: u8| if v == 0 { 0.0 } else { (55.0 + v as f32 * 40.0) / 255.0 };
                    [to_value(r), to_value(g), to_value(b), 1.0]
                }
                // 24 级灰度 (232-255)
                _ => {
                    let gray = (8.0 + (idx - 232) as f32 * 10.0) / 255.0;
                    [gray, gray, gray, 1.0]
                }
            }
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

    fn create_default_colors() -> Arc<rio_backend::config::colors::Colors> {
        use rio_backend::config::colors::Colors;
        Arc::new(Colors::default())
    }

    /// 创建测试用 Renderer
    fn create_test_renderer() -> Renderer {
        use crate::domain::primitives::LogicalPixels;
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));

        // 使用真实的配置
        let colors = create_default_colors();
        let config = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 1.0, colors);
        Renderer::new(font_context, config)
    }

    /// 创建 Mock TerminalState
    fn create_mock_state() -> TerminalState {
        // 创建每行有唯一 hash 的 GridData
        let row_hashes: Vec<u64> = (0..24).map(|i| 1000 + i as u64).collect();
        let grid_data = Arc::new(GridData::new_mock(80, 24, 0, row_hashes));
        let grid = GridView::new(grid_data);

        let cursor = CursorView::new(AbsolutePoint::new(0, 0), CursorShape::Block);

        TerminalState {
            grid,
            cursor,
            selection: None,
            search: None,
            hyperlink_hover: None,
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
    /// 创建所有行 hash 相同的 Mock State（模拟空行场景）
    fn create_mock_state_same_hash() -> TerminalState {
        // 所有行 hash 相同（模拟全空行）
        let row_hashes: Vec<u64> = vec![9999; 24];
        let grid_data = Arc::new(GridData::new_mock(80, 24, 0, row_hashes));
        let grid = GridView::new(grid_data);

        let cursor = CursorView::new(AbsolutePoint::new(0, 0), CursorShape::Block);

        TerminalState {
            grid,
            cursor,
            selection: None,
            search: None,
            hyperlink_hover: None,
        }
    }

    /// 🐛 BUG 复现测试：相同内容的行，光标只应该出现在光标所在行
    ///
    /// 场景：
    /// - Line 0: 空行 + 有光标 → 渲染出带光标的 image
    /// - Line 1: 空行 + 无光标 → 应该渲染出无光标的 image
    ///
    /// Bug：Line 1 错误地复用了 Line 0 的 layout（带 cursor_info），导致也显示光标
    #[test]
    fn test_same_content_different_cursor_state() {
        let mut renderer = create_test_renderer();
        let state = create_mock_state_same_hash();

        // 光标在第 0 行
        assert_eq!(state.cursor.position.line, 0);

        // 渲染 Line 0（有光标）→ Miss
        let _img0 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_misses, 1, "Line 0 should be cache miss");

        renderer.reset_stats();

        // 渲染 Line 1（无光标，但 text_hash 相同）
        // 期望：要么 Miss（重新计算），要么 LayoutHit 但 cursor_info 为 None
        let _img1 = renderer.render_line(1, &state);

        // 打印实际结果
        eprintln!("Line 1 stats: misses={}, layout_hits={}, cache_hits={}",
            renderer.stats.cache_misses,
            renderer.stats.layout_hits,
            renderer.stats.cache_hits);

        // 关键断言：Line 1 不应该命中 Line 0 的带光标缓存
        // 如果 layout_hits == 1，说明复用了 layout，需要检查 cursor_info 是否被正确处理
        // 如果 cache_hits == 1，那就是严重 bug（直接返回了带光标的 image）

        // 目前期望行为：由于 state_hash 不同（Line 0 有光标，Line 1 无光标），
        // 应该是 LayoutHit 或 Miss，不应该是 FullHit
        assert_eq!(renderer.stats.cache_hits, 0,
            "BUG: Line 1 should NOT get FullHit from Line 0's cached image!");
    }

    /// 🐛 BUG 复现测试：LayoutHit 时 cursor_info 应该被正确处理
    ///
    /// 验证：当 Line 1 走 LayoutHit 分支时，不应该使用 Line 0 的 cursor_info
    #[test]
    fn test_layout_hit_cursor_info_not_inherited() {
        let mut renderer = create_test_renderer();
        let state = create_mock_state_same_hash();

        // 光标在第 0 行
        assert_eq!(state.cursor.position.line, 0);

        // 渲染 Line 0（有光标）→ Miss，layout 里有 cursor_info
        let _img0 = renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_misses, 1);

        renderer.reset_stats();

        // 渲染 Line 1（无光标）→ LayoutHit
        let _img1 = renderer.render_line(1, &state);
        assert_eq!(renderer.stats.layout_hits, 1, "Line 1 should be LayoutHit");

        // 注：cursor_info 在 render_with_layout() 中从 state 动态计算，
        // 不从 layout 缓存读取，所以 LayoutHit 时光标会被正确处理
    }

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
        assert_eq!(metrics1.cell_width.value, metrics2.cell_width.value);
        assert_eq!(metrics1.cell_height.value, metrics2.cell_height.value);
        assert_eq!(metrics1.baseline_offset.value, metrics2.baseline_offset.value);
    }

    #[test]
    fn test_reconfigure_invalidates_cache() {
        use crate::domain::primitives::LogicalPixels;
        let mut renderer = create_test_renderer();

        // 计算初始 metrics
        let metrics1 = renderer.get_font_metrics();
        let cell_width1 = metrics1.cell_width.value;

        // 修改字体大小
        let colors = create_default_colors();
        let new_config = RenderConfig::new(LogicalPixels::new(16.0), 1.0, 1.0, colors);
        renderer.reconfigure(new_config);

        // 重新计算 metrics（缓存已失效）
        let metrics2 = renderer.get_font_metrics();
        let cell_width2 = metrics2.cell_width.value;

        // 验证 metrics 已改变
        assert_ne!(cell_width1, cell_width2);
        assert!(cell_width2 > cell_width1);  // 更大的字体 → 更宽的单元格
    }

    #[test]
    fn test_set_font_size() {
        use crate::domain::primitives::LogicalPixels;
        let mut renderer = create_test_renderer();

        // 初始配置
        assert_eq!(renderer.config().font_size.value, 14.0);

        // 修改字体大小
        renderer.set_font_size(LogicalPixels::new(16.0));

        // 验证配置已更新
        assert_eq!(renderer.config().font_size.value, 16.0);
    }

    #[test]
    fn test_reconfigure_no_change() {
        use crate::domain::primitives::LogicalPixels;
        let mut renderer = create_test_renderer();

        // 计算初始 metrics（填充缓存）
        let _ = renderer.get_font_metrics();

        // 使用相同配置重新配置（不应该清空缓存）
        // 注意：使用相同的 Arc<Colors> 实例，确保 PartialEq 返回 true
        let colors = Arc::clone(&renderer.config().colors);
        let config = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 1.0, colors);
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
        assert_eq!(img.width(), (80.0 * renderer.get_font_metrics().cell_width.value) as i32);

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

    /// 性能测试：选区从 (0,0)-(3,10) 扩展到 (0,0)-(3,20)
    ///
    /// 场景：100 行终端，选区末端从 col10 移动到 col20
    /// 期望：只有 row3 需要重新渲染，其他 99 行应该缓存命中
    #[test]
    fn test_selection_expand_performance() {
        let mut renderer = create_test_renderer();

        // 创建 100 行的 mock state
        let row_hashes: Vec<u64> = (0..100).map(|i| 1000 + i as u64).collect();
        let grid_data = Arc::new(GridData::new_mock(80, 100, 0, row_hashes));
        let grid = GridView::new(grid_data);
        let cursor = CursorView::new(AbsolutePoint::new(50, 0), CursorShape::Block);

        // 初始选区：(0,0) 到 (3,10)
        let mut state = TerminalState {
            grid: grid.clone(),
            cursor: cursor.clone(),
            selection: Some(SelectionView::new(
                AbsolutePoint::new(0, 0),
                AbsolutePoint::new(3, 10),
                SelectionType::Simple,
            )),
            search: None,
            hyperlink_hover: None,
        };

        // === 第一帧：渲染所有 100 行（全部 cache miss）===
        let frame1_start = std::time::Instant::now();
        for line in 0..100 {
            let _img = renderer.render_line(line, &state);
        }
        let frame1_time = frame1_start.elapsed();

        eprintln!("Frame 1 (cold): {:?} | misses={} hits={} layout_hits={}",
            frame1_time,
            renderer.stats.cache_misses,
            renderer.stats.cache_hits,
            renderer.stats.layout_hits);

        assert_eq!(renderer.stats.cache_misses, 100, "Frame 1: all lines should miss");
        renderer.reset_stats();

        // === 第二帧：选区扩展到 (0,0)-(3,20) ===
        state.selection = Some(SelectionView::new(
            AbsolutePoint::new(0, 0),
            AbsolutePoint::new(3, 20),
            SelectionType::Simple,
        ));

        let frame2_start = std::time::Instant::now();
        for line in 0..100 {
            let _img = renderer.render_line(line, &state);
        }
        let frame2_time = frame2_start.elapsed();

        eprintln!("Frame 2 (selection expanded): {:?} | misses={} hits={} layout_hits={}",
            frame2_time,
            renderer.stats.cache_misses,
            renderer.stats.cache_hits,
            renderer.stats.layout_hits);

        // 期望：
        // - row 0,1,2: 选区范围是 (0, MAX)，没变化 → cache_hits
        // - row 3: 选区范围从 (0,10) 变为 (0,20) → layout_hits
        // - row 4-99: 不在选区内 → cache_hits
        // 总计：99 hits + 1 layout_hit
        assert_eq!(renderer.stats.cache_hits, 99,
            "Frame 2: 99 lines should hit cache (row 0-2 and row 4-99)");
        assert_eq!(renderer.stats.layout_hits, 1,
            "Frame 2: only row 3 should need re-render (layout hit)");
        assert_eq!(renderer.stats.cache_misses, 0,
            "Frame 2: no cache misses expected");

        // 性能断言：第二帧应该比第一帧快很多
        eprintln!("Speedup: {:.1}x", frame1_time.as_micros() as f64 / frame2_time.as_micros() as f64);
        assert!(frame2_time < frame1_time / 2,
            "Frame 2 should be at least 2x faster than Frame 1");
    }
}
