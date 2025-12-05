//! RenderScheduler - 渲染调度器
//!
//! DDD 职责分离：
//! - 持有 DisplayLink（基础设施层）
//! - 协调 TerminalPool 的渲染
//! - 管理渲染布局
//!
//! 不直接持有 TerminalPool，而是通过回调方式触发渲染

use crate::display_link::DisplayLink;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// 渲染回调类型
///
/// 参数：布局信息 Vec<(terminal_id, x, y, width, height)>
pub type RenderCallback = Box<dyn Fn(&[(usize, f32, f32, f32, f32)]) + Send + Sync>;

/// 渲染调度器
///
/// 负责协调 DisplayLink 和渲染逻辑，不直接依赖 TerminalPool
pub struct RenderScheduler {
    /// DisplayLink 实例
    display_link: Option<DisplayLink>,

    /// 是否需要渲染
    needs_render: Arc<AtomicBool>,

    /// 渲染布局
    render_layout: Arc<Mutex<Vec<(usize, f32, f32, f32, f32)>>>,

    /// 渲染回调（由外部设置）
    render_callback: Arc<Mutex<Option<RenderCallback>>>,
}

impl RenderScheduler {
    /// 创建渲染调度器
    pub fn new() -> Self {
        Self {
            display_link: None,
            needs_render: Arc::new(AtomicBool::new(false)),
            render_layout: Arc::new(Mutex::new(Vec::new())),
            render_callback: Arc::new(Mutex::new(None)),
        }
    }

    /// 设置渲染回调
    ///
    /// 回调在 DisplayLink VSync 时触发，参数是当前布局
    pub fn set_render_callback<F>(&self, callback: F)
    where
        F: Fn(&[(usize, f32, f32, f32, f32)]) + Send + Sync + 'static,
    {
        let mut cb = self.render_callback.lock();
        *cb = Some(Box::new(callback));
    }

    /// 启动 DisplayLink
    pub fn start(&mut self) -> bool {
        if self.display_link.is_some() {
            // eprintln!("⚠️ [RenderScheduler] DisplayLink already running");
            return true;
        }

        let needs_render = self.needs_render.clone();
        let render_layout = self.render_layout.clone();
        let render_callback = self.render_callback.clone();

        let display_link = DisplayLink::new(move || {
            // 检查是否需要渲染
            let should_render = needs_render.swap(false, Ordering::AcqRel);
            if !should_render {
                return;
            }

            // eprintln!("🔄 [RenderScheduler] VSync: needs_render=true, calling callback");

            // 获取布局
            let layout = {
                let layout_guard = render_layout.lock();
                layout_guard.clone()
            };

            // eprintln!("🔄 [RenderScheduler] Layout count: {}", layout.len());

            // 即使 layout 为空也调用回调（让 Swift 侧处理）
            // if layout.is_empty() {
            //     return;
            // }

            // 调用渲染回调
            let cb_guard = render_callback.lock();
            if let Some(ref callback) = *cb_guard {
                // eprintln!("🔄 [RenderScheduler] Calling render callback");
                callback(&layout);
            } else {
                // eprintln!("⚠️ [RenderScheduler] No render callback set");
            }
        });

        match display_link {
            Some(dl) => {
                if dl.start() {
                    self.display_link = Some(dl);
                    // eprintln!("✅ [RenderScheduler] Started");
                    true
                } else {
                    eprintln!("❌ [RenderScheduler] Failed to start DisplayLink");
                    false
                }
            }
            None => {
                eprintln!("❌ [RenderScheduler] Failed to create DisplayLink");
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
        // eprintln!("⏹️ [RenderScheduler] Stopped");
    }

    /// 请求渲染
    #[inline]
    pub fn request_render(&self) {
        // eprintln!("🎯 [RenderScheduler] request_render() called");
        self.needs_render.store(true, Ordering::Release);
        if let Some(ref dl) = self.display_link {
            dl.request_render();
        }
    }

    /// 设置渲染布局
    pub fn set_layout(&self, layout: Vec<(usize, f32, f32, f32, f32)>) {
        let mut render_layout = self.render_layout.lock();
        *render_layout = layout;
    }

    /// 获取 needs_render 的 Arc 引用
    ///
    /// 可用于与 TerminalPool 的 needs_render 共享
    pub fn needs_render_flag(&self) -> Arc<AtomicBool> {
        self.needs_render.clone()
    }

    /// 绑定到 TerminalPool 的 needs_render
    ///
    /// 让 RenderScheduler 和 TerminalPool 共享同一个 needs_render 标记
    pub fn bind_needs_render(&mut self, flag: Arc<AtomicBool>) {
        // eprintln!("🔗 [RenderScheduler] bind_needs_render() - binding to TerminalPool's flag");
        self.needs_render = flag;
    }
}

impl Drop for RenderScheduler {
    fn drop(&mut self) {
        self.stop();
    }
}
