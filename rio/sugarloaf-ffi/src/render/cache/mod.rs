//! Cache Subsystem - 缓存子系统
//!
//! 两层 Hash 缓存架构：
//! - **line_cache** - LineCache 两层缓存结构
//! - **hash** - Hash 计算（text_hash, state_hash）


pub mod line_cache;


pub mod hash;


pub use line_cache::{LineCache, LineCacheEntry, CacheResult, GlyphLayout, CursorInfo, SelectionInfo, SearchMatchInfo, HyperlinkHoverInfo};


pub use hash::{compute_text_hash, compute_state_hash_for_line};
