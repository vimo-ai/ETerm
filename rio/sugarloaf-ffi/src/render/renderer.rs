use crate::domain::TerminalState;
use super::cache::{LineCache, GlyphLayout, MockImage, CacheResult};
use super::hash::{compute_text_hash, compute_state_hash_for_line};

/// 渲染引擎（管理缓存 + 渲染流程）
pub struct Renderer {
    cache: LineCache,
    /// 统计信息（用于测试验证）
    pub stats: RenderStats,
    /// Mock: 用于生成唯一 image id
    next_image_id: usize,
}

/// 渲染统计（用于验证缓存行为）
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RenderStats {
    pub cache_hits: usize,      // 内层缓存命中次数
    pub layout_hits: usize,     // 外层缓存命中次数
    pub cache_misses: usize,    // 完全未命中次数
}

impl Renderer {
    pub fn new() -> Self {
        Self {
            cache: LineCache::new(),
            stats: RenderStats::default(),
            next_image_id: 0,
        }
    }

    /// 渲染一行（核心逻辑：三级缓存查询）
    pub fn render_line(&mut self, line: usize, state: &TerminalState) -> MockImage {
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

    /// Mock: 计算字形布局（Phase 3 替换为真实字体处理）
    fn compute_glyph_layout(&self, line: usize, state: &TerminalState) -> GlyphLayout {
        let content_hash = compute_text_hash(line, state);
        GlyphLayout { content_hash }
    }

    /// Mock: 基于布局绘制（Phase 3 替换为真实绘制）
    fn render_with_layout(&mut self, _layout: GlyphLayout, _line: usize, _state: &TerminalState) -> MockImage {
        let id = self.next_image_id;
        self.next_image_id += 1;
        MockImage { id }
    }

    /// 重置统计信息
    pub fn reset_stats(&mut self) {
        self.stats = RenderStats::default();
    }
}

impl Default for Renderer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AbsolutePoint, GridView, GridData, CursorView, SelectionView, SelectionType, SearchView, MatchRange};
    use rio_backend::ansi::CursorShape;
    use std::sync::Arc;

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
        let mut renderer = Renderer::new();
        let state = create_mock_state();

        // 渲染第 0 行
        let img = renderer.render_line(0, &state);

        // 验证返回了图像
        assert_eq!(img.id, 0);

        // 验证统计信息
        assert_eq!(renderer.stats.cache_misses, 1);
        assert_eq!(renderer.stats.layout_hits, 0);
        assert_eq!(renderer.stats.cache_hits, 0);
    }

    #[test]
    fn test_three_level_cache() {
        let mut renderer = Renderer::new();
        let mut state = create_mock_state();

        // 第一次渲染：完全未命中
        let img1 = renderer.render_line(0, &state);
        assert_eq!(img1.id, 0);
        assert_eq!(renderer.stats.cache_misses, 1);

        // 第二次渲染（状态不变）：内层命中
        let img2 = renderer.render_line(0, &state);
        assert_eq!(img2.id, 0); // 同一个图像
        assert_eq!(renderer.stats.cache_hits, 1);

        // 光标移动到第 0 行（改变状态）：外层命中
        state.cursor.position = AbsolutePoint::new(0, 5);
        let img3 = renderer.render_line(0, &state);
        assert_eq!(img3.id, 1); // 新图像
        assert_eq!(renderer.stats.layout_hits, 1);
    }

    /// 测试：验证两层缓存命中
    #[test]
    fn test_two_layer_cache_hit() {
        let mut renderer = Renderer::new();

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
        let mut renderer = Renderer::new();
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
        let mut renderer = Renderer::new();
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
        let mut renderer = Renderer::new();
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
        let mut renderer = Renderer::new();
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
        let mut renderer = Renderer::new();
        let state = create_mock_state();

        renderer.render_line(0, &state);
        assert_eq!(renderer.stats.cache_misses, 1);

        renderer.reset_stats();
        assert_eq!(renderer.stats.cache_misses, 0);
        assert_eq!(renderer.stats.cache_hits, 0);
        assert_eq!(renderer.stats.layout_hits, 0);
    }
}
