//! GlyphAtlas - 字形纹理图集
//!
//! 所有终端共享的字形缓存，替代原有的 LineCache 渲染缓存。
//! 每个唯一字形只光栅化一次，显著降低内存占用。

use std::collections::HashMap;
use skia_safe::{surfaces, Surface, Image, Color, ImageInfo, ColorType, AlphaType};

// ============================================================================
// GlyphKey - 字形键（针对终端场景简化）
// ============================================================================

/// 字形键
///
/// 用于唯一标识一个字形的渲染结果。
/// 针对等宽终端场景简化，不包含 subpixel positioning。
#[derive(Hash, Eq, PartialEq, Clone, Copy, Debug)]
pub struct GlyphKey {
    /// 字形 ID（grapheme 的完整 hash，避免冲突）
    pub glyph_id: u64,
    /// 字体索引（支持多字体 fallback）
    pub font_index: u16,
    /// 物理尺寸（已含 DPI，量化到整数）
    pub size: u16,
    /// 字符宽度（1=单宽, 2=双宽 emoji/中文）
    pub width: u8,
    /// 样式标志：bit0=bold, bit1=italic, bit2=synthetic_bold, bit3=synthetic_italic
    pub flags: u8,
}

impl GlyphKey {
    pub const FLAG_BOLD: u8 = 0b0001;
    pub const FLAG_ITALIC: u8 = 0b0010;
    pub const FLAG_SYNTHETIC_BOLD: u8 = 0b0100;
    pub const FLAG_SYNTHETIC_ITALIC: u8 = 0b1000;

    pub fn new(glyph_id: u64, font_index: u16, size: f32, width: f32, flags: u8) -> Self {
        Self {
            glyph_id,
            font_index,
            size: (size * 10.0) as u16,  // 量化：0.1px 精度
            width: width.round() as u8,  // 1 或 2
            flags,
        }
    }

    pub fn is_bold(&self) -> bool {
        self.flags & Self::FLAG_BOLD != 0
    }

    pub fn is_italic(&self) -> bool {
        self.flags & Self::FLAG_ITALIC != 0
    }
}

// ============================================================================
// AtlasRegion - Atlas 中的区域
// ============================================================================

/// Atlas 中的区域坐标
#[derive(Clone, Copy, Debug)]
pub struct AtlasRegion {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

impl AtlasRegion {
    /// 转换为 Skia 源矩形（用于 draw_image_rect）
    pub fn to_src_rect(&self) -> skia_safe::Rect {
        skia_safe::Rect::from_xywh(
            self.x as f32,
            self.y as f32,
            self.width as f32,
            self.height as f32,
        )
    }
}

// ============================================================================
// GlyphBitmap - 字形位图数据
// ============================================================================

/// 字形位图（光栅化结果）
pub struct GlyphBitmap {
    pub width: u16,
    pub height: u16,
    pub data: Vec<u8>,
    pub row_bytes: usize,
}

impl GlyphBitmap {
    pub fn info(&self) -> ImageInfo {
        ImageInfo::new(
            (self.width as i32, self.height as i32),
            ColorType::RGBA8888,
            AlphaType::Premul,
            None,
        )
    }
}

// ============================================================================
// AtlasAllocator - Shelf-based 分配器（从 Rio 移植）
// ============================================================================

/// Atlas 分配器（shelf-based 算法）
pub struct AtlasAllocator {
    width: u16,
    height: u16,
    shelves: Vec<Shelf>,
    waste_limit: f32,
}

#[derive(Debug, Clone)]
struct Shelf {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
}

impl AtlasAllocator {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            shelves: Vec::new(),
            waste_limit: 0.1,
        }
    }

    /// 分配一个矩形区域
    pub fn allocate(&mut self, width: u16, height: u16) -> Option<(u16, u16)> {
        let padded_width = width.saturating_add(1);
        let padded_height = height.saturating_add(1);

        if padded_width > self.width {
            return None;
        }

        if let Some((shelf_idx, x, y)) = self.find_best_shelf(padded_width, padded_height) {
            let shelf = &mut self.shelves[shelf_idx];
            shelf.x += padded_width;
            shelf.width = shelf.width.saturating_sub(padded_width);
            return Some((x, y));
        }

        self.create_new_shelf(padded_width, padded_height)
    }

    fn find_best_shelf(&mut self, width: u16, height: u16) -> Option<(usize, u16, u16)> {
        let mut best_shelf = None;
        let mut best_waste = f32::INFINITY;

        for (i, shelf) in self.shelves.iter().enumerate() {
            if shelf.width >= width && shelf.height >= height {
                let waste_ratio = self.calculate_waste_ratio(shelf, height);
                let score = if shelf.height == height {
                    waste_ratio - 1.0
                } else {
                    waste_ratio
                };

                if score < best_waste && waste_ratio <= self.waste_limit {
                    best_waste = score;
                    best_shelf = Some((i, shelf.x, shelf.y));
                }
            }
        }

        best_shelf
    }

    fn calculate_waste_ratio(&self, shelf: &Shelf, height: u16) -> f32 {
        if shelf.height == 0 {
            return f32::INFINITY;
        }
        let wasted = shelf.height.saturating_sub(height) as f32;
        wasted / shelf.height as f32
    }

    fn create_new_shelf(&mut self, width: u16, height: u16) -> Option<(u16, u16)> {
        let y = self.find_next_y();

        if y.saturating_add(height) > self.height {
            return None;
        }

        let shelf = Shelf {
            x: width,
            y,
            width: self.width.saturating_sub(width),
            height,
        };

        self.shelves.push(shelf);
        Some((0, y))
    }

    fn find_next_y(&self) -> u16 {
        self.shelves
            .iter()
            .map(|s| s.y.saturating_add(s.height))
            .max()
            .unwrap_or(0)
    }

    pub fn clear(&mut self) {
        self.shelves.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.shelves.is_empty()
    }

    /// 获取利用率统计
    pub fn utilization(&self) -> AtlasStats {
        let total_area = (self.width as u32) * (self.height as u32);
        let used_height = self.find_next_y() as u32;
        let used_area = (self.width as u32) * used_height;

        AtlasStats {
            total_area,
            used_area,
            utilization_ratio: if total_area > 0 {
                used_area as f32 / total_area as f32
            } else {
                0.0
            },
            num_shelves: self.shelves.len(),
            num_glyphs: 0,  // 由 GlyphAtlas 填充
        }
    }
}

/// Atlas 统计信息
#[derive(Debug)]
pub struct AtlasStats {
    pub total_area: u32,
    pub used_area: u32,
    pub utilization_ratio: f32,
    pub num_shelves: usize,
    pub num_glyphs: usize,
}

// ============================================================================
// GlyphAtlas - 字形图集
// ============================================================================

/// 字形图集（所有终端共享）
pub struct GlyphAtlas {
    /// Atlas Surface（CPU 光栅化）
    surface: Surface,
    /// 缓存的 Image snapshot
    cached_image: Option<Image>,
    /// 是否需要更新 snapshot
    dirty: bool,
    /// 分配器
    allocator: AtlasAllocator,
    /// 字形位置映射
    glyph_map: HashMap<GlyphKey, AtlasRegion>,
}

impl GlyphAtlas {
    /// Atlas 尺寸（2048×2048 RGBA = 16MB）
    pub const ATLAS_SIZE: i32 = 2048;

    pub fn new() -> Self {
        let surface = surfaces::raster_n32_premul((Self::ATLAS_SIZE, Self::ATLAS_SIZE))
            .expect("Failed to create atlas surface");

        Self {
            surface,
            cached_image: None,
            dirty: true,
            allocator: AtlasAllocator::new(Self::ATLAS_SIZE as u16, Self::ATLAS_SIZE as u16),
            glyph_map: HashMap::new(),
        }
    }

    /// 获取 Atlas Image（dirty flag 机制）
    pub fn get_image(&mut self) -> &Image {
        if self.dirty || self.cached_image.is_none() {
            self.cached_image = Some(self.surface.image_snapshot());
            self.dirty = false;
        }
        self.cached_image.as_ref().unwrap()
    }

    /// 查询字形是否已缓存
    pub fn get(&self, key: &GlyphKey) -> Option<AtlasRegion> {
        self.glyph_map.get(key).copied()
    }

    /// 获取或光栅化字形
    ///
    /// 如果字形已缓存，直接返回区域。
    /// 否则调用 `rasterize` 闭包生成位图，写入 Atlas。
    pub fn get_or_rasterize<F>(&mut self, key: GlyphKey, rasterize: F) -> Option<AtlasRegion>
    where
        F: FnOnce() -> Option<GlyphBitmap>,
    {
        // 缓存命中
        if let Some(region) = self.glyph_map.get(&key) {
            return Some(*region);
        }

        // 光栅化字形
        let bitmap = rasterize()?;

        // 零尺寸字形（空格等）
        if bitmap.width == 0 || bitmap.height == 0 {
            let region = AtlasRegion { x: 0, y: 0, width: 0, height: 0 };
            self.glyph_map.insert(key, region);
            return Some(region);
        }

        // 分配空间
        let (x, y) = match self.allocator.allocate(bitmap.width, bitmap.height) {
            Some(pos) => pos,
            None => {
                // Atlas 满了，清空重建
                crate::rust_log_info!(
                    "[GlyphAtlas] Atlas full ({} glyphs), clearing...",
                    self.glyph_map.len()
                );
                self.clear();
                self.allocator.allocate(bitmap.width, bitmap.height)?
            }
        };

        // 写入 Atlas Surface
        let info = bitmap.info();
        let success = self.surface.canvas().write_pixels(
            &info,
            &bitmap.data,
            bitmap.row_bytes,
            (x as i32, y as i32),
        );

        if !success {
            crate::rust_log_info!("[GlyphAtlas] Failed to write pixels at ({}, {})", x, y);
            return None;
        }

        self.dirty = true;

        let region = AtlasRegion {
            x,
            y,
            width: bitmap.width,
            height: bitmap.height,
        };
        self.glyph_map.insert(key, region);

        Some(region)
    }

    /// 清空 Atlas
    pub fn clear(&mut self) {
        self.glyph_map.clear();
        self.allocator.clear();
        self.surface.canvas().clear(Color::TRANSPARENT);
        self.cached_image = None;
        self.dirty = true;
    }

    /// 获取统计信息
    pub fn stats(&self) -> AtlasStats {
        let mut stats = self.allocator.utilization();
        stats.num_glyphs = self.glyph_map.len();
        stats
    }

    /// 字形数量
    pub fn glyph_count(&self) -> usize {
        self.glyph_map.len()
    }

    /// 内存占用（字节）
    pub fn memory_bytes(&self) -> usize {
        // Surface: 2048 * 2048 * 4 = 16MB
        // HashMap overhead: ~100 bytes per entry
        let surface_bytes = (Self::ATLAS_SIZE * Self::ATLAS_SIZE * 4) as usize;
        let map_bytes = self.glyph_map.len() * 100;
        surface_bytes + map_bytes
    }
}

impl Default for GlyphAtlas {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_glyph_key() {
        // GlyphKey::new(glyph_id, font_index, size, width, flags)
        let key1 = GlyphKey::new(65, 0, 14.0, 1.0, GlyphKey::FLAG_BOLD);
        let key2 = GlyphKey::new(65, 0, 14.0, 1.0, GlyphKey::FLAG_BOLD);
        let key3 = GlyphKey::new(65, 0, 14.0, 1.0, 0);

        assert_eq!(key1, key2);
        assert_ne!(key1, key3);
        assert!(key1.is_bold());
        assert!(!key1.is_italic());
    }

    #[test]
    fn test_atlas_allocator_basic() {
        let mut alloc = AtlasAllocator::new(100, 100);

        let pos1 = alloc.allocate(10, 10);
        assert_eq!(pos1, Some((0, 0)));

        let pos2 = alloc.allocate(10, 10);
        assert_eq!(pos2, Some((11, 0)));  // +1 padding
    }

    #[test]
    fn test_atlas_allocator_new_shelf() {
        let mut alloc = AtlasAllocator::new(100, 100);

        alloc.allocate(50, 10);
        let pos = alloc.allocate(60, 10);  // 不适合当前 shelf
        assert_eq!(pos, Some((0, 11)));    // 新 shelf
    }

    #[test]
    fn test_atlas_allocator_full() {
        let mut alloc = AtlasAllocator::new(20, 20);

        let pos1 = alloc.allocate(19, 19);
        assert_eq!(pos1, Some((0, 0)));

        let pos2 = alloc.allocate(1, 1);
        assert_eq!(pos2, None);  // 满了
    }

    #[test]
    fn test_atlas_allocator_clear() {
        let mut alloc = AtlasAllocator::new(100, 100);

        alloc.allocate(10, 10);
        assert!(!alloc.is_empty());

        alloc.clear();
        assert!(alloc.is_empty());

        let pos = alloc.allocate(10, 10);
        assert_eq!(pos, Some((0, 0)));
    }

    #[test]
    fn test_glyph_atlas_new() {
        let atlas = GlyphAtlas::new();
        assert_eq!(atlas.glyph_count(), 0);
        assert!(atlas.memory_bytes() > 0);
    }

    #[test]
    fn test_glyph_atlas_get_or_rasterize() {
        let mut atlas = GlyphAtlas::new();

        let key = GlyphKey::new(65, 0, 14.0, 1.0, 0);

        // 第一次：调用 rasterize
        let mut called = false;
        let region1 = atlas.get_or_rasterize(key, || {
            called = true;
            Some(GlyphBitmap {
                width: 10,
                height: 20,
                data: vec![0u8; 10 * 20 * 4],
                row_bytes: 10 * 4,
            })
        });

        assert!(called);
        assert!(region1.is_some());
        let r1 = region1.unwrap();
        assert_eq!(r1.x, 0);
        assert_eq!(r1.y, 0);
        assert_eq!(r1.width, 10);
        assert_eq!(r1.height, 20);

        // 第二次：缓存命中
        called = false;
        let region2 = atlas.get_or_rasterize(key, || {
            called = true;
            None
        });

        assert!(!called);  // 不应调用
        assert!(region2.is_some());
    }

    #[test]
    fn test_glyph_atlas_stats() {
        let mut atlas = GlyphAtlas::new();

        let key = GlyphKey::new(65, 0, 14.0, 1.0, 0);
        atlas.get_or_rasterize(key, || {
            Some(GlyphBitmap {
                width: 10,
                height: 20,
                data: vec![0u8; 10 * 20 * 4],
                row_bytes: 10 * 4,
            })
        });

        let stats = atlas.stats();
        assert_eq!(stats.num_glyphs, 1);
        assert!(stats.utilization_ratio > 0.0);
    }
}
