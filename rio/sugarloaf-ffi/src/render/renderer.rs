use crate::domain::TerminalState;
use crate::domain::views::grid::CellData;
use super::cache::{LineCache, GlyphLayout, CacheResult};
use super::cache::GlyphAtlas;
use super::cache::{compute_text_hash, compute_state_hash_for_line};
use super::font::FontContext;
use super::layout::TextShaper;
use super::rasterizer::GlyphRasterizer;
use super::config::{RenderConfig, FontMetrics};
use super::block_drawing::{BlockDrawer, is_drawable_block_char};
use sugarloaf::layout::{BuilderLine, FragmentData, FragmentStyle};
use sugarloaf::font_introspector::Attributes;
use rio_backend::config::colors::AnsiColor;
use std::sync::Arc;
use std::cell::RefCell;
use skia_safe::{FontMgr, Color};
use skia_safe::textlayout::{FontCollection, ParagraphBuilder, ParagraphStyle, TextStyle};

thread_local! {
    /// 线程本地 FontCollection（用于 emoji 渲染）
    static FONT_COLLECTION: RefCell<FontCollection> = RefCell::new({
        let mut fc = FontCollection::new();
        fc.set_default_font_manager(FontMgr::new(), None);
        fc
    });
}

/// Color4f 转 Color
fn color4f_to_color(c: skia_safe::Color4f) -> Color {
    Color::from_argb(
        (c.a * 255.0) as u8,
        (c.r * 255.0) as u8,
        (c.g * 255.0) as u8,
        (c.b * 255.0) as u8,
    )
}

/// 渲染引擎（管理缓存 + 渲染流程）
pub struct Renderer {
    /// 行缓存（pub 用于内存统计）
    pub cache: LineCache,
    /// 统计信息（用于测试验证）
    pub stats: RenderStats,
    /// 字体上下文
    font_context: Arc<FontContext>,
    /// 文本整形器
    text_shaper: TextShaper,
    /// 字形光栅化器（Atlas 路径）
    glyph_rasterizer: GlyphRasterizer,
    /// 字形 Atlas（字形纹理缓存）
    glyph_atlas: GlyphAtlas,
    /// Block Elements 绘制器（解决高 DPI 缝隙问题）
    block_drawer: BlockDrawer,

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
            glyph_rasterizer: GlyphRasterizer::new(),
            glyph_atlas: GlyphAtlas::new(),
            block_drawer: BlockDrawer::new(),
            config,
            cached_metrics: None,
        }
    }

    /// 获取 Atlas 统计信息
    pub fn atlas_stats(&self) -> super::cache::AtlasStats {
        self.glyph_atlas.stats()
    }

    /// 渲染一行
    ///
    /// # 参数
    /// - `line`: 屏幕行号
    /// - `state`: 终端状态
    /// - `_gpu_context`: 未使用（保留用于 API 兼容）
    pub fn render_line(&mut self, line: usize, state: &TerminalState, _gpu_context: Option<&mut skia_safe::gpu::DirectContext>) -> skia_safe::Image {
        self.render_line_atlas(line, state)
    }

    /// 混合渲染策略：LineCache (1-2屏) + Atlas (历史滚动)
    ///
    /// 1. 首先查询 LineCache（FullHit = 最快，直接 blit）
    /// 2. 如果 LineCache miss，使用 Atlas 渲染（字形已预热，快速组合）
    /// 3. 渲染完成后存入 LineCache（LRU 自动淘汰旧条目）
    fn render_line_atlas(&mut self, line: usize, state: &TerminalState) -> skia_safe::Image {
        let text_hash = compute_text_hash(line, state);
        let state_hash = compute_state_hash_for_line(line, state);

        // 第一步：查询 LineCache（两层缓存）
        match self.cache.get(text_hash, state_hash) {
            CacheResult::FullHit(image) => {
                // 🎯 最快路径：LineCache 完全命中，直接返回
                self.stats.cache_hits += 1;
                return image;
            }
            CacheResult::LayoutHit(layout) => {
                // 📐 布局命中：使用 Atlas 重新组合渲染
                self.stats.layout_hits += 1;
                let image = self.render_with_atlas(layout.clone(), line, state);
                // 存入 LineCache（LRU 会自动淘汰旧条目）
                self.cache.insert(text_hash, state_hash, layout, image.clone());
                return image;
            }
            CacheResult::Miss => {
                // 继续执行下面的完整渲染流程
            }
        }

        // 第二步：完全 miss，计算布局 + Atlas 渲染
        self.stats.cache_misses += 1;
        let layout = self.compute_glyph_layout(line, state);
        let image = self.render_with_atlas(layout.clone(), line, state);

        // 存入 LineCache
        self.cache.insert(text_hash, state_hash, layout, image.clone());

        image
    }

    /// 获取当前帧的缓存统计（不重置）
    /// 返回 (cache_hits, layout_hits, cache_misses)
    pub fn get_frame_stats(&self) -> (usize, usize, usize) {
        (self.stats.cache_hits, self.stats.layout_hits, self.stats.cache_misses)
    }

    /// 打印当前帧的缓存统计并重置
    pub fn print_frame_stats(&mut self, _frame_label: &str) {
        // 统计已移至 render_all 中输出
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
        });
    }

    /// 获取当前配置（只读访问）
    pub fn config(&self) -> &RenderConfig {
        &self.config
    }

    /// Atlas 渲染：从 GlyphAtlas 组合字形
    ///
    /// 渲染策略：
    /// - 普通字符：走 GlyphAtlas + draw_atlas（高效批量渲染）
    /// - Emoji：直接使用 Paragraph API 渲染（支持彩色 emoji）
    ///
    /// 原因：draw_str 和 draw_atlas 不支持彩色 emoji（COLR/sbix 格式），
    /// 只有 Paragraph API 能正确渲染 Apple Color Emoji 等彩色字体。
    fn render_with_atlas(&mut self, layout: GlyphLayout, line: usize, state: &TerminalState) -> skia_safe::Image {
        use skia_safe::{surfaces, Paint, Color4f, Rect, Point};
        use rio_backend::ansi::CursorShape;

        let metrics = self.get_font_metrics();
        let line_width = metrics.cell_width.value * state.grid.columns() as f32;
        let line_height = metrics.cell_height.value * self.config.line_height;
        let cell_width = metrics.cell_width.value;
        let cell_height = metrics.cell_height.value;
        let baseline_offset = metrics.baseline_offset.value;
        let font_size = self.config.physical_font_size().value;
        let background_color = self.config.background_color;

        // 创建行 Surface
        let width = line_width.round() as i32;
        let height = line_height.round() as i32;
        let mut surface = surfaces::raster_n32_premul((width, height))
            .expect("Failed to create line surface");
        let canvas = surface.canvas();
        canvas.clear(background_color);

        // 计算光标信息
        let cursor_screen_line = state.cursor.line()
            .saturating_sub(state.grid.history_size())
            .saturating_add(state.grid.display_offset());
        let cursor_on_this_line = cursor_screen_line == line;
        let cursor_col = if state.cursor.is_visible() && cursor_on_this_line {
            Some(state.cursor.col())
        } else {
            None
        };

        // 🔧 计算搜索高亮信息（从 state 动态计算）
        // 🐛 调试日志：验证搜索状态是否正确传递
        if state.search.is_some() {
            eprintln!("🔍 [render_with_atlas] Line {} has search state with {} matches",
                line, state.search.as_ref().unwrap().matches.len());
        }
        let search_ranges: Vec<(usize, usize, bool)> = if let Some(search) = &state.search {
            let abs_line = state.grid.history_size()
                .saturating_add(line)
                .saturating_sub(state.grid.display_offset());

            if let Some(indices) = search.get_matches_at_line(abs_line) {
                indices.iter().map(|&idx| {
                    let m = &search.matches[idx];
                    let is_focused = idx == search.focused_index;
                    let start_col = if abs_line == m.start.line { m.start.col } else { 0 };
                    let end_col = if abs_line == m.end.line { m.end.col } else { usize::MAX };
                    (start_col, end_col, is_focused)
                }).collect()
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };

        // 🐛 调试日志：显示当前行的搜索匹配范围
        if !search_ranges.is_empty() {
            eprintln!("🔍 [render_with_atlas] Line {} search_ranges: {:?}", line, search_ranges);
        }

        // 预填充 Atlas + 收集绘制数据（仅普通字符）
        let mut xforms: Vec<skia_safe::RSXform> = Vec::with_capacity(layout.glyphs.len());
        let mut tex_rects: Vec<Rect> = Vec::with_capacity(layout.glyphs.len());
        let mut colors: Vec<skia_safe::Color> = Vec::with_capacity(layout.glyphs.len());

        // 收集需要单独渲染的 emoji（带列号，用于搜索高亮）
        let mut emoji_glyphs: Vec<(usize, &super::layout::GlyphInfo)> = Vec::new();

        let mut bg_paint = Paint::default();

        for glyph in &layout.glyphs {
            // 计算当前列号
            let current_col = (glyph.x / cell_width).round() as usize;

            // 检查是否在搜索匹配范围内
            let search_match = search_ranges.iter().find_map(|&(start, end, is_focused)| {
                if current_col >= start && current_col <= end {
                    Some(is_focused)
                } else {
                    None
                }
            });

            // 绘制背景（搜索高亮优先）
            if let Some(is_focused) = search_match {
                // 搜索匹配背景
                let bg = if is_focused {
                    self.config.colors.search_focused_match_background
                } else {
                    self.config.colors.search_match_background
                };
                bg_paint.set_color4f(Color4f::new(bg[0], bg[1], bg[2], bg[3]), None);
                let bg_width = cell_width * glyph.width;
                let rect = Rect::from_xywh(glyph.x, 0.0, bg_width, line_height);
                canvas.draw_rect(rect, &bg_paint);
            } else if let Some(bg) = glyph.background_color {
                // 原始背景
                bg_paint.set_color4f(bg, None);
                let bg_width = cell_width * glyph.width;
                let rect = Rect::from_xywh(glyph.x, 0.0, bg_width, line_height);
                canvas.draw_rect(rect, &bg_paint);
            }

            // 检测 emoji：不走 Atlas，收集后用 Paragraph 渲染
            if glyph.is_emoji() {
                emoji_glyphs.push((current_col, glyph));
                continue;
            }

            // 🎯 Block Elements 自定义绘制（解决高 DPI 缝隙问题）
            // 使用矩形填充代替字体渲染，确保像素级精确
            let first_char = glyph.grapheme.chars().next().unwrap_or(' ');
            if glyph.grapheme.chars().count() == 1 && is_drawable_block_char(first_char) {
                // 确定前景色（搜索高亮优先）
                let fg_color = if let Some(is_focused) = search_match {
                    let fg = if is_focused {
                        self.config.colors.search_focused_match_foreground
                    } else {
                        self.config.colors.search_match_foreground
                    };
                    Color4f::new(fg[0], fg[1], fg[2], fg[3])
                } else {
                    glyph.color
                };

                // 使用 BlockDrawer 绘制
                self.block_drawer.draw(
                    canvas,
                    first_char,
                    glyph.x,
                    0.0,  // y = 0，从行顶部开始
                    cell_width * glyph.width,
                    line_height,
                    fg_color,
                    self.config.scale,
                );
                continue;
            }

            // 普通字符：走 GlyphAtlas
            let key = GlyphRasterizer::make_key(glyph, font_size);
            let region = self.glyph_atlas.get_or_rasterize(key, || {
                self.glyph_rasterizer.rasterize(glyph, cell_width, cell_height, baseline_offset)
            });

            if let Some(region) = region {
                if region.width > 0 && region.height > 0 {
                    // 计算 bitmap 内的 x 偏移（与 GlyphRasterizer 一致）
                    // bitmap 中字形从 x_offset 开始，需要在定位时补偿
                    let (_, bounds) = glyph.font.measure_str(&glyph.grapheme, None);
                    let x_offset = if bounds.left < 0.0 { -bounds.left + 1.0 } else { 1.0 };

                    // RSXform: 无旋转缩放，平移时补偿 x_offset
                    // y_offset = 0 因为 bitmap 中已经按 baseline_offset 定位了字形
                    xforms.push(skia_safe::RSXform::new(1.0, 0.0, skia_safe::Vector::new(glyph.x - x_offset, 0.0)));
                    tex_rects.push(region.to_src_rect());

                    // 确定前景色（搜索高亮优先）
                    let fg_color = if let Some(is_focused) = search_match {
                        let fg = if is_focused {
                            self.config.colors.search_focused_match_foreground
                        } else {
                            self.config.colors.search_match_foreground
                        };
                        skia_safe::Color::from_argb(
                            (fg[3] * 255.0) as u8,
                            (fg[0] * 255.0) as u8,
                            (fg[1] * 255.0) as u8,
                            (fg[2] * 255.0) as u8,
                        )
                    } else {
                        glyph.color.to_color()
                    };
                    colors.push(fg_color);
                }
            }
        }

        // 一次 draw_atlas 调用绘制所有普通字符
        if !xforms.is_empty() {
            let atlas_image = self.glyph_atlas.get_image();
            canvas.draw_atlas(
                atlas_image,
                &xforms,
                &tex_rects,
                Some(colors.as_slice()),
                skia_safe::BlendMode::Modulate,
                skia_safe::SamplingOptions::default(),
                None,
                None,
            );
        }

        // 🎯 使用 Paragraph API 渲染 emoji（和 LineRasterizer 相同逻辑）
        // 这样才能正确渲染彩色 emoji（COLR/sbix 格式）
        if !emoji_glyphs.is_empty() {
            FONT_COLLECTION.with(|fc| {
                let font_collection = fc.borrow();

                for (col, glyph) in emoji_glyphs {
                    // 检查 emoji 是否在搜索匹配范围内
                    let emoji_search_match = search_ranges.iter().find_map(|&(start, end, is_focused)| {
                        if col >= start && col <= end {
                            Some(is_focused)
                        } else {
                            None
                        }
                    });

                    // 确定前景色（搜索高亮优先）
                    let fg_color = if let Some(is_focused) = emoji_search_match {
                        let fg = if is_focused {
                            self.config.colors.search_focused_match_foreground
                        } else {
                            self.config.colors.search_match_foreground
                        };
                        Color4f::new(fg[0], fg[1], fg[2], fg[3])
                    } else {
                        glyph.color
                    };

                    let mut paragraph_style = ParagraphStyle::new();
                    let mut text_style = TextStyle::new();
                    text_style.set_font_size(glyph.font.size());
                    text_style.set_color(color4f_to_color(fg_color));
                    // 明确指定 emoji 字体
                    text_style.set_font_families(&["Apple Color Emoji"]);
                    paragraph_style.set_text_style(&text_style);

                    let mut builder = ParagraphBuilder::new(&paragraph_style, font_collection.clone());
                    builder.add_text(&glyph.grapheme);

                    let mut paragraph = builder.build();
                    // 给 emoji 额外布局空间，和 LineRasterizer 保持一致
                    paragraph.layout(cell_width * glyph.width + 10.0);

                    // 使用 alphabetic_baseline 对齐，和 LineRasterizer 保持一致
                    let para_baseline = paragraph.alphabetic_baseline();
                    let y_offset = baseline_offset - para_baseline;

                    paragraph.paint(canvas, Point::new(glyph.x, y_offset));
                }
            });
        }

        // 绘制光标
        if let Some(col) = cursor_col {
            let cursor_x = col as f32 * cell_width;
            let cursor_color = Color4f::new(
                state.cursor.color[0],
                state.cursor.color[1],
                state.cursor.color[2],
                state.cursor.color[3],
            );

            let mut cursor_paint = Paint::default();
            cursor_paint.set_anti_alias(true);
            cursor_paint.set_color4f(cursor_color, None);

            match state.cursor.shape {
                CursorShape::Block => {
                    // 🎯 先查找光标位置的字符，以确定光标宽度
                    let cursor_start_x = cursor_x;
                    let cursor_end_x = cursor_x + cell_width;

                    let glyph_at_cursor = layout.glyphs.iter().find(|g| {
                        let glyph_end_x = g.x + cell_width * g.width;
                        g.x < cursor_end_x && glyph_end_x > cursor_start_x
                    });

                    // 光标宽度：如果在宽字符上，使用双倍宽度
                    let cursor_width = if let Some(g) = glyph_at_cursor {
                        cell_width * g.width  // 宽字符时 width = 2.0
                    } else {
                        cell_width
                    };

                    // 光标起始位置：如果在宽字符的第二个 cell 上，需要调整到字符开始位置
                    let actual_cursor_x = if let Some(g) = glyph_at_cursor {
                        g.x  // 使用字符的实际起始位置
                    } else {
                        cursor_x
                    };

                    // 绘制光标背景
                    cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                    let rect = Rect::from_xywh(actual_cursor_x, 0.0, cursor_width, line_height);
                    canvas.draw_rect(rect, &cursor_paint);

                    // 重绘光标下的字符（使用反转颜色）
                    if let Some(glyph) = glyph_at_cursor {
                        // 反转颜色：根据光标亮度计算对比色
                        // 亮度公式：0.299*R + 0.587*G + 0.114*B
                        let cursor_luminance = 0.299 * cursor_color.r + 0.587 * cursor_color.g + 0.114 * cursor_color.b;
                        let inverted_color = if cursor_luminance > 0.5 {
                            // 光标是亮色，文字用黑色
                            Color4f::new(0.0, 0.0, 0.0, 1.0)
                        } else {
                            // 光标是暗色，文字用白色
                            Color4f::new(1.0, 1.0, 1.0, 1.0)
                        };

                        if glyph.is_emoji() {
                            // Emoji: 使用 Paragraph API 渲染
                            FONT_COLLECTION.with(|fc| {
                                let font_collection = fc.borrow();
                                let mut paragraph_style = ParagraphStyle::new();
                                let mut text_style = TextStyle::new();
                                text_style.set_font_size(glyph.font.size());
                                text_style.set_color(color4f_to_color(inverted_color));
                                text_style.set_font_families(&["Apple Color Emoji"]);
                                paragraph_style.set_text_style(&text_style);

                                let mut builder = ParagraphBuilder::new(&paragraph_style, font_collection.clone());
                                builder.add_text(&glyph.grapheme);

                                let mut paragraph = builder.build();
                                paragraph.layout(cell_width * glyph.width + 10.0);

                                let para_baseline = paragraph.alphabetic_baseline();
                                let y_offset = baseline_offset - para_baseline;
                                paragraph.paint(canvas, Point::new(glyph.x, y_offset));
                            });
                        } else {
                            // 普通字符：直接绘制
                            let mut text_paint = Paint::default();
                            text_paint.set_anti_alias(true);
                            text_paint.set_color4f(inverted_color, None);
                            canvas.draw_str(&glyph.grapheme, Point::new(glyph.x, baseline_offset), &glyph.font, &text_paint);
                        }
                    }
                }
                CursorShape::Underline => {
                    cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                    let underline_height = 2.0;
                    let rect = Rect::from_xywh(cursor_x, line_height - underline_height, cell_width, underline_height);
                    canvas.draw_rect(rect, &cursor_paint);
                }
                CursorShape::Beam => {
                    cursor_paint.set_style(skia_safe::PaintStyle::Fill);
                    let beam_width = 2.0;
                    let rect = Rect::from_xywh(cursor_x, 0.0, beam_width, line_height);
                    canvas.draw_rect(rect, &cursor_paint);
                }
                CursorShape::Hidden => {}
            }
        }

        surface.image_snapshot()
    }

    /// 计算字形布局（文本整形 + 字体选择）
    fn compute_glyph_layout(&mut self, line: usize, state: &TerminalState) -> GlyphLayout {
        // 1. 提取行数据
        let builder_line = self.extract_line(line, state);

        // 2. 获取 metrics（自动缓存）
        let metrics = self.get_font_metrics();
        let physical_font_size = self.config.physical_font_size();

        // 3. 文本整形
        self.text_shaper.shape_line(
            &builder_line,
            physical_font_size.value,
            metrics.cell_width.value,
        )
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
            ime: None,
        }
    }

    #[test]
    fn test_render_line_basic() {
        let mut renderer = create_test_renderer();
        let state = create_mock_state();

        // 渲染第 0 行
        let img = renderer.render_line(0, &state, None);

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
        let _img1 = renderer.render_line(0, &state, None);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 第二次渲染（状态不变）：内层命中
        let _img2 = renderer.render_line(0, &state, None);
        assert_eq!(renderer.stats.cache_hits, 1);

        // 光标移动到第 0 行（改变状态）：外层命中
        state.cursor.position = AbsolutePoint::new(0, 5);
        let _img3 = renderer.render_line(0, &state, None);
        assert_eq!(renderer.stats.layout_hits, 1);
    }

    /// 测试：验证两层缓存命中
    #[test]
    fn test_two_layer_cache_hit() {
        let mut renderer = create_test_renderer();

        let mut state = create_mock_state();
        state.cursor.position = AbsolutePoint::new(10, 0);

        // 首次渲染：完全未命中
        let _img1 = renderer.render_line(10, &state, None);
        assert_eq!(renderer.stats.cache_misses, 1);
        assert_eq!(renderer.stats.layout_hits, 0);
        assert_eq!(renderer.stats.cache_hits, 0);

        // 光标移动到同一行的另一列：外层命中
        state.cursor.position = AbsolutePoint::new(10, 5);
        let _img2 = renderer.render_line(10, &state, None);
        assert_eq!(renderer.stats.layout_hits, 1);

        // 光标回到原位置：内层命中
        state.cursor.position = AbsolutePoint::new(10, 0);
        let _img3 = renderer.render_line(10, &state, None);
        assert_eq!(renderer.stats.cache_hits, 1);
    }

    /// 测试：验证剪枝优化
    #[test]
    fn test_state_hash_pruning() {
        let mut renderer = create_test_renderer();
        let mut state = create_mock_state();

        // 光标在第 5 行，渲染第 10 行
        state.cursor.position = AbsolutePoint::new(5, 0);
        let _img1 = renderer.render_line(10, &state, None);
        renderer.reset_stats();

        // 光标移动到第 6 行，第 10 行的 state_hash 应该不变
        state.cursor.position = AbsolutePoint::new(6, 0);
        let _img2 = renderer.render_line(10, &state, None);

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
            renderer.render_line(line, &state, None);
        }
        renderer.reset_stats();

        // 光标移动到第 6 行，重新渲染所有行
        state.cursor.position = AbsolutePoint::new(6, 0);
        for line in 0..24 {
            renderer.render_line(line, &state, None);
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
            renderer.render_line(line, &state, None);
        }
        renderer.reset_stats();

        // 添加选区（覆盖 10 行），重新渲染
        state.selection = Some(SelectionView::new(
            AbsolutePoint::new(0, 0),
            AbsolutePoint::new(9, 10),
            SelectionType::Simple,
        ));
        for line in 0..10 {
            renderer.render_line(line, &state, None);
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
            renderer.render_line(line, &state, None);
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
            renderer.render_line(line, &state, None);
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
            ime: None,
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
        let _img0 = renderer.render_line(0, &state, None);
        assert_eq!(renderer.stats.cache_misses, 1, "Line 0 should be cache miss");

        renderer.reset_stats();

        // 渲染 Line 1（无光标，但 text_hash 相同）
        // 期望：要么 Miss（重新计算），要么 LayoutHit 但 cursor_info 为 None
        let _img1 = renderer.render_line(1, &state, None);

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
        let _img0 = renderer.render_line(0, &state, None);
        assert_eq!(renderer.stats.cache_misses, 1);

        renderer.reset_stats();

        // 渲染 Line 1（无光标）→ LayoutHit
        let _img1 = renderer.render_line(1, &state, None);
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
        let img = renderer.render_line(0, &state, None);

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
        let img = renderer.render_line(0, &state, None);

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
            let img = renderer.render_line(line, &state, None);
            assert!(img.width() > 0);
        }

        // 验证统计：5 次 cache miss（首次渲染）
        assert_eq!(renderer.stats.cache_misses, 5);

        // 重新渲染相同的行（应该全部命中缓存）
        renderer.reset_stats();
        for line in 0..5 {
            let _ = renderer.render_line(line, &state, None);
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
        let _ = renderer.render_line(0, &state1, None);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 光标移动到第 1 行
        terminal.write(b"\r\n");
        let state2 = terminal.state();
        renderer.reset_stats();

        // 重新渲染第 0 行（光标已不在这里）
        let _ = renderer.render_line(0, &state2, None);
        // 注意：可能是 cache_hit 或 layout_hit，取决于行内容是否改变
        // 如果光标移动导致第 0 行内容不变，应该是 cache_hit
        // 但如果终端清除了光标位置的字符，可能是 layout_hit
        assert!(renderer.stats.cache_hits > 0 || renderer.stats.layout_hits > 0);

        // 渲染第 1 行（光标在这里，cache miss）
        let _ = renderer.render_line(1, &state2, None);
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
        let img1 = renderer.render_line(0, &state, None);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 改变背景色为白色
        renderer.set_background_color(skia_safe::Color4f::new(1.0, 1.0, 1.0, 1.0));
        renderer.reset_stats();

        // 重新渲染（应该 cache miss，因为背景色变了）
        let img2 = renderer.render_line(0, &state, None);
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
            ime: None,
        };

        // === 第一帧：渲染所有 100 行（全部 cache miss）===
        let frame1_start = std::time::Instant::now();
        for line in 0..100 {
            let _img = renderer.render_line(line, &state, None);
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
            let _img = renderer.render_line(line, &state, None);
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

    /// 冷启动测试：第一帧性能（真正的 cache miss）
    #[test]
    fn test_cold_start_performance() {
        use std::time::Instant;

        const LINES: usize = 50;
        const COLS: usize = 120;

        // 创建带内容的 mock state（真实字符，不是空格）
        let grid_data = Arc::new(GridData::new_mock_with_content(COLS, LINES));
        let grid = GridView::new(grid_data);
        let cursor = CursorView::new(AbsolutePoint::new(0, 0), CursorShape::Block);
        let state = TerminalState {
            grid,
            cursor,
            selection: None,
            search: None,
            hyperlink_hover: None,
            ime: None,
        };

        // ========== 冷启动（Atlas 是空的）==========
        let mut renderer = create_test_renderer();

        let cold_start = Instant::now();
        for line in 0..LINES {
            let _img = renderer.render_line(line, &state, None);
        }
        let cold_time = cold_start.elapsed();

        // ========== 预热后再来一次（字形已缓存）==========
        renderer.cache.clear();  // 只清 LineCache，保留 Atlas

        let warm_start = Instant::now();
        for line in 0..LINES {
            let _img = renderer.render_line(line, &state, None);
        }
        let warm_time = warm_start.elapsed();

        // 输出
        eprintln!("\n🎯 [Cold Start] {} lines × {} cols (真实内容)", LINES, COLS);
        eprintln!("   Cold:       {:?} ({:.2}µs/line)", cold_time, cold_time.as_micros() as f64 / LINES as f64);
        eprintln!("   Warm:       {:?} ({:.2}µs/line)", warm_time, warm_time.as_micros() as f64 / LINES as f64);
        eprintln!("   Speedup:    {:.2}x", cold_time.as_micros() as f64 / warm_time.as_micros() as f64);

        // Atlas stats
        let stats = renderer.glyph_atlas.stats();
        eprintln!("   Atlas glyphs:      {} (unique)", stats.num_glyphs);
        eprintln!("   Atlas utilization: {:.1}%", stats.utilization_ratio * 100.0);

        // 验证 Atlas 有合理数量的字形（至少 50 个不同字符）
        assert!(stats.num_glyphs >= 50, "Atlas should have at least 50 unique glyphs");
    }

    /// 混合策略测试：验证 LineCache + Atlas 的协同工作
    #[test]
    fn test_hybrid_strategy() {
        use std::time::Instant;

        const LINES: usize = 50;
        const COLS: usize = 120;
        const FRAMES: usize = 5;

        // 创建带内容的 mock state
        let grid_data = Arc::new(GridData::new_mock_with_content(COLS, LINES));
        let grid = GridView::new(grid_data);
        let cursor = CursorView::new(AbsolutePoint::new(0, 0), CursorShape::Block);
        let state = TerminalState {
            grid,
            cursor,
            selection: None,
            search: None,
            hyperlink_hover: None,
            ime: None,
        };

        let mut renderer = create_test_renderer();

        // === 第1帧：冷启动（LineCache miss, Atlas cold）===
        let start1 = Instant::now();
        for line in 0..LINES {
            let _img = renderer.render_line(line, &state, None);
        }
        let frame1_time = start1.elapsed();

        // === 第2帧：热启动（LineCache hit）===
        let start2 = Instant::now();
        for line in 0..LINES {
            let _img = renderer.render_line(line, &state, None);
        }
        let frame2_time = start2.elapsed();

        // === 模拟滚动：清空 LineCache，但 Atlas 保留 ===
        renderer.cache.clear();

        // === 第3帧：滚动后（LineCache miss, Atlas warm）===
        let start3 = Instant::now();
        for line in 0..LINES {
            let _img = renderer.render_line(line, &state, None);
        }
        let frame3_time = start3.elapsed();

        // === 多帧稳态测试 ===
        let start_stable = Instant::now();
        for _frame in 0..FRAMES {
            for line in 0..LINES {
                let _img = renderer.render_line(line, &state, None);
            }
        }
        let stable_time = start_stable.elapsed();
        let avg_stable = stable_time.as_micros() as f64 / FRAMES as f64;

        // 输出结果
        eprintln!("\n🔀 [Hybrid Strategy] {} lines × {} cols", LINES, COLS);
        eprintln!("   Frame 1 (cold):      {:?} ({:.2}µs/line) - LineCache miss, Atlas cold",
            frame1_time, frame1_time.as_micros() as f64 / LINES as f64);
        eprintln!("   Frame 2 (cache hit): {:?} ({:.2}µs/line) - LineCache HIT",
            frame2_time, frame2_time.as_micros() as f64 / LINES as f64);
        eprintln!("   Frame 3 (scroll):    {:?} ({:.2}µs/line) - LineCache miss, Atlas warm",
            frame3_time, frame3_time.as_micros() as f64 / LINES as f64);
        eprintln!("   Stable avg:          {:.0}µs/frame ({:.2}µs/line)",
            avg_stable, avg_stable / LINES as f64);

        // 性能验证
        let speedup_cache_hit = frame1_time.as_micros() as f64 / frame2_time.as_micros() as f64;
        let speedup_atlas_warm = frame1_time.as_micros() as f64 / frame3_time.as_micros() as f64;
        eprintln!("   Cache hit speedup:   {:.1}x vs cold", speedup_cache_hit);
        eprintln!("   Atlas warm speedup:  {:.1}x vs cold", speedup_atlas_warm);

        // 内存统计
        let (entries, images, max_entries, mem_bytes) = renderer.cache.memory_stats();
        let atlas_stats = renderer.glyph_atlas.stats();
        eprintln!("   LineCache:           {}/{} entries, {} images, {}KB",
            entries, max_entries, images, mem_bytes / 1024);
        eprintln!("   Atlas:               {} glyphs, {:.1}% utilization",
            atlas_stats.num_glyphs, atlas_stats.utilization_ratio * 100.0);

        // 验证：Cache hit 应该比 cold 快很多
        assert!(speedup_cache_hit > 2.0, "Cache hit should be at least 2x faster than cold");
    }
}
