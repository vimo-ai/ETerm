//! Rio 事件系统 - 照抄 rio-backend/src/event/mod.rs
//!
//! 这个模块实现了与 Rio 完全一致的事件系统：
//! - RioEvent 枚举定义所有事件类型
//! - EventListener trait 定义事件监听接口
//! - FFI 回调实现跨语言事件传递

use std::collections::VecDeque;
use std::ffi::c_void;
use std::sync::{Arc, Mutex};

use rio_backend::crosswords::grid::Scroll;

/// Rio 事件类型 - 精简版，只保留终端嵌入需要的事件
///
/// 照抄自 rio-backend/src/event/mod.rs 的 RioEvent
#[derive(Debug, Clone)]
pub enum RioEvent {
    /// PTY 有新数据，需要检查终端更新并渲染
    /// 参数是 route_id（终端 ID）
    Wakeup(usize),

    /// 请求渲染
    Render,

    /// 光标闪烁状态改变
    CursorBlinkingChange,

    /// 光标闪烁状态改变（指定 route）
    CursorBlinkingChangeOnRoute(usize),

    /// 终端响铃
    Bell,

    /// 窗口标题改变
    Title(String),

    /// 请求写入 PTY（从终端发起的写入请求，如剪贴板响应）
    PtyWrite(String),

    /// 请求复制到剪贴板
    ClipboardStore(String),

    /// 请求从剪贴板粘贴
    ClipboardLoad,

    /// 终端退出
    Exit,

    /// 关闭指定终端
    CloseTerminal(usize),

    /// 滚动
    Scroll(Scroll),

    /// 鼠标光标需要更新（grid 内容改变）
    MouseCursorDirty,

    /// 空操作
    Noop,
}

/// FFI 事件类型 - 用于跨语言传递
///
/// 这是一个简化的 C 兼容结构，Swift 侧根据 event_type 解析
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FFIEvent {
    /// 事件类型
    /// 0 = Wakeup
    /// 1 = Render
    /// 2 = CursorBlinkingChange
    /// 3 = Bell
    /// 4 = Title (需要额外的字符串数据)
    /// 5 = PtyWrite (需要额外的字符串数据)
    /// 6 = ClipboardStore (需要额外的字符串数据)
    /// 7 = ClipboardLoad
    /// 8 = Exit
    /// 9 = CloseTerminal
    /// 10 = Scroll
    /// 11 = MouseCursorDirty
    /// 12 = Noop
    pub event_type: u32,

    /// 终端/路由 ID（用于 Wakeup, CloseTerminal, CursorBlinkingChangeOnRoute）
    pub route_id: usize,

    /// 滚动行数（用于 Scroll）
    pub scroll_delta: i32,
}

impl FFIEvent {
    pub fn wakeup(route_id: usize) -> Self {
        Self {
            event_type: 0,
            route_id,
            scroll_delta: 0,
        }
    }

    pub fn render() -> Self {
        Self {
            event_type: 1,
            route_id: 0,
            scroll_delta: 0,
        }
    }

    pub fn cursor_blinking_change() -> Self {
        Self {
            event_type: 2,
            route_id: 0,
            scroll_delta: 0,
        }
    }

    pub fn cursor_blinking_change_on_route(route_id: usize) -> Self {
        Self {
            event_type: 2,
            route_id,
            scroll_delta: 0,
        }
    }

    pub fn bell() -> Self {
        Self {
            event_type: 3,
            route_id: 0,
            scroll_delta: 0,
        }
    }

    pub fn exit() -> Self {
        Self {
            event_type: 8,
            route_id: 0,
            scroll_delta: 0,
        }
    }

    pub fn close_terminal(route_id: usize) -> Self {
        Self {
            event_type: 9,
            route_id,
            scroll_delta: 0,
        }
    }

    pub fn mouse_cursor_dirty() -> Self {
        Self {
            event_type: 11,
            route_id: 0,
            scroll_delta: 0,
        }
    }

    pub fn noop() -> Self {
        Self {
            event_type: 12,
            route_id: 0,
            scroll_delta: 0,
        }
    }
}

impl From<&RioEvent> for FFIEvent {
    fn from(event: &RioEvent) -> Self {
        match event {
            RioEvent::Wakeup(route_id) => FFIEvent::wakeup(*route_id),
            RioEvent::Render => FFIEvent::render(),
            RioEvent::CursorBlinkingChange => FFIEvent::cursor_blinking_change(),
            RioEvent::CursorBlinkingChangeOnRoute(route_id) => {
                FFIEvent::cursor_blinking_change_on_route(*route_id)
            }
            RioEvent::Bell => FFIEvent::bell(),
            RioEvent::Exit => FFIEvent::exit(),
            RioEvent::CloseTerminal(route_id) => FFIEvent::close_terminal(*route_id),
            RioEvent::MouseCursorDirty => FFIEvent::mouse_cursor_dirty(),
            RioEvent::Scroll(scroll) => {
                let delta = match scroll {
                    Scroll::Delta(d) => *d,
                    Scroll::PageUp => -20,
                    Scroll::PageDown => 20,
                    Scroll::Top => i32::MIN,
                    Scroll::Bottom => i32::MAX,
                };
                FFIEvent {
                    event_type: 10,
                    route_id: 0,
                    scroll_delta: delta,
                }
            }
            // 带字符串的事件需要特殊处理，这里先返回基础类型
            RioEvent::Title(_) => FFIEvent {
                event_type: 4,
                route_id: 0,
                scroll_delta: 0,
            },
            RioEvent::PtyWrite(_) => FFIEvent {
                event_type: 5,
                route_id: 0,
                scroll_delta: 0,
            },
            RioEvent::ClipboardStore(_) => FFIEvent {
                event_type: 6,
                route_id: 0,
                scroll_delta: 0,
            },
            RioEvent::ClipboardLoad => FFIEvent {
                event_type: 7,
                route_id: 0,
                scroll_delta: 0,
            },
            RioEvent::Noop => FFIEvent::noop(),
        }
    }
}

/// 事件回调类型
pub type EventCallback = extern "C" fn(*mut c_void, FFIEvent);

/// 字符串事件回调类型（用于 Title, PtyWrite, ClipboardStore）
pub type StringEventCallback = extern "C" fn(*mut c_void, u32, *const std::ffi::c_char);

/// 事件队列 - 用于在 Rust 侧收集事件
///
/// 照抄 Rio 的设计：事件先进入队列，然后由主线程统一消费
#[derive(Clone)]
pub struct EventQueue {
    inner: Arc<Mutex<EventQueueInner>>,
}

struct EventQueueInner {
    events: VecDeque<RioEvent>,
    /// FFI 回调
    callback: Option<EventCallback>,
    /// 字符串事件回调
    string_callback: Option<StringEventCallback>,
    /// 回调上下文
    context: *mut c_void,
}

// 手动实现 Send，因为 context 是裸指针
// 调用者需要保证 context 的生命周期
unsafe impl Send for EventQueueInner {}

impl EventQueue {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(EventQueueInner {
                events: VecDeque::new(),
                callback: None,
                string_callback: None,
                context: std::ptr::null_mut(),
            })),
        }
    }

    /// 设置事件回调
    pub fn set_callback(
        &self,
        callback: EventCallback,
        string_callback: Option<StringEventCallback>,
        context: *mut c_void,
    ) {
        let mut inner = self.inner.lock().unwrap();
        inner.callback = Some(callback);
        inner.string_callback = string_callback;
        inner.context = context;
    }

    /// 发送事件
    ///
    /// 照抄 Rio 的 EventProxy::send_event
    pub fn send_event(&self, event: RioEvent) {
        eprintln!("📤 [EventQueue] send_event: {:?}", event);
        // 使用 catch_unwind 保护 FFI 回调，防止 panic 传播
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let inner = self.inner.lock().unwrap();

            // 直接调用回调，不入队列
            // 这样可以确保事件立即传递给 Swift 侧
            if let Some(callback) = inner.callback {
                eprintln!("   Callback is set, sending to Swift");
                let ffi_event = FFIEvent::from(&event);

                // 处理带字符串的事件
                match &event {
                    RioEvent::Title(s) | RioEvent::PtyWrite(s) | RioEvent::ClipboardStore(s) => {
                        if let Some(string_cb) = inner.string_callback {
                            // 安全地创建 CString，处理包含 null 字节的情况
                            let safe_str = s.replace('\0', "");
                            if let Ok(c_str) = std::ffi::CString::new(safe_str) {
                                string_cb(inner.context, ffi_event.event_type, c_str.as_ptr());
                            }
                        }
                    }
                    _ => {
                        callback(inner.context, ffi_event);
                    }
                }
            }
        }));

        if let Err(e) = result {
            eprintln!("[rio_event] Caught panic in send_event: {:?}", e);
        }
    }

    /// 入队事件（不立即发送）
    pub fn enqueue(&self, event: RioEvent) {
        let mut inner = self.inner.lock().unwrap();
        inner.events.push_back(event);
    }

    /// 取出所有事件
    pub fn drain(&self) -> Vec<RioEvent> {
        let mut inner = self.inner.lock().unwrap();
        inner.events.drain(..).collect()
    }
}

impl Default for EventQueue {
    fn default() -> Self {
        Self::new()
    }
}

/// FFI EventListener 实现
///
/// 这是我们真正使用的 EventListener，它会把事件发送给 Swift
/// 实现 rio_backend::event::EventListener，这样 Crosswords 可以直接使用
#[derive(Clone)]
pub struct FFIEventListener {
    queue: EventQueue,
    #[allow(dead_code)] // Reserved for future multi-terminal routing
    route_id: usize,
}

impl FFIEventListener {
    pub fn new(queue: EventQueue, route_id: usize) -> Self {
        Self { queue, route_id }
    }

    pub fn queue(&self) -> &EventQueue {
        &self.queue
    }

    /// 发送我们的 RioEvent
    pub fn send_event(&self, event: RioEvent) {
        self.queue.send_event(event);
    }
}

// 为 rio_backend::event::EventListener 实现 FFIEventListener
// 这样 Crosswords 就可以直接使用我们的监听器
impl rio_backend::event::EventListener for FFIEventListener {
    fn event(&self) -> (Option<rio_backend::event::RioEvent>, bool) {
        (None, false)
    }

    fn send_event(&self, event: rio_backend::event::RioEvent, _id: rio_backend::event::WindowId) {
        // 将 rio_backend 的事件转换为我们的事件
        let our_event = convert_rio_event(event.clone());

        // 对于 PtyWrite 事件，入队而不是直接发送给 Swift
        // 因为 PtyWrite 需要在 Rust 侧（RioMachine 事件循环）处理，写回 PTY
        match &our_event {
            RioEvent::PtyWrite(_) => {
                self.queue.enqueue(our_event);
            }
            _ => {
                // 其他事件直接发送给 Swift
                self.queue.send_event(our_event);
            }
        }
    }
}

/// 将 rio_backend::event::RioEvent 转换为我们的 RioEvent
fn convert_rio_event(event: rio_backend::event::RioEvent) -> RioEvent {
    use rio_backend::event::RioEvent as BackendEvent;

    match event {
        BackendEvent::Wakeup(route_id) => RioEvent::Wakeup(route_id),
        BackendEvent::Render => RioEvent::Render,
        BackendEvent::CursorBlinkingChange => RioEvent::CursorBlinkingChange,
        BackendEvent::CursorBlinkingChangeOnRoute(route_id) => {
            RioEvent::CursorBlinkingChangeOnRoute(route_id)
        }
        BackendEvent::Bell => RioEvent::Bell,
        BackendEvent::Title(s) => RioEvent::Title(s),
        BackendEvent::PtyWrite(s) => RioEvent::PtyWrite(s),
        BackendEvent::ClipboardStore(_, s) => RioEvent::ClipboardStore(s),
        BackendEvent::ClipboardLoad(_, _) => RioEvent::ClipboardLoad,
        BackendEvent::Exit => RioEvent::Exit,
        BackendEvent::CloseTerminal(route_id) => RioEvent::CloseTerminal(route_id),
        BackendEvent::Scroll(scroll) => RioEvent::Scroll(scroll),
        BackendEvent::MouseCursorDirty => RioEvent::MouseCursorDirty,
        _ => RioEvent::Noop,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_event_conversion() {
        let event = RioEvent::Wakeup(42);
        let ffi = FFIEvent::from(&event);
        assert_eq!(ffi.event_type, 0);
        assert_eq!(ffi.route_id, 42);
    }

    #[test]
    fn test_event_queue() {
        let queue = EventQueue::new();
        queue.enqueue(RioEvent::Wakeup(1));
        queue.enqueue(RioEvent::Bell);

        let events = queue.drain();
        assert_eq!(events.len(), 2);
    }
}
