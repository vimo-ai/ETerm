//! TerminalStore - 终端状态管理（纯状态，无渲染）
//!
//! 职责：
//! - 管理所有 Terminal 实例的生命周期
//! - 处理 PTY 输入/输出
//! - 终端状态查询（CWD、进程等）
//! - 不涉及渲染

use crate::domain::aggregates::{Terminal, TerminalId, TerminalMode};
use crate::rio_event::{EventQueue, FFIEventListener};
use crate::rio_machine::Machine;
use corcovado::channel;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::JoinHandle;
use std::ffi::c_void;

use super::ffi::{TerminalEvent, TerminalEventType, TerminalPoolEventCallback};

/// 单个终端条目
pub struct TerminalEntry {
    /// Terminal 聚合根
    pub terminal: Arc<Mutex<Terminal>>,

    /// PTY 输入通道
    pub pty_tx: channel::Sender<rio_backend::event::Msg>,

    /// Machine 线程句柄
    #[allow(dead_code)]
    pub machine_handle: JoinHandle<(Machine<teletypewriter::Pty>, crate::rio_machine::State)>,

    /// 终端尺寸
    pub cols: u16,
    pub rows: u16,

    /// PTY 文件描述符（用于获取 CWD）
    pub pty_fd: i32,

    /// Shell 进程 ID（用于获取 CWD）
    pub shell_pid: u32,
}

/// 终端存储
///
/// 全局单例，管理所有终端实例
/// 可被多个 RenderSurface 共享
pub struct TerminalStore {
    /// 终端映射表
    terminals: parking_lot::RwLock<HashMap<usize, TerminalEntry>>,

    /// 下一个终端 ID（原子操作，支持并发创建）
    next_id: AtomicUsize,

    /// 事件队列
    event_queue: EventQueue,

    /// 事件回调（通知外部有新事件）
    event_callback: Mutex<Option<(TerminalPoolEventCallback, *mut c_void)>>,

    /// 是否需要渲染（当任何终端有更新时设置）
    /// 多个 RenderSurface 可以共享这个标记
    needs_render: Arc<AtomicBool>,

    /// 默认 Shell
    default_shell: String,
}

// Safety: event_callback 中的 *mut c_void 只在主线程使用
unsafe impl Send for TerminalStore {}
unsafe impl Sync for TerminalStore {}

impl TerminalStore {
    /// 创建终端存储
    pub fn new() -> Self {
        // 获取默认 Shell
        let default_shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());

        Self {
            terminals: parking_lot::RwLock::new(HashMap::new()),
            next_id: AtomicUsize::new(1), // 从 1 开始，0 表示无效
            event_queue: EventQueue::new(),
            event_callback: Mutex::new(None),
            needs_render: Arc::new(AtomicBool::new(false)),
            default_shell,
        }
    }

    /// 创建新终端
    ///
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal(&self, cols: u16, rows: u16) -> i32 {
        self.create_terminal_with_cwd(cols, rows, None)
    }

    /// 创建新终端（指定工作目录）
    ///
    /// 返回终端 ID，失败返回 -1
    pub fn create_terminal_with_cwd(&self, cols: u16, rows: u16, working_dir: Option<String>) -> i32 {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);

        // 创建 PTY
        let shell = self.default_shell.clone();
        let pty = match teletypewriter::create_pty_with_spawn(
            &shell,
            vec![],
            &working_dir,
            cols,
            rows,
        ) {
            Ok(pty) => pty,
            Err(e) => {
                eprintln!("[TerminalStore] Failed to create PTY: {:?}", e);
                return -1;
            }
        };

        // 获取 PTY 信息（通过 Deref 到 Child）
        let pty_fd = *pty.id;
        let shell_pid = *pty.pid as u32;

        // 创建 Terminal 聚合根（使用 FFI 模式）
        let terminal = Terminal::new_with_pty(
            TerminalId(id),
            cols as usize,
            rows as usize,
            self.event_queue.clone(),
        );
        let crosswords = terminal.inner_crosswords().expect("FFI terminal must have crosswords");
        let terminal = Arc::new(Mutex::new(terminal));

        // 创建 FFIEventListener
        let event_listener = FFIEventListener::new(self.event_queue.clone(), id);

        // 创建 Machine
        let machine = match Machine::new(
            crosswords,
            pty,
            event_listener,
            id,
            pty_fd,
            shell_pid,
        ) {
            Ok(m) => m,
            Err(e) => {
                eprintln!("[TerminalStore] Failed to create Machine: {:?}", e);
                return -1;
            }
        };

        // 获取消息通道（在 spawn 之前）
        let pty_tx = machine.channel();

        // 启动 Machine
        let machine_handle = machine.spawn();

        // 保存终端条目
        let entry = TerminalEntry {
            terminal,
            pty_tx,
            machine_handle,
            cols,
            rows,
            pty_fd,
            shell_pid,
        };

        self.terminals.write().insert(id, entry);

        id as i32
    }

    /// 关闭终端
    pub fn close_terminal(&self, id: usize) -> bool {
        let mut terminals = self.terminals.write();
        if let Some(entry) = terminals.remove(&id) {
            // 发送关闭消息
            let _ = entry.pty_tx.send(rio_backend::event::Msg::Shutdown);

            // 等待 Machine 线程结束（释放 Arc<Crosswords> 引用）
            // 设置超时避免死锁
            let handle = entry.machine_handle;
            std::thread::spawn(move || {
                // 在后台等待，避免阻塞主线程
                let _ = handle.join();
            });

            true
        } else {
            false
        }
    }

    /// 获取终端数量
    pub fn terminal_count(&self) -> usize {
        self.terminals.read().len()
    }

    /// 检查终端是否存在
    pub fn contains(&self, id: usize) -> bool {
        self.terminals.read().contains_key(&id)
    }

    /// 获取所有终端 ID
    pub fn terminal_ids(&self) -> Vec<usize> {
        self.terminals.read().keys().cloned().collect()
    }

    /// 获取终端的当前工作目录
    pub fn get_cwd(&self, id: usize) -> Option<std::path::PathBuf> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            teletypewriter::foreground_process_path(entry.pty_fd, entry.shell_pid).ok()
        } else {
            None
        }
    }

    /// 获取终端的前台进程名称
    pub fn get_foreground_process_name(&self, id: usize) -> Option<String> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let name = teletypewriter::foreground_process_name(entry.pty_fd, entry.shell_pid);
            if name.is_empty() {
                None
            } else {
                Some(name)
            }
        } else {
            None
        }
    }

    /// 检查终端是否有正在运行的子进程（非 shell）
    pub fn has_running_process(&self, id: usize) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let fg_name = teletypewriter::foreground_process_name(entry.pty_fd, entry.shell_pid);
            if fg_name.is_empty() {
                return false;
            }
            let shell_names = ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "csh", "dash"];
            !shell_names.contains(&fg_name.as_str())
        } else {
            false
        }
    }

    /// 写入输入到终端
    pub fn input(&self, id: usize, data: &[u8]) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            use std::borrow::Cow;
            let _ = entry.pty_tx.send(rio_backend::event::Msg::Input(Cow::Owned(data.to_vec())));
            // 输入后标记需要渲染
            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// 滚动终端
    pub fn scroll(&self, id: usize, delta: i32) -> bool {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let mut terminal = entry.terminal.lock();
            terminal.scroll(delta);
            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// 调整终端大小
    pub fn resize_terminal(&self, id: usize, cols: u16, rows: u16, width: f32, height: f32) -> bool {
        let mut terminals = self.terminals.write();
        if let Some(entry) = terminals.get_mut(&id) {
            // 更新 Terminal
            {
                let mut terminal = entry.terminal.lock();
                terminal.resize(cols as usize, rows as usize);
            }

            // 通知 PTY
            let winsize = teletypewriter::WinsizeBuilder {
                cols,
                rows,
                width: width as u16,
                height: height as u16,
            };
            let _ = entry.pty_tx.send(rio_backend::event::Msg::Resize(winsize));

            entry.cols = cols;
            entry.rows = rows;

            self.needs_render.store(true, Ordering::Release);
            true
        } else {
            false
        }
    }

    /// 搜索
    pub fn search(&self, terminal_id: usize, query: &str) -> i32 {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            // search() 返回匹配数量
            terminal.search(query) as i32
        } else {
            -1
        }
    }

    /// 搜索下一个
    pub fn search_next(&self, terminal_id: usize) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.next_match();
            self.needs_render.store(true, Ordering::Release);
        }
    }

    /// 搜索上一个
    pub fn search_prev(&self, terminal_id: usize) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.prev_match();
            self.needs_render.store(true, Ordering::Release);
        }
    }

    /// 清除搜索
    pub fn clear_search(&self, terminal_id: usize) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.clear_search();
            self.needs_render.store(true, Ordering::Release);
        }
    }

    /// 设置终端模式
    pub fn set_terminal_mode(&self, terminal_id: usize, mode: TerminalMode) {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            let mut terminal = entry.terminal.lock();
            terminal.set_mode(mode);
            if mode == TerminalMode::Active {
                self.needs_render.store(true, Ordering::Release);
            }
        }
    }

    /// 获取终端模式
    pub fn get_terminal_mode(&self, terminal_id: usize) -> Option<TerminalMode> {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&terminal_id) {
            let terminal = entry.terminal.lock();
            Some(terminal.mode())
        } else {
            None
        }
    }

    /// 获取终端（只读访问）
    ///
    /// 注意：返回的是 Terminal 的克隆或快照，用于渲染
    pub fn with_terminal<F, R>(&self, id: usize, f: F) -> Option<R>
    where
        F: FnOnce(&Terminal) -> R,
    {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let terminal = entry.terminal.lock();
            Some(f(&*terminal))
        } else {
            None
        }
    }

    /// 获取终端（可变访问）
    pub fn with_terminal_mut<F, R>(&self, id: usize, f: F) -> Option<R>
    where
        F: FnOnce(&mut Terminal) -> R,
    {
        let terminals = self.terminals.read();
        if let Some(entry) = terminals.get(&id) {
            let mut terminal = entry.terminal.lock();
            Some(f(&mut *terminal))
        } else {
            None
        }
    }

    /// 获取终端尺寸
    pub fn get_terminal_size(&self, id: usize) -> Option<(u16, u16)> {
        let terminals = self.terminals.read();
        terminals.get(&id).map(|e| (e.cols, e.rows))
    }

    // MARK: - 事件相关

    /// 获取事件队列引用（供 RenderSurface 使用）
    pub fn event_queue(&self) -> &EventQueue {
        &self.event_queue
    }

    /// 设置事件回调
    pub fn set_event_callback(&self, callback: TerminalPoolEventCallback, context: *mut c_void) {
        *self.event_callback.lock() = Some((callback, context));

        // 设置 EventQueue 回调
        let store_ptr = self as *const TerminalStore as *mut c_void;
        self.event_queue.set_callback(
            Self::event_queue_callback,
            None,
            store_ptr,
        );
    }

    /// EventQueue 回调
    extern "C" fn event_queue_callback(context: *mut c_void, event: crate::rio_event::FFIEvent) {
        if context.is_null() {
            return;
        }

        let event_type = match event.event_type {
            0 => TerminalEventType::Wakeup,
            1 => TerminalEventType::Render,
            2 => TerminalEventType::CursorBlink,
            3 => TerminalEventType::Bell,
            4 => TerminalEventType::TitleChanged,
            _ => return,
        };

        // 收到 Wakeup/Render 事件时：
        // 检查终端模式，Background 模式完全跳过
        if event_type == TerminalEventType::Wakeup || event_type == TerminalEventType::Render {
            unsafe {
                let store = &*(context as *const TerminalStore);
                let terminal_id = event.route_id;

                let terminals = store.terminals.read();
                if let Some(entry) = terminals.get(&terminal_id) {
                    let terminal = entry.terminal.lock();
                    if terminal.mode() == TerminalMode::Background {
                        // Background 模式，完全跳过
                        return;
                    } else {
                        // Active 模式，标记需要渲染
                        store.needs_render.store(true, Ordering::Release);
                    }
                } else {
                    store.needs_render.store(true, Ordering::Release);
                }
            }
        }

        // 发送事件到外部回调
        let terminal_event = TerminalEvent {
            event_type,
            data: event.route_id as u64,
        };

        unsafe {
            let store = &*(context as *const TerminalStore);
            let callback = store.event_callback.lock();
            if let Some((cb, ctx)) = *callback {
                cb(ctx, terminal_event);
            }
        }
    }

    // MARK: - 渲染标记

    /// 检查是否需要渲染
    #[inline]
    pub fn needs_render(&self) -> bool {
        self.needs_render.load(Ordering::Acquire)
    }

    /// 清除渲染标记
    #[inline]
    pub fn clear_render_flag(&self) {
        self.needs_render.store(false, Ordering::Release);
    }

    /// 获取 needs_render 的 Arc 引用（供 RenderSurface 共享）
    pub fn needs_render_flag(&self) -> Arc<AtomicBool> {
        self.needs_render.clone()
    }

    /// 标记需要渲染
    #[inline]
    pub fn mark_needs_render(&self) {
        self.needs_render.store(true, Ordering::Release);
    }
}
