//! Render Domain - 渲染领域
//!
//! 职责：将 TerminalState 转换为可显示的 Frame
//!
//! 架构：
//! - **renderer** - 渲染引擎（协调者）
//! - **context** - 渲染上下文（坐标转换）
//! - **cache** - 缓存子系统（两层 Hash 缓存）
//!
//! 核心创新：两层 Hash 缓存
//! - 外层 Hash：text_hash → GlyphLayout（跳过字体选择+文本整形，70% 性能提升）
//! - 内层 Hash：state_hash → MockImage（零开销，0% 耗时）
//! - 剪枝优化：state_hash 只包含影响本行的状态参数

#[cfg(feature = "new_architecture")]
pub mod renderer;

#[cfg(feature = "new_architecture")]
pub mod context;

#[cfg(feature = "new_architecture")]
pub mod cache;

#[cfg(feature = "new_architecture")]
pub mod config;

#[cfg(feature = "new_architecture")]
pub mod layout;

#[cfg(feature = "new_architecture")]
pub mod font;

#[cfg(feature = "new_architecture")]
pub mod rasterizer;

#[cfg(feature = "new_architecture")]
pub mod box_drawing;

// Re-exports for convenience
#[cfg(feature = "new_architecture")]
pub use renderer::{Renderer, RenderStats};

#[cfg(feature = "new_architecture")]
pub use context::RenderContext;

#[cfg(feature = "new_architecture")]
pub use cache::{LineCache, CacheResult};

#[cfg(feature = "new_architecture")]
pub use config::{RenderConfig, FontMetrics};
