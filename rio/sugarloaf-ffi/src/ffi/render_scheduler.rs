//! RenderScheduler FFI - 渲染调度器（CVDisplayLink）
//!
//! 新架构：Rust 侧完成整个渲染循环
//! - Swift 只负责设置布局（terminal_pool_set_render_layout）
//! - Rust 在 VSync 时自动调用 pool.render_all()

use crate::app::RenderScheduler;
use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;


/// RenderScheduler 句柄（不透明指针）
#[repr(C)]
pub struct RenderSchedulerHandle {
    _private: [u8; 0],
}

/// 渲染布局信息（兼容旧接口）
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RenderLayout {
    pub terminal_id: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// 创建 RenderScheduler
#[no_mangle]
pub extern "C" fn render_scheduler_create() -> *mut RenderSchedulerHandle {
    let scheduler = RenderScheduler::new();
    Box::into_raw(Box::new(scheduler)) as *mut RenderSchedulerHandle
}

/// 销毁 RenderScheduler
#[no_mangle]
pub extern "C" fn render_scheduler_destroy(handle: *mut RenderSchedulerHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        let _ = Box::from_raw(handle as *mut RenderScheduler);
    }
}

/// 绑定到 TerminalPool（新架构）
///
/// 绑定后：
/// - RenderScheduler 和 TerminalPool 共享 needs_render 标记
/// - RenderScheduler 在 VSync 时直接调用 pool.render_all()
/// - 无需 Swift 参与渲染循环
#[no_mangle]
pub extern "C" fn render_scheduler_bind_to_pool(
    scheduler_handle: *mut RenderSchedulerHandle,
    pool_handle: *mut TerminalPoolHandle,
) {
    if scheduler_handle.is_null() || pool_handle.is_null() {
        return;
    }

    let scheduler = unsafe { &mut *(scheduler_handle as *mut RenderScheduler) };
    let pool = unsafe { &mut *(pool_handle as *mut TerminalPool) };

    // 共享 needs_render 标记
    scheduler.bind_needs_render(pool.needs_render_flag());

    // 设置渲染回调：直接调用 pool.render_all()
    // 使用 usize 传递指针，绕过 Send + Sync 检查
    // Safety: pool 的生命周期由 Swift 管理，保证在 RenderScheduler 生命周期内有效
    let pool_addr = pool_handle as usize;
    scheduler.set_render_callback(move || {
        let pool = unsafe { &mut *(pool_addr as *mut TerminalPool) };
        pool.render_all();
    });
}

/// 启动 RenderScheduler（启动 CVDisplayLink）
#[no_mangle]
pub extern "C" fn render_scheduler_start(handle: *mut RenderSchedulerHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let scheduler = unsafe { &mut *(handle as *mut RenderScheduler) };
    scheduler.start()
}

/// 停止 RenderScheduler
#[no_mangle]
pub extern "C" fn render_scheduler_stop(handle: *mut RenderSchedulerHandle) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &mut *(handle as *mut RenderScheduler) };
    scheduler.stop();
}

/// 请求渲染（标记 dirty）
#[no_mangle]
pub extern "C" fn render_scheduler_request_render(handle: *mut RenderSchedulerHandle) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &*(handle as *const RenderScheduler) };
    scheduler.request_render();
}
