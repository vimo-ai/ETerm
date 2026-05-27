pub mod line_cache;
pub mod hash;

pub use render_core::{GlyphAtlas, GlyphKey, AtlasRegion, GlyphBitmap, AtlasStats, GlyphLayout};

pub use line_cache::{LineCache, LineCacheEntry, CacheResult, CursorInfo, SelectionInfo, SearchMatchInfo, HyperlinkHoverInfo};
pub use hash::{compute_text_hash, compute_state_hash_for_line};
