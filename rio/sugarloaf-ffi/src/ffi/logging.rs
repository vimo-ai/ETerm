//! 日志桥接 FFI 模块
//!
//! 将 Rust 端的关键日志转发到 Swift 端，让日志能够被持久化到文件中。
//!
//! # 架构
//! - Rust 端通过全局回调将日志消息发送到 Swift
//! - Swift 端使用 LogManager 将日志写入文件
//! - 如果回调未设置，fallback 到 eprintln!
//!
//! # 使用方式
//! ```ignore
//! // Swift 端设置回调
//! set_rust_log_callback(my_callback);
//!
//! // Rust 端记录日志
//! rust_log_warn!("[RenderLoop] ⚠️ terminal {} not found", terminal_id);
//! rust_log_error!("[RenderLoop] ❌ Failed to create DisplayLink");
//! ```

use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicPtr, Ordering};

// ============================================================================
// 日志级别定义
// ============================================================================

/// 日志级别（与 Swift LogLevel 对应）
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RustLogLevel {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

// ============================================================================
// 回调类型定义
// ============================================================================

/// 日志回调函数类型
///
/// Swift 端需要实现此回调并通过 set_rust_log_callback 设置
///
/// # 参数
/// - level: 日志级别
/// - message: 日志消息（UTF-8 C 字符串）
///
/// # 线程安全
/// 回调可能从多个线程调用，Swift 端需要保证线程安全
pub type LogCallback = extern "C" fn(level: RustLogLevel, message: *const c_char);

// ============================================================================
// 全局回调存储
// ============================================================================

/// 全局日志回调（原子指针，线程安全）
static LOG_CALLBACK: AtomicPtr<()> = AtomicPtr::new(std::ptr::null_mut());

// ============================================================================
// FFI 函数
// ============================================================================

/// 设置日志回调
///
/// Swift 端应该在 App 启动时调用此函数设置回调
///
/// # 参数
/// - callback: 日志回调函数
///
/// # 示例（Swift）
/// ```swift
/// let callback: @convention(c) (RustLogLevel, UnsafePointer<CChar>?) -> Void = { level, message in
///     guard let message = message else { return }
///     let text = String(cString: message)
///
///     switch level {
///     case 2: // Warn
///         LogManager.shared.warn(text)
///     case 3: // Error
///         LogManager.shared.error(text)
///     default:
///         break
///     }
/// }
/// set_rust_log_callback(callback)
/// ```
#[no_mangle]
pub extern "C" fn set_rust_log_callback(callback: LogCallback) {
    LOG_CALLBACK.store(callback as *mut (), Ordering::SeqCst);
}

/// 清除日志回调
///
/// 通常不需要调用，除非需要显式禁用回调
#[no_mangle]
pub extern "C" fn clear_rust_log_callback() {
    LOG_CALLBACK.store(std::ptr::null_mut(), Ordering::SeqCst);
}

// ============================================================================
// 核心日志函数
// ============================================================================

/// 发送日志消息
///
/// 如果回调已设置，通过回调发送到 Swift 端
/// 如果回调未设置，fallback 到 eprintln!
///
/// # 参数
/// - level: 日志级别
/// - message: 日志消息
///
/// # 线程安全
/// 此函数是线程安全的，可以从任何线程调用
pub fn log_message(level: RustLogLevel, message: &str) {
    let callback = LOG_CALLBACK.load(Ordering::SeqCst);

    if !callback.is_null() {
        // 回调已设置，发送到 Swift
        if let Ok(c_string) = CString::new(message) {
            let callback: LogCallback = unsafe { std::mem::transmute(callback) };
            callback(level, c_string.as_ptr());
        } else {
            // CString 转换失败（字符串中包含 null 字符），fallback 到 eprintln
            eprintln!("{}", message);
        }
    } else {
        // 回调未设置，fallback 到 eprintln
        eprintln!("{}", message);
    }
}

// ============================================================================
// 便捷宏
// ============================================================================

/// Debug 日志宏
///
/// # 示例
/// ```ignore
/// rust_log_debug!("[RenderLoop] callback count: {}", count);
/// ```
#[macro_export]
macro_rules! rust_log_debug {
    ($($arg:tt)*) => {
        $crate::ffi::logging::log_message(
            $crate::ffi::logging::RustLogLevel::Debug,
            &format!($($arg)*)
        )
    };
}

/// Info 日志宏
///
/// # 示例
/// ```ignore
/// rust_log_info!("[RenderLoop] DisplayLink started");
/// ```
#[macro_export]
macro_rules! rust_log_info {
    ($($arg:tt)*) => {
        $crate::ffi::logging::log_message(
            $crate::ffi::logging::RustLogLevel::Info,
            &format!($($arg)*)
        )
    };
}

/// Warn 日志宏（最常用）
///
/// # 示例
/// ```ignore
/// rust_log_warn!("[RenderLoop] ⚠️ terminal {} not found", terminal_id);
/// ```
#[macro_export]
macro_rules! rust_log_warn {
    ($($arg:tt)*) => {
        $crate::ffi::logging::log_message(
            $crate::ffi::logging::RustLogLevel::Warn,
            &format!($($arg)*)
        )
    };
}

/// Error 日志宏（最常用）
///
/// # 示例
/// ```ignore
/// rust_log_error!("[RenderLoop] ❌ Failed to create DisplayLink: {}", result);
/// ```
#[macro_export]
macro_rules! rust_log_error {
    ($($arg:tt)*) => {
        $crate::ffi::logging::log_message(
            $crate::ffi::logging::RustLogLevel::Error,
            &format!($($arg)*)
        )
    };
}

// ============================================================================
// 测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn test_fallback_to_eprintln() {
        // 未设置回调时，应该 fallback 到 eprintln（不会 panic）
        log_message(RustLogLevel::Warn, "test message");
    }

    #[test]
    fn test_callback_invocation() {
        // 记录回调调用
        static mut LAST_LEVEL: Option<RustLogLevel> = None;
        static mut LAST_MESSAGE: Option<String> = None;

        extern "C" fn test_callback(level: RustLogLevel, message: *const c_char) {
            unsafe {
                LAST_LEVEL = Some(level);
                if !message.is_null() {
                    use std::ffi::CStr;
                    if let Ok(s) = CStr::from_ptr(message).to_str() {
                        LAST_MESSAGE = Some(s.to_string());
                    }
                }
            }
        }

        // 设置回调
        set_rust_log_callback(test_callback);

        // 发送日志
        log_message(RustLogLevel::Error, "test error");

        // 验证
        unsafe {
            assert_eq!(LAST_LEVEL, Some(RustLogLevel::Error));
            assert_eq!(LAST_MESSAGE.as_deref(), Some("test error"));
        }

        // 清除回调
        clear_rust_log_callback();
    }

    #[test]
    fn test_macro_usage() {
        // 测试宏不会 panic
        rust_log_debug!("debug: {}", 42);
        rust_log_info!("info: {}", "test");
        rust_log_warn!("warn: {}", true);
        rust_log_error!("error: {}", 3.14);
    }
}
