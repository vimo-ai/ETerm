//! Rio Machine - 照抄 rio-backend/src/performer/mod.rs
//!
//! PTY 事件驱动处理器，完全照抄 Rio 的实现
//! 核心差异：使用我们的 FFIEventListener 而不是 EventProxy

use std::borrow::Cow;
use std::collections::VecDeque;
use std::io::{self, ErrorKind, Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{Builder, JoinHandle};
use std::time::Instant;

use corcovado::channel;
#[cfg(unix)]
use corcovado::unix::UnixReady;
use corcovado::{Events, PollOpt, Ready};

use rio_backend::crosswords::Crosswords;
use rio_backend::event::Msg;
use rio_backend::performer::handler::Processor;

use crate::infra::SharedLogBuffer;
use teletypewriter::EventedPty;

use crate::rio_event::{FFIEventListener, RioEvent};
use pty_daemon::shared_ring::SharedRingBuffer;

/// 性能日志开关（开发调试时设为 true，生产环境设为 false）
const DEBUG_PERFORMANCE: bool = false;

/// 性能日志宏（只在 DEBUG_PERFORMANCE = true 时输出）
macro_rules! perf_log {
    ($($arg:tt)*) => {
        if DEBUG_PERFORMANCE {
            println!($($arg)*);
        }
    };
}

/// 照抄 Rio: READ_BUFFER_SIZE = 1MB
const READ_BUFFER_SIZE: usize = 0x10_0000;

/// 照抄 Rio: 锁定 terminal 时最大读取字节数
const MAX_LOCKED_READ: usize = u16::MAX as usize;

/// 照抄 Rio: PeekableReceiver
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

/// 照抄 Rio: Writing 状态
struct Writing {
    source: Cow<'static, [u8]>,
    written: usize,
}

impl Writing {
    #[inline]
    fn new(c: Cow<'static, [u8]>) -> Writing {
        Writing {
            source: c,
            written: 0,
        }
    }

    #[inline]
    fn advance(&mut self, n: usize) {
        self.written += n;
    }

    #[inline]
    fn remaining_bytes(&self) -> &[u8] {
        &self.source[self.written..]
    }

    #[inline]
    fn finished(&self) -> bool {
        self.written >= self.source.len()
    }
}

/// 照抄 Rio: State
#[derive(Default)]
pub struct State {
    write_list: VecDeque<Cow<'static, [u8]>>,
    writing: Option<Writing>,
    parser: Processor,
}

impl State {
    #[inline]
    fn ensure_next(&mut self) {
        if self.writing.is_none() {
            self.goto_next();
        }
    }

    #[inline]
    fn goto_next(&mut self) {
        self.writing = self.write_list.pop_front().map(Writing::new);
    }

    #[inline]
    fn take_current(&mut self) -> Option<Writing> {
        self.writing.take()
    }

    #[inline]
    fn needs_write(&self) -> bool {
        self.writing.is_some() || !self.write_list.is_empty()
    }

    #[inline]
    fn set_current(&mut self, new: Option<Writing>) {
        self.writing = new;
    }
}

/// Rio Machine - 照抄 rio-backend/src/performer/mod.rs 的 Machine
///
/// 核心差异：
/// - 使用 FFIEventListener 而不是 EventProxy
/// - 不需要 window_id（我们只有一个"窗口"）
pub struct Machine<T: EventedPty> {
    sender: channel::Sender<Msg>,
    receiver: PeekableReceiver<Msg>,
    pty: T,
    poll: corcovado::Poll,
    terminal: Arc<parking_lot::RwLock<Crosswords<FFIEventListener>>>,
    event_listener: FFIEventListener,
    route_id: usize,
    // 🔍 调试：记录上一次的前台进程和状态
    #[allow(dead_code)] // Debug fields
    last_fg_process: Option<String>,
    #[allow(dead_code)] // Debug fields
    last_process_state: Option<String>,
    // 🔍 调试：PTY 文件描述符和 shell PID
    #[allow(dead_code)] // Debug fields
    pty_fd: i32,
    #[allow(dead_code)] // Debug fields
    shell_pid: u32,
    /// 日志缓冲（可选，来自 Terminal）
    log_buffer: SharedLogBuffer,
    /// 共享内存 ring buffer（daemon 模式下用于恢复屏幕）
    shared_ring: Option<SharedRingBuffer>,
}

impl<T> Machine<T>
where
    T: EventedPty + Send + 'static,
{
    /// 照抄 Rio: Machine::new
    pub fn new(
        terminal: Arc<parking_lot::RwLock<Crosswords<FFIEventListener>>>,
        pty: T,
        event_listener: FFIEventListener,
        route_id: usize,
        pty_fd: i32,
        shell_pid: u32,
    ) -> Result<Machine<T>, Box<dyn std::error::Error>> {
        Self::new_with_log_buffer(terminal, pty, event_listener, route_id, pty_fd, shell_pid, None, None)
    }

    pub fn new_with_log_buffer(
        terminal: Arc<parking_lot::RwLock<Crosswords<FFIEventListener>>>,
        pty: T,
        event_listener: FFIEventListener,
        route_id: usize,
        pty_fd: i32,
        shell_pid: u32,
        log_buffer: SharedLogBuffer,
        shared_ring: Option<SharedRingBuffer>,
    ) -> Result<Machine<T>, Box<dyn std::error::Error>> {
        let (sender, receiver) = channel::channel();
        let poll = corcovado::Poll::new()?;

        Ok(Machine {
            sender,
            receiver: PeekableReceiver::new(receiver),
            poll,
            pty,
            terminal,
            event_listener,
            route_id,
            last_fg_process: None,
            last_process_state: None,
            pty_fd,
            shell_pid,
            log_buffer,
            shared_ring,
        })
    }

    /// 获取进程状态 (R=Running, S=Sleeping, etc.)
    #[allow(dead_code)] // Debug utility
    fn get_process_state(pid: i32) -> String {
        #[cfg(target_os = "macos")]
        {
            // macOS: 使用 ps 命令
            use std::process::Command;
            if let Ok(output) = Command::new("ps")
                .args(["-p", &pid.to_string(), "-o", "state="])
                .output()
            {
                return String::from_utf8_lossy(&output.stdout).trim().to_string();
            }
        }

        #[cfg(target_os = "linux")]
        {
            // Linux: 读取 /proc/{pid}/stat
            let stat_path = format!("/proc/{}/stat", pid);
            if let Ok(content) = std::fs::read_to_string(&stat_path) {
                // /proc/{pid}/stat 格式: pid (comm) state ...
                // 第三个字段是 state
                let parts: Vec<&str> = content.split_whitespace().collect();
                if parts.len() > 2 {
                    return parts[2].to_string();
                }
            }
        }

        "?".to_string()
    }

    /// 照抄 Rio: Machine::pty_read
    ///
    /// 这是最关键的函数，从 PTY 读取数据并解析
    #[inline]
    fn pty_read(&mut self, state: &mut State, buf: &mut [u8]) -> io::Result<()> {
        let mut unprocessed = 0;
        let mut processed = 0;

        // RwLock 不需要 lease，parking_lot 的 RwLock 默认是公平的
        let mut terminal = None;

        loop {
            // 照抄 Rio: Read from the PTY.
            match self.pty.reader().read(&mut buf[unprocessed..]) {
                // This is received on Windows/macOS when no more data is readable from the PTY.
                Ok(0) if unprocessed == 0 => break,
                Ok(got) => {
                    // ⚠️ [PERFORMANCE] 注释掉频繁的进程检测（每次PTY读取都调用proc_pidpath+ps命令，导致严重卡顿）
                    // 原因：处理64KB数据时可能触发几百次系统调用，累积耗时2-3.5秒
                    // 且收集的数据(last_fg_process/last_process_state)从未被使用
                    // 如需恢复：在合适的地方（如定时器或进程切换事件）调用，而非每次PTY读取
                    /*
                    // 🎯 检测前台进程和状态
                    let fg_pid = unsafe { libc::tcgetpgrp(self.pty_fd) };

                    if fg_pid > 0 {
                        let fg_process = teletypewriter::foreground_process_name(self.pty_fd, self.shell_pid);
                        let fg_process_trimmed = fg_process.trim().to_string();

                        // 获取进程状态
                        let process_state = Self::get_process_state(fg_pid);
                        let state_desc = match process_state.as_str() {
                            "R" => "Running",
                            "S" => "Sleeping",
                            "D" => "Disk Sleep",
                            "Z" => "Zombie",
                            "T" => "Stopped",
                            _ => "Unknown",
                        };

                        // 检测进程切换（不输出日志）
                        let process_changed = self.last_fg_process.as_ref() != Some(&fg_process_trimmed);

                        self.last_fg_process = Some(fg_process_trimmed);
                        self.last_process_state = Some(process_state);
                    }
                    */

                    unprocessed += got
                },
                Err(err) => match err.kind() {
                    ErrorKind::Interrupted | ErrorKind::WouldBlock => {
                        // Go back to mio if we're caught up on parsing and the PTY would block.
                        if unprocessed == 0 {
                            break;
                        }
                    }
                    _ => return Err(err),
                },
            }

            // 照抄 Rio: Attempt to lock the terminal.
            let lock_start = std::time::Instant::now();
            let terminal = match &mut terminal {
                Some(terminal) => terminal,
                None => {
                    let lock_acquired = match self.terminal.try_write() {
                        // Force block if we are at the buffer size limit.
                        None if unprocessed >= READ_BUFFER_SIZE => {
                            perf_log!("🔒 [I/O Thread] try_write failed, forcing write lock...");
                            let t = self.terminal.write();
                            let elapsed = lock_start.elapsed().as_micros();
                            perf_log!("🔒 [I/O Thread] Acquired write lock after {}μs ({}ms)", elapsed, elapsed / 1000);
                            t
                        }
                        None => continue,
                        Some(t) => {
                            let elapsed = lock_start.elapsed().as_micros();
                            if elapsed > 1000 {
                                perf_log!("🔒 [I/O Thread] Acquired write lock (try_write) after {}μs", elapsed);
                            }
                            t
                        }
                    };
                    terminal.insert(lock_acquired)
                }
            };

            // 写入日志缓冲区（如果启用）
            if let Some(ref log_buffer) = self.log_buffer {
                log_buffer.append(&buf[..unprocessed]);
            }

            // 写入共享内存 ring buffer（daemon 模式下恢复屏幕用）
            if let Some(ref shm) = self.shared_ring {
                let shm_start = std::time::Instant::now();
                shm.write(&buf[..unprocessed]);
                let shm_ns = shm_start.elapsed().as_nanos();
                // ⚠️ DO NOT DELETE - shm write 性能日志，用于验证热路径开销
                #[cfg(feature = "perf_log")]
                crate::rust_log_info!("[perf] shm_write: {}ns for {} bytes", shm_ns, unprocessed);
            }

            // 照抄 Rio: Parse the incoming bytes.
            let parse_start = std::time::Instant::now();
            state.parser.advance(&mut **terminal, &buf[..unprocessed]);
            let parse_time = parse_start.elapsed().as_micros();

            if parse_time > 10000 {
                perf_log!("🔒 [I/O Thread] parser.advance() took {}μs ({}ms) for {} bytes",
                         parse_time, parse_time / 1000, unprocessed);
            }

            processed += unprocessed;
            unprocessed = 0;

            // 照抄 Rio: Assure we're not blocking the terminal too long unnecessarily.
            if processed >= MAX_LOCKED_READ {
                perf_log!("🔒 [I/O Thread] Releasing write lock after processing {} bytes (MAX_LOCKED_READ limit)", processed);
                break;
            }
        }

        // 释放锁时打印日志
        if terminal.is_some() && processed > 0 {
            perf_log!("🔒 [I/O Thread] Releasing write lock after processing {} bytes total", processed);
        }

        // 照抄 Rio: Queue terminal update processing unless all processed bytes were synchronized.
        //
        // 注意：不在这里抑制 Wakeup，而是在渲染层检查 is_syncing
        // 原因：完全抑制 Wakeup 会导致界面卡死（用户输入无响应）
        if processed > 0 {
            self.event_listener
                .send_event(RioEvent::Wakeup(self.route_id));
        }

        Ok(())
    }

    /// 照抄 Rio: Machine::drain_recv_channel
    ///
    /// Returns `false` when a shutdown message was received.
    fn drain_recv_channel(&mut self, state: &mut State) -> bool {
        while let Some(msg) = self.receiver.recv() {
            match msg {
                Msg::Input(input) => {
                    state.write_list.push_back(input);
                }
                Msg::Resize(window_size) => {
                    eprintln!("[Machine-{}] Resize: cols={} rows={}",
                        self.route_id, window_size.cols, window_size.rows);
                    match self.pty.set_winsize(window_size) {
                        Ok(_) => eprintln!("[Machine-{}] set_winsize OK", self.route_id),
                        Err(e) => eprintln!("[Machine-{}] set_winsize FAILED: {}", self.route_id, e),
                    }
                }
                Msg::Shutdown => return false,
            }
        }

        true
    }

    /// 照抄 Rio: Machine::channel_event
    ///
    /// Returns a `bool` indicating whether or not the event loop should continue running.
    #[inline]
    fn channel_event(&mut self, token: corcovado::Token, state: &mut State) -> bool {
        if !self.drain_recv_channel(state) {
            return false;
        }

        self.poll
            .reregister(
                &self.receiver.rx,
                token,
                Ready::readable(),
                PollOpt::edge() | PollOpt::oneshot(),
            )
            .unwrap();

        true
    }

    /// 照抄 Rio: Machine::pty_write
    #[inline]
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

    /// 获取消息发送通道
    pub fn channel(&self) -> channel::Sender<Msg> {
        self.sender.clone()
    }

    /// 照抄 Rio: Machine::spawn
    ///
    /// 启动 PTY 事件循环
    pub fn spawn(mut self) -> JoinHandle<(Self, State)> {
        Builder::new()
            .name(format!("PTY-{}", self.route_id))
            .spawn(move || {
                let mut state = State::default();
                let mut buf = [0u8; READ_BUFFER_SIZE];

                let mut tokens = (0..).map(Into::into);

                let poll_opts = PollOpt::edge() | PollOpt::oneshot();

                let channel_token = tokens.next().unwrap();
                self.poll
                    .register(
                        &self.receiver.rx,
                        channel_token,
                        Ready::readable(),
                        poll_opts,
                    )
                    .unwrap();

                // 照抄 Rio: Register TTY through EventedRW interface.
                self.pty
                    .register(&self.poll, &mut tokens, Ready::readable(), poll_opts)
                    .unwrap();

                let mut events = Events::with_capacity(1024);

                eprintln!("[Machine-{}] event loop started, pty_fd={}, shell_pid={}", self.route_id, self.pty_fd, self.shell_pid);

                'event_loop: loop {
                    // 照抄 Rio: Wakeup the event loop when a synchronized update timeout was reached.
                    let handler = state.parser.sync_timeout();
                    let timeout = handler
                        .sync_timeout()
                        .map(|st| st.saturating_duration_since(Instant::now()));

                    events.clear();
                    if let Err(err) = self.poll.poll(&mut events, timeout) {
                        match err.kind() {
                            ErrorKind::Interrupted => continue,
                            _ => {
                                eprintln!("[Machine-{}] Event loop polling error: {}", self.route_id, err);
                                break 'event_loop;
                            }
                        }
                    }

                    // 照抄 Rio: Handle synchronized update timeout.
                    if events.is_empty() && self.receiver.peek().is_none() {
                        let mut terminal = self.terminal.write();
                        state.parser.stop_sync(&mut *terminal);

                        // 照抄 Rio: Emit damage event if there's any damage after processing sync buffer
                        self.event_listener
                            .send_event(RioEvent::Wakeup(self.route_id));

                        continue;
                    }

                    // 照抄 Rio: Handle channel events, if there are any.
                    if !self.drain_recv_channel(&mut state) {
                        break;
                    }

                    for event in events.iter() {
                        match event.token() {
                            token if token == channel_token => {
                                // 照抄 Rio: In case should shutdown by message
                                if !self.channel_event(channel_token, &mut state) {
                                    break 'event_loop;
                                }
                            }
                            token if token == self.pty.child_event_token() => {
                                if let Some(teletypewriter::ChildEvent::Exited) =
                                    self.pty.next_child_event()
                                {
                                    // 照抄 Rio: 子进程退出
                                    self.terminal.write().exit();

                                    self.event_listener.send_event(RioEvent::Render);

                                    break 'event_loop;
                                }
                            }

                            token
                                if token == self.pty.read_token()
                                    || token == self.pty.write_token() =>
                            {
                                #[cfg(unix)]
                                if UnixReady::from(event.readiness()).is_hup() {
                                    eprintln!("[Machine-{}] PTY HUP detected, skipping I/O", self.route_id);
                                    continue;
                                }
                                if event.readiness().is_readable() {
                                    if let Err(err) = self.pty_read(&mut state, &mut buf) {
                                        // 照抄 Rio: On Linux, a `read` on the master side of a PTY can fail
                                        // with `EIO` if the client side hangs up. In that case,
                                        // just loop back round for the inevitable `Exited` event.
                                        #[cfg(target_os = "linux")]
                                        if err.raw_os_error() == Some(libc::EIO) {
                                            continue;
                                        }

                                        eprintln!(
                                            "[Machine-{}] Error reading from PTY in event loop: {}",
                                            self.route_id, err
                                        );
                                        break 'event_loop;
                                    }
                                }

                                if event.readiness().is_writable() {
                                    if let Err(err) = self.pty_write(&mut state) {
                                        eprintln!(
                                            "[Machine-{}] Error writing to PTY in event loop: {}",
                                            self.route_id, err
                                        );
                                        break 'event_loop;
                                    }
                                }
                            }
                            _ => (),
                        }
                    }

                    // 🎯 处理 EventListener 队列中的事件（如 CPR 响应）
                    let queued_events = self.event_listener.queue().drain();
                    for event in queued_events {
                        match event {
                            crate::rio_event::RioEvent::PtyWrite(text) => {
                                state.write_list.push_back(std::borrow::Cow::Owned(text.into_bytes()));
                            }
                            _ => {
                                // 其他事件不在这里处理（如 Wakeup、Render 等由 Swift 处理）
                            }
                        }
                    }

                    // 照抄 Rio: Register write interest if necessary.
                    let mut interest = Ready::readable();
                    if state.needs_write() {
                        interest.insert(Ready::writable());
                    }
                    // 照抄 Rio: Reregister with new interest.
                    self.pty
                        .reregister(&self.poll, interest, poll_opts)
                        .unwrap();
                }

                // 照抄 Rio: The evented instances are not dropped here so deregister them explicitly.
                let _ = self.poll.deregister(&self.receiver.rx);
                let _ = self.pty.deregister(&self.poll);

                (self, state)
            })
            .expect("Failed to spawn PTY thread")
    }
}

/// RingReader — polls SharedRingBuffer during baton-pass takeover,
/// feeds new bytes to Crosswords so ETerm continues rendering.
pub struct RingReader {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<u64>>,
}

impl RingReader {
    pub fn start(
        initial_cursor: u64,
        crosswords: Arc<parking_lot::RwLock<Crosswords<FFIEventListener>>>,
        event_listener: FFIEventListener,
        route_id: usize,
        shm_name: String,
    ) -> Result<Self, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_clone = stop.clone();

        let handle = std::thread::Builder::new()
            .name(format!("RingReader-{}", route_id))
            .spawn(move || {
                Self::reader_loop(stop_clone, initial_cursor, crosswords, event_listener, route_id, &shm_name)
            })
            .map_err(|e| format!("spawn RingReader: {e}"))?;

        Ok(Self {
            stop,
            handle: Some(handle),
        })
    }

    fn reader_loop(
        stop: Arc<AtomicBool>,
        mut cursor: u64,
        crosswords: Arc<parking_lot::RwLock<Crosswords<FFIEventListener>>>,
        event_listener: FFIEventListener,
        route_id: usize,
        shm_name: &str,
    ) -> u64 {
        let ring = match pty_daemon::shared_ring::SharedRingBuffer::open(shm_name) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("[RingReader-{}] failed to open shm {}: {}", route_id, shm_name, e);
                return cursor;
            }
        };

        let mut parser: Processor = Processor::new();

        while !stop.load(Ordering::Acquire) {
            let (data, new_total) = ring.read_since(cursor);
            if data.is_empty() {
                std::thread::sleep(std::time::Duration::from_millis(8));
                continue;
            }

            cursor = new_total;

            {
                let mut cw = crosswords.write();
                parser.advance(&mut *cw, &data);
            }

            event_listener.send_event(RioEvent::Wakeup(route_id));
        }

        cursor
    }

    pub fn stop_and_join(mut self) -> u64 {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.handle.take() {
            handle.join().unwrap_or(0)
        } else {
            0
        }
    }
}

impl Drop for RingReader {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

/// 用于发送 PTY 输入的辅助函数
pub fn send_input(sender: &channel::Sender<Msg>, data: &[u8]) -> bool {
    let result = sender
        .send(Msg::Input(Cow::Owned(data.to_vec())))
        .is_ok();
    if !result {
        eprintln!("[send_input] channel send FAILED ({} bytes)", data.len());
    }
    result
}

/// 用于发送 resize 消息的辅助函数
pub fn send_resize(sender: &channel::Sender<Msg>, winsize: teletypewriter::WinsizeBuilder) -> bool {
    sender.send(Msg::Resize(winsize)).is_ok()
}
