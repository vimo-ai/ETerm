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


pub mod renderer;


pub mod context;


pub mod cache;


pub mod config;


pub mod layout;


pub mod font;


pub mod rasterizer;


pub mod box_drawing;

// Re-exports for convenience

pub use renderer::{Renderer, RenderStats};


pub use context::RenderContext;


pub use cache::{LineCache, CacheResult};


pub use config::{RenderConfig, FontMetrics};
