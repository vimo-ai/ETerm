//! RenderScheduler FFI - 渲染调度器（CVDisplayLink）

use crate::app::RenderScheduler;
use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;
use std::ffi::c_void;

/// RenderScheduler 句柄（不透明指针）
#[repr(C)]
pub struct RenderSchedulerHandle {
    _private: [u8; 0],
}

/// 渲染布局信息
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RenderLayout {
    pub terminal_id: usize,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// 渲染回调类型
///
/// 在 VSync 时触发，Swift 侧应该在回调中执行渲染：
/// - terminal_pool_begin_frame
/// - terminal_pool_render_terminal (for each layout item)
/// - terminal_pool_end_frame
pub type RenderSchedulerCallback = extern "C" fn(
    context: *mut c_void,
    layout: *const RenderLayout,
    layout_count: usize,
);

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

/// 设置渲染回调
///
/// 回调在 CVDisplayLink VSync 时触发
#[no_mangle]
pub extern "C" fn render_scheduler_set_callback(
    handle: *mut RenderSchedulerHandle,
    callback: RenderSchedulerCallback,
    context: *mut c_void,
) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &*(handle as *const RenderScheduler) };

    // 包装 C 回调为 Rust 闭包
    // 注意：context 需要是 Send + Sync（Swift 侧保证）
    let context_ptr = context as usize; // 转成 usize 来满足 Send + Sync
    scheduler.set_render_callback(move |layout: &[(usize, f32, f32, f32, f32)]| {
        // 转换布局格式
        let layouts: Vec<RenderLayout> = layout
            .iter()
            .map(|&(terminal_id, x, y, width, height)| RenderLayout {
                terminal_id,
                x,
                y,
                width,
                height,
            })
            .collect();

        // 调用 C 回调
        callback(context_ptr as *mut c_void, layouts.as_ptr(), layouts.len());
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

/// 设置渲染布局
///
/// 布局信息会在下次 VSync 回调时传给回调函数
#[no_mangle]
pub extern "C" fn render_scheduler_set_layout(
    handle: *mut RenderSchedulerHandle,
    layout: *const RenderLayout,
    count: usize,
) {
    if handle.is_null() {
        return;
    }

    let scheduler = unsafe { &*(handle as *const RenderScheduler) };

    let layouts = if layout.is_null() || count == 0 {
        Vec::new()
    } else {
        let slice = unsafe { std::slice::from_raw_parts(layout, count) };
        slice
            .iter()
            .map(|l| (l.terminal_id, l.x, l.y, l.width, l.height))
            .collect()
    };

    scheduler.set_layout(layouts);
}

/// 绑定到 TerminalPool 的 needs_render 标记
///
/// 让 RenderScheduler 和 TerminalPool 共享同一个 dirty 标记
#[no_mangle]
pub extern "C" fn render_scheduler_bind_to_pool(
    scheduler_handle: *mut RenderSchedulerHandle,
    pool_handle: *mut TerminalPoolHandle,
) {
    if scheduler_handle.is_null() || pool_handle.is_null() {
        return;
    }

    let scheduler = unsafe { &mut *(scheduler_handle as *mut RenderScheduler) };
    let pool = unsafe { &*(pool_handle as *const TerminalPool) };

    scheduler.bind_needs_render(pool.needs_render_flag());
}
