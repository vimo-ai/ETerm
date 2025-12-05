//! Cache Subsystem - 缓存子系统
//!
//! 两层 Hash 缓存架构：
//! - **line_cache** - LineCache 两层缓存结构
//! - **hash** - Hash 计算（text_hash, state_hash）

#[cfg(feature = "new_architecture")]
pub mod line_cache;

#[cfg(feature = "new_architecture")]
pub mod hash;

#[cfg(feature = "new_architecture")]
pub use line_cache::{LineCache, LineCacheEntry, CacheResult, GlyphLayout, CursorInfo};

#[cfg(feature = "new_architecture")]
pub use hash::{compute_text_hash, compute_state_hash_for_line};
