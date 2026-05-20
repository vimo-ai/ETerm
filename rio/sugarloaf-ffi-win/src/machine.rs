use std::borrow::Cow;
use std::collections::VecDeque;
use std::io::{self, ErrorKind, Read, Write};
use std::sync::Arc;
use std::thread::{Builder, JoinHandle};
use std::time::Instant;

use corcovado::channel;
use corcovado::{Events, PollOpt, Ready};

use rio_backend::crosswords::Crosswords;
use rio_backend::event::Msg;
use rio_backend::performer::handler::Processor;
use teletypewriter::EventedPty;

use crate::event::WinEventListener;

const READ_BUFFER_SIZE: usize = 0x10_0000;
const MAX_LOCKED_READ: usize = u16::MAX as usize;

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

pub struct Machine<T: EventedPty> {
    sender: channel::Sender<Msg>,
    receiver: PeekableReceiver<Msg>,
    pty: T,
    poll: corcovado::Poll,
    terminal: Arc<parking_lot::RwLock<Crosswords<WinEventListener>>>,
    event_listener: WinEventListener,
    route_id: usize,
}

impl<T> Machine<T>
where
    T: EventedPty + Send + 'static,
{
    pub fn new(
        terminal: Arc<parking_lot::RwLock<Crosswords<WinEventListener>>>,
        pty: T,
        event_listener: WinEventListener,
        route_id: usize,
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
        })
    }

    #[inline]
    fn pty_read(&mut self, state: &mut State, buf: &mut [u8]) -> io::Result<()> {
        let mut unprocessed = 0;
        let mut processed = 0;
        let mut terminal = None;

        loop {
            match self.pty.reader().read(&mut buf[unprocessed..]) {
                Ok(0) if unprocessed == 0 => break,
                Ok(got) => unprocessed += got,
                Err(err) => match err.kind() {
                    ErrorKind::Interrupted | ErrorKind::WouldBlock => {
                        if unprocessed == 0 {
                            break;
                        }
                    }
                    _ => return Err(err),
                },
            }

            let terminal = match &mut terminal {
                Some(terminal) => terminal,
                None => {
                    let lock_acquired = match self.terminal.try_write() {
                        None if unprocessed >= READ_BUFFER_SIZE => {
                            self.terminal.write()
                        }
                        None => continue,
                        Some(t) => t,
                    };
                    terminal.insert(lock_acquired)
                }
            };

            state.parser.advance(&mut **terminal, &buf[..unprocessed]);

            processed += unprocessed;
            unprocessed = 0;

            if processed >= MAX_LOCKED_READ {
                break;
            }
        }

        if processed > 0 {
            self.event_listener.mark_dirty();
        }

        Ok(())
    }

    fn drain_recv_channel(&mut self, state: &mut State) -> bool {
        while let Some(msg) = self.receiver.recv() {
            match msg {
                Msg::Input(input) => {
                    state.write_list.push_back(input);
                }
                Msg::Resize(window_size) => {
                    let _ = self.pty.set_winsize(window_size);
                }
                Msg::Shutdown => return false,
            }
        }
        true
    }

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
                            ErrorKind::Interrupted | ErrorKind::WouldBlock => {
                                break 'write_many
                            }
                            _ => return Err(err),
                        }
                    }
                }
            }
        }
        Ok(())
    }

    pub fn channel(&self) -> channel::Sender<Msg> {
        self.sender.clone()
    }

    pub fn spawn(mut self) -> JoinHandle<(Self, State)> {
        Builder::new()
            .name(format!("PTY-win-{}", self.route_id))
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

                self.pty
                    .register(&self.poll, &mut tokens, Ready::readable(), poll_opts)
                    .unwrap();

                let mut events = Events::with_capacity(1024);

                'event_loop: loop {
                    let handler = state.parser.sync_timeout();
                    let timeout = handler
                        .sync_timeout()
                        .map(|st| st.saturating_duration_since(Instant::now()));

                    events.clear();
                    if let Err(err) = self.poll.poll(&mut events, timeout) {
                        match err.kind() {
                            ErrorKind::Interrupted => continue,
                            _ => break 'event_loop,
                        }
                    }

                    if events.is_empty() && self.receiver.peek().is_none() {
                        let mut terminal = self.terminal.write();
                        state.parser.stop_sync(&mut *terminal);
                        self.event_listener.mark_dirty();
                        continue;
                    }

                    if !self.drain_recv_channel(&mut state) {
                        break;
                    }

                    for event in events.iter() {
                        match event.token() {
                            token if token == channel_token => {
                                if !self.channel_event(channel_token, &mut state) {
                                    break 'event_loop;
                                }
                            }
                            token if token == self.pty.child_event_token() => {
                                if let Some(teletypewriter::ChildEvent::Exited) =
                                    self.pty.next_child_event()
                                {
                                    self.terminal.write().exit();
                                    self.event_listener.mark_dirty();
                                    break 'event_loop;
                                }
                            }
                            token
                                if token == self.pty.read_token()
                                    || token == self.pty.write_token() =>
                            {
                                if event.readiness().is_readable() {
                                    if let Err(_err) =
                                        self.pty_read(&mut state, &mut buf)
                                    {
                                        break 'event_loop;
                                    }
                                }

                                if event.readiness().is_writable() {
                                    if let Err(_err) = self.pty_write(&mut state) {
                                        break 'event_loop;
                                    }
                                }
                            }
                            _ => (),
                        }
                    }

                    let mut interest = Ready::readable();
                    if state.needs_write() {
                        interest.insert(Ready::writable());
                    }
                    self.pty
                        .reregister(&self.poll, interest, poll_opts)
                        .unwrap();
                }

                let _ = self.poll.deregister(&self.receiver.rx);
                let _ = self.pty.deregister(&self.poll);

                (self, state)
            })
            .expect("Failed to spawn PTY thread")
    }
}
