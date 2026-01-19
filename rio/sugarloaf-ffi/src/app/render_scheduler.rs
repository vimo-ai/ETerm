//! RenderScheduler - 渲染调度器
//!
//! 职责：
//! - 持有 DisplayLink（VSync 驱动）
//! - 在 VSync 时检查 needs_render，如果需要则调用渲染回调
//!
//! 架构变更：
//! - 旧：DisplayLink → callback → Swift render() → FFI × N
//! - 新：DisplayLink → Rust render_all()（通过回调，无 Swift 参与）

use crate::display_link::DisplayLink;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// 渲染回调类型（在 Rust 侧完成整个渲染）
pub type RenderAllCallback = Box<dyn Fn() + Send + Sync>;

/// 渲染调度器
///
/// 在 Rust 侧完成整个渲染循环，Swift 只负责布局同步
pub struct RenderScheduler {
    /// DisplayLink 实例
    display_link: Option<DisplayLink>,

    /// 是否需要渲染（与 TerminalPool 共享）
    needs_render: Arc<AtomicBool>,

    /// 渲染回调（调用 pool.render_all()）
    render_callback: Arc<Mutex<Option<RenderAllCallback>>>,
}

impl Default for RenderScheduler {
    fn default() -> Self {
        Self::new()
    }
}

impl RenderScheduler {
    /// 创建渲染调度器
    pub fn new() -> Self {
        Self {
            display_link: None,
            needs_render: Arc::new(AtomicBool::new(false)),
            render_callback: Arc::new(Mutex::new(None)),
        }
    }

    /// 设置渲染回调
    ///
    /// 回调应该调用 pool.render_all() 完成整个渲染循环
    pub fn set_render_callback<F>(&self, callback: F)
    where
        F: Fn() + Send + Sync + 'static,
    {
        let mut cb = self.render_callback.lock();
        *cb = Some(Box::new(callback));
    }

    /// 启动 DisplayLink
    pub fn start(&mut self) -> bool {
        if self.display_link.is_some() {
            return true;
        }

        let needs_render = self.needs_render.clone();
        let render_callback = self.render_callback.clone();

        let display_link = DisplayLink::new(move || {
            // 检查是否需要渲染（最小化空闲开销）
            if !needs_render.swap(false, Ordering::AcqRel) {
                return;
            }

            // 调用渲染回调（在 Rust 侧完成整个渲染）
            let cb_guard = render_callback.lock();
            if let Some(ref callback) = *cb_guard {
                callback();
            }
        });

        match display_link {
            Some(dl) => {
                if dl.start() {
                    self.display_link = Some(dl);
                    true
                } else {
                    crate::rust_log_error!("[RenderLoop] ❌ Failed to start DisplayLink");
                    false
                }
            }
            None => {
                crate::rust_log_error!("[RenderLoop] ❌ Failed to create DisplayLink");
                false
            }
        }
    }

    /// 停止 DisplayLink
    pub fn stop(&mut self) {
        if let Some(ref dl) = self.display_link {
            dl.stop();
        }
        self.display_link = None;
    }

    /// 请求渲染
    #[inline]
    pub fn request_render(&self) {
        self.needs_render.store(true, Ordering::Release);
    }

    /// 获取 needs_render 的 Arc 引用
    pub fn needs_render_flag(&self) -> Arc<AtomicBool> {
        self.needs_render.clone()
    }

    /// 绑定到 TerminalPool 的 needs_render
    ///
    /// 让 RenderScheduler 和 TerminalPool 共享同一个 needs_render 标记
    pub fn bind_needs_render(&mut self, flag: Arc<AtomicBool>) {
        self.needs_render = flag;
    }
}

impl Drop for RenderScheduler {
    fn drop(&mut self) {
        self.stop();
    }
}
