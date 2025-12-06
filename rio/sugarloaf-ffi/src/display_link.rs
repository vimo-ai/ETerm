//! Rust 绑定 macOS CVDisplayLink
//!
//! CVDisplayLink 是 macOS 的帧同步 API，回调在 VSync 时触发。
//! 用于替代 Swift 侧的 CVDisplayLink，让渲染调度完全在 Rust 侧完成。

// 保持与 Apple CoreVideo API 文档一致的命名风格
#![allow(non_upper_case_globals)]
#![allow(non_snake_case)]

use std::ffi::c_void;

// ============================================================================
// CVDisplayLink C API 类型和函数声明
// ============================================================================

#[repr(C)]
pub struct __CVDisplayLink {
    _private: [u8; 0],
}

pub type CVDisplayLinkRef = *mut __CVDisplayLink;
pub type CVReturn = i32;

pub const kCVReturnSuccess: CVReturn = 0;

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    fn CVDisplayLinkCreateWithActiveCGDisplays(displayLinkOut: *mut CVDisplayLinkRef) -> CVReturn;
    fn CVDisplayLinkSetOutputCallback(
        displayLink: CVDisplayLinkRef,
        callback: Option<
            extern "C" fn(
                displayLink: CVDisplayLinkRef,
                inNow: *const c_void,
                inOutputTime: *const c_void,
                flagsIn: u64,
                flagsOut: *mut u64,
                displayLinkContext: *mut c_void,
            ) -> CVReturn,
        >,
        userInfo: *mut c_void,
    ) -> CVReturn;
    fn CVDisplayLinkStart(displayLink: CVDisplayLinkRef) -> CVReturn;
    fn CVDisplayLinkStop(displayLink: CVDisplayLinkRef) -> CVReturn;
    fn CVDisplayLinkRelease(displayLink: CVDisplayLinkRef);
}

// ============================================================================
// DisplayLink 封装
// ============================================================================

/// 回调上下文，存储用户回调
struct CallbackContext {
    /// 用户提供的回调函数
    callback: Box<dyn Fn() + Send + Sync>,
}

/// CVDisplayLink 的 Rust 封装
///
/// # 使用方式
/// ```ignore
/// let display_link = DisplayLink::new(|| {
///     // VSync 回调，每帧都会调用
///     // 由调用方决定是否真正渲染
///     if should_render() {
///         render();
///     }
/// });
/// display_link.start();
/// // ...
/// display_link.stop();
/// ```
///
/// 注意：DisplayLink 不做 dirty 检查，每次 VSync 都会调用回调。
/// 调用方（如 RenderScheduler）负责检查是否需要渲染。
pub struct DisplayLink {
    link: CVDisplayLinkRef,
    context: *mut CallbackContext,
}

// Safety: DisplayLink 内部的 CVDisplayLinkRef 是线程安全的
// CallbackContext 的 callback 是 Send + Sync 的
unsafe impl Send for DisplayLink {}
unsafe impl Sync for DisplayLink {}

impl DisplayLink {
    /// 创建新的 DisplayLink
    ///
    /// # 参数
    /// - `callback`: VSync 回调函数，在需要渲染时调用
    ///
    /// # 返回
    /// - `Some(DisplayLink)` - 成功
    /// - `None` - 创建失败
    pub fn new<F>(callback: F) -> Option<Self>
    where
        F: Fn() + Send + Sync + 'static,
    {
        let mut link: CVDisplayLinkRef = std::ptr::null_mut();

        // 创建 CVDisplayLink
        let result = unsafe { CVDisplayLinkCreateWithActiveCGDisplays(&mut link) };
        if result != kCVReturnSuccess || link.is_null() {
            eprintln!("❌ [DisplayLink] Failed to create CVDisplayLink: {}", result);
            return None;
        }

        // 创建回调上下文
        let context = Box::new(CallbackContext {
            callback: Box::new(callback),
        });
        let context_ptr = Box::into_raw(context);

        // 设置回调
        let result = unsafe {
            CVDisplayLinkSetOutputCallback(link, Some(Self::display_link_callback), context_ptr as *mut c_void)
        };
        if result != kCVReturnSuccess {
            eprintln!("❌ [DisplayLink] Failed to set callback: {}", result);
            unsafe {
                drop(Box::from_raw(context_ptr));
                CVDisplayLinkRelease(link);
            }
            return None;
        }

        Some(Self {
            link,
            context: context_ptr,
        })
    }

    /// 启动 DisplayLink
    pub fn start(&self) -> bool {
        let result = unsafe { CVDisplayLinkStart(self.link) };
        result == kCVReturnSuccess
    }

    /// 停止 DisplayLink
    pub fn stop(&self) -> bool {
        let result = unsafe { CVDisplayLinkStop(self.link) };
        result == kCVReturnSuccess
    }

    /// 请求渲染（兼容接口，实际不做任何事）
    ///
    /// DisplayLink 每帧都会调用回调，由调用方自己判断是否需要渲染
    #[inline]
    pub fn request_render(&self) {
        // 不做任何事，dirty 检查由 RenderScheduler 负责
    }

    /// CVDisplayLink 回调函数
    ///
    /// 在 VSync 时被 macOS 调用（注意：在非主线程）
    /// 每帧都会调用，由回调内部决定是否真正渲染
    extern "C" fn display_link_callback(
        _display_link: CVDisplayLinkRef,
        _in_now: *const c_void,
        _in_output_time: *const c_void,
        _flags_in: u64,
        _flags_out: *mut u64,
        display_link_context: *mut c_void,
    ) -> CVReturn {
        if display_link_context.is_null() {
            return kCVReturnSuccess;
        }

        let context = unsafe { &*(display_link_context as *const CallbackContext) };

        // 每帧都调用回调，由回调内部决定是否渲染
        (context.callback)();

        kCVReturnSuccess
    }
}

impl Drop for DisplayLink {
    fn drop(&mut self) {
        // 停止
        unsafe { CVDisplayLinkStop(self.link) };

        // 释放 CVDisplayLink
        unsafe { CVDisplayLinkRelease(self.link) };

        // 释放回调上下文
        if !self.context.is_null() {
            unsafe { drop(Box::from_raw(self.context)) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn test_display_link_creation() {
        let call_count = Arc::new(AtomicUsize::new(0));
        let call_count_clone = call_count.clone();

        let display_link = DisplayLink::new(move || {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        });

        assert!(display_link.is_some());
    }

    #[test]
    fn test_display_link_start_stop() {
        let display_link = DisplayLink::new(|| {}).unwrap();

        assert!(display_link.start());
        thread::sleep(Duration::from_millis(100));
        assert!(display_link.stop());
    }

    #[test]
    fn test_display_link_request_render() {
        let call_count = Arc::new(AtomicUsize::new(0));
        let call_count_clone = call_count.clone();

        let display_link = DisplayLink::new(move || {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        })
        .unwrap();

        display_link.start();

        // 请求渲染
        display_link.request_render();
        thread::sleep(Duration::from_millis(50));

        display_link.stop();

        // 应该至少调用了一次
        assert!(call_count.load(Ordering::SeqCst) >= 1);
    }
}
