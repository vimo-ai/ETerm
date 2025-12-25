//! Cache Subsystem - 缓存子系统
//!
//! - **line_cache** - LineCache 布局缓存
//! - **glyph_atlas** - GlyphAtlas 字形图集（共享）
//! - **hash** - Hash 计算

pub mod line_cache;
pub mod glyph_atlas;
pub mod hash;

pub use line_cache::{LineCache, LineCacheEntry, CacheResult, GlyphLayout, CursorInfo, SelectionInfo, SearchMatchInfo, HyperlinkHoverInfo};
pub use glyph_atlas::{GlyphAtlas, GlyphKey, AtlasRegion, GlyphBitmap, AtlasStats};
pub use hash::{compute_text_hash, compute_state_hash_for_line};
