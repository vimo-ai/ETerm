//! Application Layer - 应用层
//!
//! 职责：协调 Terminal Domain + Render Domain，提供高层 API
//!
//! 架构：
//! - **terminal_pool** - 多终端池
//! - **render_scheduler** - 渲染调度器（协调 DisplayLink + TerminalPool）
//! - **ffi** - FFI 类型定义

pub mod terminal_pool;
pub mod render_scheduler;
pub mod ffi;

pub use terminal_pool::{TerminalPool, DetachedTerminal};
pub use render_scheduler::RenderScheduler;
pub use ffi::{
    AppConfig, ErrorCode, FontMetrics, GridPoint, TerminalEvent, TerminalEventType,
    TerminalPoolEventCallback,
};
