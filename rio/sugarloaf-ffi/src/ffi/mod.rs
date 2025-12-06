//! FFI 模块 - 提供 C ABI 兼容的 FFI 接口
//!
//! 本模块将 FFI 函数按功能拆分为多个子模块：
//! - terminal_pool: 终端池管理
//! - cursor: 光标相关
//! - selection: 选区相关
//! - render_scheduler: 渲染调度器
//! - word_boundary: 分词相关

pub mod terminal_pool;
pub mod cursor;
pub mod selection;
pub mod render_scheduler;
pub mod word_boundary;

// Re-export 所有 FFI 函数和类型，保持外部可见性
pub use terminal_pool::*;
pub use cursor::*;
pub use selection::*;
pub use render_scheduler::*;
pub use word_boundary::*;
