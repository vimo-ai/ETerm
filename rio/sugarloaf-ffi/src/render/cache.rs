use std::collections::HashMap;

/// 两层缓存
pub struct LineCache {
    cache: HashMap<u64, LineCacheEntry>,
}

/// 缓存条目（每个文本内容一个）
pub struct LineCacheEntry {
    /// 外层：文本布局（字体选择 + 整形结果）
    pub layout: GlyphLayout,
    /// 内层：不同状态组合的最终渲染
    pub renders: HashMap<u64, MockImage>,
}

/// 字形布局（Mock 版本，Phase 3 替换为真实数据）
#[derive(Debug, Clone)]
pub struct GlyphLayout {
    pub content_hash: u64,
}

/// Mock 图像（占位符）
#[derive(Debug, Clone, PartialEq)]
pub struct MockImage {
    pub id: usize,
}

/// 缓存查询结果
pub enum CacheResult {
    /// 内层命中：直接返回最终渲染
    FullHit(MockImage),
    /// 外层命中：返回布局，需要重新绘制状态
    LayoutHit(GlyphLayout),
    /// 完全未命中：需要完整渲染
    Miss,
}

impl LineCache {
    pub fn new() -> Self {
        Self {
            cache: HashMap::new(),
        }
    }

    /// 两层查询
    pub fn get(&self, text_hash: u64, state_hash: u64) -> CacheResult {
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

    /// 两层插入
    pub fn insert(
        &mut self,
        text_hash: u64,
        state_hash: u64,
        layout: GlyphLayout,
        image: MockImage,
    ) {
        let entry = self.cache.entry(text_hash).or_insert_with(|| {
            LineCacheEntry {
                layout: layout.clone(),
                renders: HashMap::new(),
            }
        });

        // 更新布局（可能相同，但为了简化逻辑总是更新）
        entry.layout = layout;
        // 插入内层缓存
        entry.renders.insert(state_hash, image);
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

    #[test]
    fn test_cache_insert_and_get() {
        let mut cache = LineCache::new();

        let text_hash = 123;
        let state_hash = 456;
        let layout = GlyphLayout { content_hash: text_hash };
        let image = MockImage { id: 1 };

        // 插入缓存
        cache.insert(text_hash, state_hash, layout.clone(), image.clone());

        // 查询应该完全命中
        match cache.get(text_hash, state_hash) {
            CacheResult::FullHit(img) => {
                assert_eq!(img, image);
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

        let layout = GlyphLayout { content_hash: text_hash };
        let image_1 = MockImage { id: 1 };
        let image_2 = MockImage { id: 2 };

        // 插入两个不同状态的渲染
        cache.insert(text_hash, state_hash_1, layout.clone(), image_1.clone());
        cache.insert(text_hash, state_hash_2, layout.clone(), image_2.clone());

        // 查询第一个状态：完全命中
        match cache.get(text_hash, state_hash_1) {
            CacheResult::FullHit(img) => assert_eq!(img.id, 1),
            _ => panic!("Expected FullHit for state_hash_1"),
        }

        // 查询第二个状态：完全命中
        match cache.get(text_hash, state_hash_2) {
            CacheResult::FullHit(img) => assert_eq!(img.id, 2),
            _ => panic!("Expected FullHit for state_hash_2"),
        }

        // 查询新状态：外层命中
        let state_hash_3 = 400;
        match cache.get(text_hash, state_hash_3) {
            CacheResult::LayoutHit(l) => {
                assert_eq!(l.content_hash, text_hash);
            }
            _ => panic!("Expected LayoutHit for state_hash_3"),
        }
    }

    #[test]
    fn test_cache_miss() {
        let cache = LineCache::new();

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

        let layout_1 = GlyphLayout { content_hash: text_hash_1 };
        let layout_2 = GlyphLayout { content_hash: text_hash_2 };
        let image_1 = MockImage { id: 1 };
        let image_2 = MockImage { id: 2 };

        cache.insert(text_hash_1, state_hash, layout_1, image_1.clone());
        cache.insert(text_hash_2, state_hash, layout_2, image_2.clone());

        // 两个不同的文本内容应该独立缓存
        match cache.get(text_hash_1, state_hash) {
            CacheResult::FullHit(img) => assert_eq!(img.id, 1),
            _ => panic!("Expected FullHit for text_hash_1"),
        }

        match cache.get(text_hash_2, state_hash) {
            CacheResult::FullHit(img) => assert_eq!(img.id, 2),
            _ => panic!("Expected FullHit for text_hash_2"),
        }
    }
}
