use std::collections::HashMap;
use std::num::NonZeroUsize;
use lru::LruCache;

use crate::render::layout::GlyphInfo;
use rio_backend::ansi::CursorShape;

/// 外层缓存最大条目数（text_hash → LineCacheEntry）
/// 15000 条 × ~150KB ≈ 2.2GB 上限（实际会更小，因为有内层复用）
const MAX_TEXT_ENTRIES: usize = 15000;

/// 两层缓存（带 LRU 淘汰）
pub struct LineCache {
    cache: LruCache<u64, LineCacheEntry>,
}

/// 缓存条目（每个文本内容一个）
pub struct LineCacheEntry {
    /// 外层：文本布局（字体选择 + 整形结果）
    pub layout: GlyphLayout,
    /// 内层：不同状态组合的最终渲染
    pub renders: HashMap<u64, skia_safe::Image>,
}

/// 字形布局（真实版本）
///
/// 注意：只包含字体选择结果，不包含状态信息（光标、选区、搜索）
/// 状态信息在渲染时从 TerminalState 动态获取
#[derive(Debug, Clone)]
pub struct GlyphLayout {
    /// 所有字形信息（字符 + 字体 + 像素坐标）
    pub glyphs: Vec<GlyphInfo>,
}

/// 光标信息（用于渲染）
#[derive(Debug, Clone, Copy)]
pub struct CursorInfo {
    /// 光标列号
    pub col: usize,
    /// 光标形状
    pub shape: CursorShape,
    /// 光标颜色 (RGBA)
    pub color: [f32; 4],
}

/// 选区信息（用于渲染时动态覆盖背景色）
#[derive(Debug, Clone, Copy)]
pub struct SelectionInfo {
    /// 选区起始列
    pub start_col: usize,
    /// 选区结束列
    pub end_col: usize,
    /// 选区前景色 (RGBA)
    pub fg_color: [f32; 4],
    /// 选区背景色 (RGBA)
    pub bg_color: [f32; 4],
}

/// 搜索匹配信息（用于渲染时动态覆盖背景色）
#[derive(Debug, Clone)]
pub struct SearchMatchInfo {
    /// 匹配范围列表 (start_col, end_col, is_focused)
    pub ranges: Vec<(usize, usize, bool)>,
    /// 普通匹配前景色 (RGBA)
    pub fg_color: [f32; 4],
    /// 普通匹配背景色 (RGBA)
    pub bg_color: [f32; 4],
    /// 焦点匹配前景色 (RGBA)
    pub focused_fg_color: [f32; 4],
    /// 焦点匹配背景色 (RGBA)
    pub focused_bg_color: [f32; 4],
}

/// 超链接悬停信息（用于渲染时添加下划线和颜色）
#[derive(Debug, Clone, Copy)]
pub struct HyperlinkHoverInfo {
    /// 超链接起始列
    pub start_col: usize,
    /// 超链接结束列
    pub end_col: usize,
    /// 超链接前景色（通常是蓝色）
    pub fg_color: [f32; 4],
}

/// 缓存查询结果
pub enum CacheResult {
    /// 内层命中：直接返回最终渲染
    FullHit(skia_safe::Image),
    /// 外层命中：返回布局，需要重新绘制状态
    LayoutHit(GlyphLayout),
    /// 完全未命中：需要完整渲染
    Miss,
}

impl LineCache {
    pub fn new() -> Self {
        Self {
            cache: LruCache::new(NonZeroUsize::new(MAX_TEXT_ENTRIES).unwrap()),
        }
    }

    /// 两层查询（注意：会更新 LRU 顺序）
    pub fn get(&mut self, text_hash: u64, state_hash: u64) -> CacheResult {
        match self.cache.get(&text_hash) {
            Some(entry) => {
                // 外层命中，检查内层
                match entry.renders.get(&state_hash) {
                    Some(image) => CacheResult::FullHit(image.clone()),
                    None => CacheResult::LayoutHit(entry.layout.clone()),
                }
            }
            None => CacheResult::Miss,
        }
    }

    /// 两层插入（超过容量时自动淘汰最久未使用的条目）
    pub fn insert(
        &mut self,
        text_hash: u64,
        state_hash: u64,
        layout: GlyphLayout,
        image: skia_safe::Image,
    ) {
        // 先检查是否已存在
        if let Some(entry) = self.cache.get_mut(&text_hash) {
            // 更新布局和内层缓存
            entry.layout = layout;
            entry.renders.insert(state_hash, image);
        } else {
            // 新建条目（LruCache 会自动淘汰最旧的）
            let mut renders = HashMap::new();
            renders.insert(state_hash, image);
            self.cache.put(text_hash, LineCacheEntry {
                layout,
                renders,
            });
        }
    }

    /// 清空缓存（窗口 resize 时调用）
    pub fn clear(&mut self) {
        self.cache.clear();
    }

    /// 获取当前缓存条目数（用于调试）
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.cache.len()
    }
}

impl Default for LineCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skia_safe::{images, ImageInfo, ColorType, AlphaType, Image};

    /// 创建 Mock Image（用于测试）
    fn create_mock_image(width: i32, height: i32) -> Image {
        let info = ImageInfo::new(
            (width, height),
            ColorType::RGBA8888,
            AlphaType::Premul,
            None,
        );
        // 创建空的像素数据
        let row_bytes = (width * 4) as usize;
        let data_size = row_bytes * height as usize;
        let data = vec![0u8; data_size];

        images::raster_from_data(
            &info,
            skia_safe::Data::new_copy(&data),
            row_bytes,
        ).unwrap()
    }

    /// 创建 Mock Layout（用于测试）
    fn create_mock_layout(_content_hash: u64) -> GlyphLayout {
        GlyphLayout {
            glyphs: vec![],
        }
    }

    #[test]
    fn test_cache_insert_and_get() {
        let mut cache = LineCache::new();

        let text_hash = 123;
        let state_hash = 456;
        let layout = create_mock_layout(text_hash);
        let image = create_mock_image(100, 20);

        // 插入缓存
        cache.insert(text_hash, state_hash, layout.clone(), image.clone());

        // 查询应该完全命中
        match cache.get(text_hash, state_hash) {
            CacheResult::FullHit(_img) => {
                // 验证返回了图像（无法比较 Image 对象）
            }
            _ => panic!("Expected FullHit"),
        }
    }

    #[test]
    fn test_two_layer_lookup() {
        let mut cache = LineCache::new();

        let text_hash = 100;
        let state_hash_1 = 200;
        let state_hash_2 = 300;

        let layout = create_mock_layout(text_hash);
        let image_1 = create_mock_image(100, 20);
        let image_2 = create_mock_image(100, 20);

        // 插入两个不同状态的渲染
        cache.insert(text_hash, state_hash_1, layout.clone(), image_1.clone());
        cache.insert(text_hash, state_hash_2, layout.clone(), image_2.clone());

        // 查询第一个状态：完全命中
        match cache.get(text_hash, state_hash_1) {
            CacheResult::FullHit(_img) => {},
            _ => panic!("Expected FullHit for state_hash_1"),
        }

        // 查询第二个状态：完全命中
        match cache.get(text_hash, state_hash_2) {
            CacheResult::FullHit(_img) => {},
            _ => panic!("Expected FullHit for state_hash_2"),
        }

        // 查询新状态：外层命中
        let state_hash_3 = 400;
        match cache.get(text_hash, state_hash_3) {
            CacheResult::LayoutHit(_) => {
                // LayoutHit 成功
            }
            _ => panic!("Expected LayoutHit for state_hash_3"),
        }
    }

    #[test]
    fn test_cache_miss() {
        let mut cache = LineCache::new();

        // 查询空缓存
        match cache.get(999, 888) {
            CacheResult::Miss => {}
            _ => panic!("Expected Miss"),
        }
    }

    #[test]
    fn test_multiple_text_hashes() {
        let mut cache = LineCache::new();

        let text_hash_1 = 100;
        let text_hash_2 = 200;
        let state_hash = 300;

        let layout_1 = create_mock_layout(text_hash_1);
        let layout_2 = create_mock_layout(text_hash_2);
        let image_1 = create_mock_image(100, 20);
        let image_2 = create_mock_image(100, 20);

        cache.insert(text_hash_1, state_hash, layout_1, image_1.clone());
        cache.insert(text_hash_2, state_hash, layout_2, image_2.clone());

        // 两个不同的文本内容应该独立缓存
        match cache.get(text_hash_1, state_hash) {
            CacheResult::FullHit(_img) => {},
            _ => panic!("Expected FullHit for text_hash_1"),
        }

        match cache.get(text_hash_2, state_hash) {
            CacheResult::FullHit(_img) => {},
            _ => panic!("Expected FullHit for text_hash_2"),
        }
    }

    #[test]
    fn test_lru_eviction() {
        // 创建一个小容量的缓存来测试淘汰
        use std::num::NonZeroUsize;
        use lru::LruCache;

        // 直接测试 LruCache 的淘汰行为
        let mut cache: LruCache<u64, String> = LruCache::new(NonZeroUsize::new(3).unwrap());

        // 插入 3 个条目
        cache.put(1, "one".to_string());
        cache.put(2, "two".to_string());
        cache.put(3, "three".to_string());

        assert_eq!(cache.len(), 3);

        // 访问 1，使其成为最近使用
        let _ = cache.get(&1);

        // 插入第 4 个，应该淘汰最久未使用的 2
        cache.put(4, "four".to_string());

        assert_eq!(cache.len(), 3);
        assert!(cache.get(&1).is_some(), "1 should exist (recently used)");
        assert!(cache.get(&2).is_none(), "2 should be evicted (LRU)");
        assert!(cache.get(&3).is_some(), "3 should exist");
        assert!(cache.get(&4).is_some(), "4 should exist (just added)");
    }

    #[test]
    fn test_line_cache_capacity_limit() {
        let mut cache = LineCache::new();
        let state_hash = 100;

        // 插入 MAX_TEXT_ENTRIES + 100 个条目
        let total_entries = super::MAX_TEXT_ENTRIES + 100;
        for i in 0..total_entries {
            let text_hash = i as u64;
            let layout = create_mock_layout(text_hash);
            let image = create_mock_image(100, 20);
            cache.insert(text_hash, state_hash, layout, image);
        }

        // 缓存大小应该不超过 MAX_TEXT_ENTRIES
        assert!(
            cache.len() <= super::MAX_TEXT_ENTRIES,
            "Cache size {} should not exceed MAX_TEXT_ENTRIES {}",
            cache.len(),
            super::MAX_TEXT_ENTRIES
        );

        // 最近插入的应该还在
        let recent_hash = (total_entries - 1) as u64;
        match cache.get(recent_hash, state_hash) {
            CacheResult::FullHit(_) => {},
            _ => panic!("Recently inserted entry should exist"),
        }

        // 最早插入的应该被淘汰
        match cache.get(0, state_hash) {
            CacheResult::Miss => {},
            _ => panic!("Oldest entry should be evicted"),
        }
    }
}
