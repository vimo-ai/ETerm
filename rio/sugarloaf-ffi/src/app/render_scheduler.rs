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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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

    /// 调试统计：VSync 回调计数
    callback_count: Arc<AtomicU64>,
    /// 调试统计：实际渲染计数
    render_count: Arc<AtomicU64>,
    /// 调试统计：上次日志输出时间（秒）
    last_log_time: Arc<AtomicU64>,
}

impl RenderScheduler {
    /// 创建渲染调度器
    pub fn new() -> Self {
        Self {
            display_link: None,
            needs_render: Arc::new(AtomicBool::new(false)),
            render_callback: Arc::new(Mutex::new(None)),
            callback_count: Arc::new(AtomicU64::new(0)),
            render_count: Arc::new(AtomicU64::new(0)),
            last_log_time: Arc::new(AtomicU64::new(0)),
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
        let callback_count = self.callback_count.clone();
        let render_count = self.render_count.clone();
        let last_log_time = self.last_log_time.clone();

        // 首次回调标志（用于输出启动日志）
        let first_callback = Arc::new(AtomicBool::new(true));
        let first_callback_clone = first_callback.clone();

        let display_link = DisplayLink::new(move || {
            // 统计 VSync 回调次数
            let cb_cnt = callback_count.fetch_add(1, Ordering::Relaxed) + 1;

            // 首次回调时输出日志
            if first_callback_clone.swap(false, Ordering::Relaxed) {
                crate::rust_log_info!("[RenderLoop] 🎬 First CVDisplayLink callback received");
            }

            // 获取当前时间（秒）
            let now_secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);

            // 检查是否需要渲染
            let should_render = needs_render.swap(false, Ordering::AcqRel);
            if !should_render {
                // 检测长时间无渲染（每 5 秒检查一次）
                let last_secs = last_log_time.load(Ordering::Relaxed);
                if now_secs >= last_secs + 5 {
                    last_log_time.store(now_secs, Ordering::Relaxed);
                    let rnd_cnt = render_count.load(Ordering::Relaxed);
                    // 如果 5 秒内 rendered=0，输出警告（Release 也输出）
                    if rnd_cnt == 0 || cb_cnt > 0 && (rnd_cnt as f64 / cb_cnt as f64) < 0.001 {
                        crate::rust_log_warn!(
                            "[RenderLoop] ⚠️ Low render rate: vsync={}, rendered={}, ratio={:.3}%",
                            cb_cnt, rnd_cnt, (rnd_cnt as f64 / cb_cnt.max(1) as f64) * 100.0
                        );
                    }
                }
                return;
            }

            // 统计实际渲染次数
            let rnd_cnt = render_count.fetch_add(1, Ordering::Relaxed) + 1;

            // 每 5 秒输出一次统计日志（仅 Debug）
            #[cfg(debug_assertions)]
            {
                let last_secs = last_log_time.load(Ordering::Relaxed);
                if now_secs >= last_secs + 5 {
                    last_log_time.store(now_secs, Ordering::Relaxed);
                    crate::rust_log_info!("[RenderLoop] stats: vsync={}, rendered={}, ratio={:.1}%",
                        cb_cnt, rnd_cnt, (rnd_cnt as f64 / cb_cnt as f64) * 100.0);
                }
            }
            #[cfg(not(debug_assertions))]
            let _ = &last_log_time;

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
