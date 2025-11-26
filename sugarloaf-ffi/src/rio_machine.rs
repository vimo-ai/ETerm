//! Rio Machine - 照抄 rio-backend/src/performer/mod.rs
//!
//! PTY 事件驱动处理器，完全照抄 Rio 的实现
//! 核心差异：使用我们的 FFIEventListener 而不是 EventProxy

use std::borrow::Cow;
use std::collections::VecDeque;
use std::io::{self, ErrorKind, Read, Write};
use std::sync::Arc;
use std::thread::{Builder, JoinHandle};
use std::time::Instant;

use corcovado::channel;
#[cfg(unix)]
use corcovado::unix::UnixReady;
use corcovado::{Events, PollOpt, Ready};

use rio_backend::crosswords::Crosswords;
use rio_backend::event::Msg;
use rio_backend::performer::handler::Processor;
use teletypewriter::EventedPty;

use crate::rio_event::{FFIEventListener, RioEvent};
use crate::sync::FairMutex;

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
    terminal: Arc<FairMutex<Crosswords<FFIEventListener>>>,
    event_listener: FFIEventListener,
    route_id: usize,
    // 🔍 调试：记录上一次的前台进程和状态
    last_fg_process: Option<String>,
    last_process_state: Option<String>,
    // 🔍 调试：PTY 文件描述符和 shell PID
    pty_fd: i32,
    shell_pid: u32,
}

impl<T> Machine<T>
where
    T: EventedPty + Send + 'static,
{
    /// 照抄 Rio: Machine::new
    pub fn new(
        terminal: Arc<FairMutex<Crosswords<FFIEventListener>>>,
        pty: T,
        event_listener: FFIEventListener,
        route_id: usize,
        pty_fd: i32,
        shell_pid: u32,
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
        })
    }

    /// 获取进程状态 (R=Running, S=Sleeping, etc.)
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

        // 照抄 Rio: Reserve the next terminal lock for PTY reading.
        let _terminal_lease = Some(self.terminal.lease());
        let mut terminal = None;

        loop {
            // 照抄 Rio: Read from the PTY.
            match self.pty.reader().read(&mut buf[unprocessed..]) {
                // This is received on Windows/macOS when no more data is readable from the PTY.
                Ok(0) if unprocessed == 0 => break,
                Ok(got) => {
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

                        // 检测进程切换
                        let process_changed = self.last_fg_process.as_ref() != Some(&fg_process_trimmed);
                        let state_changed = self.last_process_state.as_ref() != Some(&process_state);

                        if process_changed {
                            if let Some(ref last) = self.last_fg_process {
                                eprintln!("⚡ [进程切换] {} → {} | 状态: {} ({})",
                                          last, fg_process_trimmed, process_state, state_desc);
                            } else {
                                eprintln!("🔧 [初始进程] {} | 状态: {} ({}) | pid: {}",
                                          fg_process_trimmed, process_state, state_desc, fg_pid);
                            }
                        } else if state_changed {
                            eprintln!("🔄 [状态变化] {} | {} → {} | pid: {}",
                                      fg_process_trimmed,
                                      self.last_process_state.as_ref().unwrap_or(&"?".to_string()),
                                      process_state,
                                      fg_pid);
                        }

                        self.last_fg_process = Some(fg_process_trimmed);
                        self.last_process_state = Some(process_state);
                    }

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
            let terminal = match &mut terminal {
                Some(terminal) => terminal,
                None => terminal.insert(match self.terminal.try_lock_unfair() {
                    // Force block if we are at the buffer size limit.
                    None if unprocessed >= READ_BUFFER_SIZE => self.terminal.lock_unfair(),
                    None => continue,
                    Some(terminal) => terminal,
                }),
            };

            // 照抄 Rio: Parse the incoming bytes.
            state.parser.advance(&mut **terminal, &buf[..unprocessed]);

            processed += unprocessed;
            unprocessed = 0;

            // 照抄 Rio: Assure we're not blocking the terminal too long unnecessarily.
            if processed >= MAX_LOCKED_READ {
                break;
            }
        }

        // 照抄 Rio: Queue terminal update processing unless all processed bytes were synchronized.
        // For non-synchronized updates, we send a Wakeup event which will coalesce
        // multiple rapid updates into a single render pass.
        if state.parser.sync_bytes_count() < processed && processed > 0 {
            // 照抄 Rio: Send a Wakeup event to coalesce renders
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
                Msg::Input(input) => state.write_list.push_back(input),
                Msg::Resize(window_size) => {
                    let _ = self.pty.set_winsize(window_size);
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
                        let mut terminal = self.terminal.lock();
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
                                    self.terminal.lock().exit();

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
                                    // 照抄 Rio: Don't try to do I/O on a dead PTY.
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

/// 用于发送 PTY 输入的辅助函数
pub fn send_input(sender: &channel::Sender<Msg>, data: &[u8]) -> bool {
    sender
        .send(Msg::Input(Cow::Owned(data.to_vec())))
        .is_ok()
}

/// 用于发送 resize 消息的辅助函数
pub fn send_resize(sender: &channel::Sender<Msg>, winsize: teletypewriter::WinsizeBuilder) -> bool {
    sender.send(Msg::Resize(winsize)).is_ok()
}

/// 用于发送 shutdown 消息的辅助函数
pub fn send_shutdown(sender: &channel::Sender<Msg>) -> bool {
    sender.send(Msg::Shutdown).is_ok()
}

