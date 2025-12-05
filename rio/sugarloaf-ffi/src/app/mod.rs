//! Application Layer - 应用层
//!
//! 职责：协调 Terminal Domain + Render Domain，提供高层 API
//!
//! 架构：
//! - **terminal_app** - 单终端应用（旧接口，兼容）
//! - **terminal_pool** - 多终端池（新接口，推荐）
//! - **ffi** - FFI 类型定义

#[cfg(feature = "new_architecture")]
pub mod terminal_app;

#[cfg(feature = "new_architecture")]
pub mod terminal_pool;

#[cfg(feature = "new_architecture")]
pub mod ffi;

#[cfg(feature = "new_architecture")]
pub use terminal_app::TerminalApp;

#[cfg(feature = "new_architecture")]
pub use terminal_pool::TerminalPool;

#[cfg(feature = "new_architecture")]
pub use ffi::{
    AppConfig, ErrorCode, FontMetrics, GridPoint, TerminalEvent, TerminalEventType,
};
