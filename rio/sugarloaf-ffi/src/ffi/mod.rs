//! FFI 模块 - 提供 C ABI 兼容的 FFI 接口
//!
//! 本模块将 FFI 函数按功能拆分为多个子模块：
//! - terminal_pool: 终端池管理
//! - cursor: 光标相关
//! - selection: 选区相关
//! - render_scheduler: 渲染调度器
//! - word_boundary: 分词相关
//! - ime: 输入法预编辑相关

use std::panic::{catch_unwind, AssertUnwindSafe};

pub mod terminal_pool;
pub mod cursor;
pub mod selection;
pub mod render_scheduler;
pub mod word_boundary;
pub mod hyperlink;
pub mod keyboard;
pub mod ime;

/// FFI 边界防护 - 捕获所有 panic，防止跨 FFI 边界传播
///
/// Rust 的 panic 跨 FFI 边界是未定义行为，必须在边界处捕获。
/// 此函数提供统一的 panic 捕获机制，确保 FFI 调用的安全性。
///
/// # 参数
/// - `default`: panic 时返回的默认值
/// - `f`: 要执行的闘数
///
/// # 示例
/// ```ignore
/// #[no_mangle]
/// pub extern "C" fn some_ffi_function() -> bool {
///     ffi_boundary(false, || {
///         // 业务逻辑，即使 panic 也不会崩溃
///         true
///     })
/// }
/// ```
#[inline]
pub fn ffi_boundary<T, F>(default: T, f: F) -> T
where
    F: FnOnce() -> T,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(panic_info) => {
            // 记录 panic 信息（可选：后续可接入日志系统）
            let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic".to_string()
            };
            eprintln!("[FFI panic captured] {}", msg);
            default
        }
    }
}

// Re-export 所有 FFI 函数和类型，保持外部可见性
pub use terminal_pool::*;
pub use cursor::*;
pub use selection::*;
pub use render_scheduler::*;
pub use word_boundary::*;
pub use hyperlink::*;
pub use keyboard::*;
pub use ime::*;
