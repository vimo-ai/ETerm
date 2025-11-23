//! PTY 事件驱动处理器
//!
//! 参考 Rio 的 Machine 实现 (rio-backend/src/performer/mod.rs)
//!
//! 核心架构:
//! 1. 独立线程运行事件循环，使用 corcovado (mio fork) 监听 PTY 事件
//! 2. PTY 可读时循环读取直到 WouldBlock
//! 3. 读取完成后通过回调通知 Swift 触发渲染
//! 4. 不使用定时器轮询

use std::borrow::Cow;
use std::collections::VecDeque;
use std::ffi::c_void;
use std::io::{self, ErrorKind, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{Builder, JoinHandle};

use corcovado::channel;
#[cfg(unix)]
use corcovado::unix::UnixReady;
use corcovado::{Events, Poll, PollOpt, Ready, Token};

use rio_backend::crosswords::Crosswords;
use rio_backend::performer::handler::Processor;
use teletypewriter::{ProcessReadWrite, EventedPty};

use crate::sync::FairMutex;

/// PTY 读取缓冲区大小 (1MB，和 Rio 一致)
const READ_BUFFER_SIZE: usize = 0x10_0000;
/// 锁定 terminal 时最大读取字节数
const MAX_LOCKED_READ: usize = u16::MAX as usize;

/// 渲染回调类型
pub type WakeupCallback = extern "C" fn(*mut c_void);

/// 发送给 Machine 的消息
#[derive(Debug)]
pub enum Msg {
    /// 写入 PTY 的数据
    Input(Cow<'static, [u8]>),
    /// 调整窗口大小
    Resize(teletypewriter::WinsizeBuilder),
    /// 关闭
    Shutdown,
}

/// 可 peek 的 channel receiver
struct PeekableReceiver<T> {
    rx: channel::Receiver<T>,
    peeked: Option<T>,
}

impl<T> PeekableReceiver<T> {
    fn new(rx: channel::Receiver<T>) -> Self {
        Self { rx, peeked: None }
    }

    fn peek(&mut self) -> Option<&T> {
        if self.peeked.is_none() {
            self.peeked = self.rx.try_recv().ok();
        }
        self.peeked.as_ref()
    }

    fn recv(&mut self) -> Option<T> {
        if self.peeked.is_some() {
            self.peeked.take()
        } else {
            self.rx.try_recv().ok()
        }
    }
}

/// 写入状态
struct Writing {
    source: Cow<'static, [u8]>,
    written: usize,
}

impl Writing {
    fn new(c: Cow<'static, [u8]>) -> Writing {
        Writing {
            source: c,
            written: 0,
        }
    }

    fn advance(&mut self, n: usize) {
        self.written += n;
    }

    fn remaining_bytes(&self) -> &[u8] {
        &self.source[self.written..]
    }

    fn finished(&self) -> bool {
        self.written >= self.source.len()
    }
}

/// Machine 状态
#[derive(Default)]
pub struct State {
    write_list: VecDeque<Cow<'static, [u8]>>,
    writing: Option<Writing>,
    parser: Processor,
}

impl State {
    fn ensure_next(&mut self) {
        if self.writing.is_none() {
            self.goto_next();
        }
    }

    fn goto_next(&mut self) {
        self.writing = self.write_list.pop_front().map(Writing::new);
    }

    fn take_current(&mut self) -> Option<Writing> {
        self.writing.take()
    }

    fn needs_write(&self) -> bool {
        self.writing.is_some() || !self.write_list.is_empty()
    }

    fn set_current(&mut self, new: Option<Writing>) {
        self.writing = new;
    }
}

/// 事件收集器 - 替代 VoidListener
///
/// 参考 Rio 的 EventProxy 实现 (rio-backend/src/event/mod.rs)
/// 用于收集 Crosswords 产生的事件（如 CPR 响应、颜色查询等）
#[derive(Clone)]
pub struct EventCollector {
    events: std::sync::Arc<std::sync::Mutex<VecDeque<rio_backend::event::RioEvent>>>,
}

impl EventCollector {
    pub fn new() -> Self {
        Self {
            events: std::sync::Arc::new(std::sync::Mutex::new(VecDeque::new())),
        }
    }

    /// 取出所有待处理的事件
    pub fn drain_events(&self) -> Vec<rio_backend::event::RioEvent> {
        let mut events = self.events.lock().unwrap();
        events.drain(..).collect()
    }
}

impl Default for EventCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl rio_backend::event::EventListener for EventCollector {
    fn event(&self) -> (Option<rio_backend::event::RioEvent>, bool) {
        // 这个方法不是主要用途，Rio 主要通过 send_event 发送事件
        (None, false)
    }

    fn send_event(&self, event: rio_backend::event::RioEvent, _id: rio_backend::event::WindowId) {
        let mut events = self.events.lock().unwrap();
        events.push_back(event);
        // 调试日志（生产环境可移除）
        eprintln!("[EventCollector] Received event: {:?}", events.back());
    }
}

/// 向后兼容的别名
pub type VoidListener = EventCollector;

/// PTY 事件驱动处理器
///
/// 参考 Rio 的 Machine 实现，核心差异：
/// - Rio 通过 winit EventLoop 发送事件
/// - 我们通过 C 回调通知 Swift 层
pub struct PtyMachine {
    sender: channel::Sender<Msg>,
    receiver: PeekableReceiver<Msg>,
    pty: teletypewriter::Pty,
    poll: Poll,
    terminal: Arc<FairMutex<Crosswords<EventCollector>>>,
    /// 事件收集器 - 用于接收 Crosswords 产生的事件（如 CPR 响应）
    event_collector: EventCollector,
    /// 渲染回调
    wakeup_callback: Option<WakeupCallback>,
    callback_context: *mut c_void,
    /// 是否运行中
    running: Arc<AtomicBool>,
    /// 终端 ID (用于日志)
    terminal_id: usize,
}

// 允许跨线程发送 (callback_context 由调用者保证生命周期)
unsafe impl Send for PtyMachine {}

impl PtyMachine {
    /// 创建新的 PTY Machine
    pub fn new(
        pty: teletypewriter::Pty,
        terminal: Arc<FairMutex<Crosswords<EventCollector>>>,
        event_collector: EventCollector,
        terminal_id: usize,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let (sender, receiver) = channel::channel();
        let poll = Poll::new()?;

        Ok(PtyMachine {
            sender,
            receiver: PeekableReceiver::new(receiver),
            poll,
            pty,
            terminal,
            event_collector,
            wakeup_callback: None,
            callback_context: std::ptr::null_mut(),
            running: Arc::new(AtomicBool::new(false)),
            terminal_id,
        })
    }

    /// 设置渲染回调
    pub fn set_wakeup_callback(&mut self, callback: WakeupCallback, context: *mut c_void) {
        self.wakeup_callback = Some(callback);
        self.callback_context = context;
    }

    /// 获取消息发送通道
    pub fn channel(&self) -> channel::Sender<Msg> {
        self.sender.clone()
    }

    /// 检查是否运行中
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    /// 从 PTY 读取数据
    ///
    /// 参考 Rio Machine::pty_read()
    fn pty_read(&mut self, state: &mut State, buf: &mut [u8]) -> io::Result<bool> {
        let mut unprocessed = 0;
        let mut processed = 0;
        let mut has_data = false;

        // 预约 terminal 锁，阻止渲染线程获取
        let _terminal_lease = Some(self.terminal.lease());
        let mut terminal = None;

        loop {
            // 从 PTY 读取
            match self.pty.reader().read(&mut buf[unprocessed..]) {
                // 没有更多数据可读
                Ok(0) if unprocessed == 0 => break,
                Ok(got) => {
                    unprocessed += got;
                    has_data = true;
                }
                Err(err) => match err.kind() {
                    ErrorKind::Interrupted | ErrorKind::WouldBlock => {
                        // 如果没有未处理数据，返回
                        if unprocessed == 0 {
                            break;
                        }
                    }
                    _ => return Err(err),
                },
            }

            // 尝试获取 terminal 锁
            let terminal = match &mut terminal {
                Some(terminal) => terminal,
                None => terminal.insert(match self.terminal.try_lock_unfair() {
                    // 缓冲区满了，强制阻塞获取锁
                    None if unprocessed >= READ_BUFFER_SIZE => self.terminal.lock_unfair(),
                    None => continue,
                    Some(terminal) => terminal,
                }),
            };

            // 解析数据
            state.parser.advance(&mut **terminal, &buf[..unprocessed]);

            processed += unprocessed;
            unprocessed = 0;

            // 避免长时间锁定
            if processed >= MAX_LOCKED_READ {
                break;
            }
        }

        Ok(has_data)
    }

    /// 向 PTY 写入数据
    fn pty_write(&mut self, state: &mut State) -> io::Result<()> {
        state.ensure_next();

        'write_many: while let Some(mut current) = state.take_current() {
            'write_one: loop {
                match self.pty.writer().write(current.remaining_bytes()) {
                    Ok(0) => {
                        state.set_current(Some(current));
                        break 'write_many;
                    }
                    Ok(n) => {
                        current.advance(n);
                        if current.finished() {
                            state.goto_next();
                            break 'write_one;
                        }
                    }
                    Err(err) => {
                        state.set_current(Some(current));
                        match err.kind() {
                            ErrorKind::Interrupted | ErrorKind::WouldBlock => break 'write_many,
                            _ => return Err(err),
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// 处理 channel 事件
    fn drain_recv_channel(&mut self, state: &mut State) -> bool {
        while let Some(msg) = self.receiver.recv() {
            match msg {
                Msg::Input(input) => state.write_list.push_back(input),
                Msg::Resize(window_size) => {
                    let _ = self.pty.set_winsize(window_size);
                }
                Msg::Shutdown => return false,
            }
        }
        true
    }

    /// 通知 Swift 层渲染
    fn send_wakeup(&self) {
        if let Some(callback) = self.wakeup_callback {
            callback(self.callback_context);
        }
    }

    /// 启动事件循环（在新线程中运行）
    pub fn spawn(mut self) -> JoinHandle<(Self, State)> {
        let running = self.running.clone();

        Builder::new()
            .name(format!("PTY-{}", self.terminal_id))
            .spawn(move || {
                running.store(true, Ordering::SeqCst);

                let mut state = State::default();
                let mut buf = [0u8; READ_BUFFER_SIZE];

                let mut tokens = (0..).map(Token);

                let poll_opts = PollOpt::edge() | PollOpt::oneshot();

                // 注册 channel
                let channel_token = tokens.next().unwrap();
                self.poll
                    .register(&self.receiver.rx, channel_token, Ready::readable(), poll_opts)
                    .unwrap();

                // 注册 PTY
                self.pty
                    .register(&self.poll, &mut tokens, Ready::readable(), poll_opts)
                    .unwrap();

                let mut events = Events::with_capacity(1024);

                'event_loop: loop {
                    events.clear();

                    // 等待事件（无超时，完全事件驱动）
                    if let Err(err) = self.poll.poll(&mut events, None) {
                        match err.kind() {
                            ErrorKind::Interrupted => continue,
                            _ => {
                                eprintln!("[PtyMachine-{}] Poll error: {}", self.terminal_id, err);
                                break 'event_loop;
                            }
                        }
                    }

                    // 先处理 channel 消息
                    if !self.drain_recv_channel(&mut state) {
                        break 'event_loop;
                    }

                    let mut needs_wakeup = false;

                    for event in events.iter() {
                        match event.token() {
                            token if token == channel_token => {
                                // 重新注册 channel
                                self.poll
                                    .reregister(
                                        &self.receiver.rx,
                                        channel_token,
                                        Ready::readable(),
                                        poll_opts,
                                    )
                                    .unwrap();
                            }
                            token if token == self.pty.child_event_token() => {
                                // 子进程事件
                                if let Some(teletypewriter::ChildEvent::Exited) =
                                    self.pty.next_child_event()
                                {
                                    eprintln!(
                                        "[PtyMachine-{}] Child process exited",
                                        self.terminal_id
                                    );
                                    self.terminal.lock().exit();
                                    needs_wakeup = true;
                                    break 'event_loop;
                                }
                            }
                            token
                                if token == self.pty.read_token()
                                    || token == self.pty.write_token() =>
                            {
                                #[cfg(unix)]
                                if UnixReady::from(event.readiness()).is_hup() {
                                    continue;
                                }

                                // PTY 可读
                                if event.readiness().is_readable() {
                                    match self.pty_read(&mut state, &mut buf) {
                                        Ok(has_data) => {
                                            if has_data {
                                                needs_wakeup = true;
                                            }
                                        }
                                        Err(err) => {
                                            #[cfg(target_os = "linux")]
                                            if err.raw_os_error() == Some(libc::EIO) {
                                                continue;
                                            }
                                            eprintln!(
                                                "[PtyMachine-{}] PTY read error: {}",
                                                self.terminal_id, err
                                            );
                                            break 'event_loop;
                                        }
                                    }
                                }

                                // PTY 可写
                                if event.readiness().is_writable() {
                                    if let Err(err) = self.pty_write(&mut state) {
                                        eprintln!(
                                            "[PtyMachine-{}] PTY write error: {}",
                                            self.terminal_id, err
                                        );
                                        break 'event_loop;
                                    }
                                }
                            }
                            _ => (),
                        }
                    }

                    // 🎯 关键：处理 EventCollector 中的事件（如 CPR 响应）
                    // 参考 Rio: rio/frontends/rioterm/src/application.rs:627-636
                    let collected_events = self.event_collector.drain_events();
                    if !collected_events.is_empty() {
                        eprintln!(
                            "[PtyMachine-{}] [CPR DEBUG] Draining {} events from EventCollector",
                            self.terminal_id, collected_events.len()
                        );
                    }
                    for event in collected_events {
                        match event {
                            rio_backend::event::RioEvent::PtyWrite(text) => {
                                // 将响应写回 PTY（如 CPR 响应 "\x1b[{row};{col}R"）
                                eprintln!(
                                    "[PtyMachine-{}] [CPR DEBUG] Processing PtyWrite, writing to PTY: {:?}",
                                    self.terminal_id, text
                                );
                                state.write_list.push_back(Cow::Owned(text.into_bytes()));
                            }
                            // 可以根据需要处理其他事件类型
                            _ => {
                                eprintln!(
                                    "[PtyMachine-{}] [CPR DEBUG] Unhandled event: {:?}",
                                    self.terminal_id, event
                                );
                            }
                        }
                    }

                    // 重新注册 PTY 事件
                    let mut interest = Ready::readable();
                    if state.needs_write() {
                        interest.insert(Ready::writable());
                    }
                    self.pty.reregister(&self.poll, interest, poll_opts).unwrap();

                    // 如果有新数据，通知 Swift 层渲染
                    if needs_wakeup {
                        self.send_wakeup();
                    }
                }

                // 清理
                let _ = self.poll.deregister(&self.receiver.rx);
                let _ = self.pty.deregister(&self.poll);
                running.store(false, Ordering::SeqCst);

                (self, state)
            })
            .expect("Failed to spawn PTY thread")
    }
}

/// 简化的 PTY 写入接口
pub fn send_input(sender: &channel::Sender<Msg>, data: &[u8]) -> bool {
    sender
        .send(Msg::Input(Cow::Owned(data.to_vec())))
        .is_ok()
}

/// 发送 resize 消息
pub fn send_resize(sender: &channel::Sender<Msg>, winsize: teletypewriter::WinsizeBuilder) -> bool {
    sender.send(Msg::Resize(winsize)).is_ok()
}

/// 发送 shutdown 消息
pub fn send_shutdown(sender: &channel::Sender<Msg>) -> bool {
    sender.send(Msg::Shutdown).is_ok()
}
