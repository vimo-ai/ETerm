use crate::clipboard::ClipboardType;
use crate::colors::ColorRgb;
use crate::graphics::UpdateQueues;
use crate::grid::Scroll;
use crate::pos::{Direction, Pos};
use crate::search::{Match, RegexSearch};
use crate::crosswords::LineDamage;
use std::collections::{BTreeSet, VecDeque};
use std::fmt::Debug;
use std::fmt::Formatter;
use std::sync::Arc;

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub struct WindowId(u64);

impl From<u64> for WindowId {
    fn from(id: u64) -> Self {
        WindowId(id)
    }
}

#[allow(clippy::result_unit_err)]
pub trait EventLoopProxy<T>: Clone {
    fn send_event(&self, event: T) -> Result<(), ()>;
}

#[derive(Debug, Clone)]
pub enum Event<T> {
    UserEvent(T),
}

#[derive(Debug, Clone)]
pub enum RioEventType {
    Rio(RioEvent),
    Frame,
}

#[derive(Debug, Eq, PartialEq)]
pub enum ClickState {
    None,
    Click,
    DoubleClick,
    TripleClick,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalDamage {
    Full,
    Partial(BTreeSet<LineDamage>),
    CursorOnly,
}

#[derive(Clone)]
pub enum RioEvent {
    PrepareRender(u64),
    PrepareRenderOnRoute(u64, usize),
    PrepareUpdateConfig,
    Render,
    RenderRoute(usize),
    Wakeup(usize),
    UpdateGraphics {
        route_id: usize,
        queues: UpdateQueues,
    },
    Paste,
    Copy(String),
    UpdateFontSize(u8),
    Scroll(Scroll),
    ToggleFullScreen,
    Minimize(bool),
    Hide,
    HideOtherApplications,
    UpdateConfig,
    CreateWindow,
    CloseWindow,
    CreateNativeTab(Option<String>),
    CreateConfigEditor,
    SelectNativeTabByIndex(usize),
    SelectNativeTabLast,
    SelectNativeTabNext,
    SelectNativeTabPrev,
    ReportToAssistant(String),
    MouseCursorDirty,
    Title(String),
    TitleWithSubtitle(String, String),
    ResetTitle,
    CurrentDirectoryChanged(std::path::PathBuf),
    CommandExecuted(String),
    ShellCommandStarted {
        command: String,
        cwd: Option<String>,
        git_branch: Option<String>,
    },
    ShellCommandFinished {
        exit_code: Option<u8>,
    },
    ClipboardStore(ClipboardType, String),
    ClipboardLoad(
        ClipboardType,
        Arc<dyn Fn(&str) -> String + Sync + Send + 'static>,
    ),
    ColorRequest(
        usize,
        Arc<dyn Fn(ColorRgb) -> String + Sync + Send + 'static>,
    ),
    PtyWrite(String),
    TextAreaSizeRequest(Arc<dyn Fn(crate::event::WinsizeInfo) -> String + Sync + Send + 'static>),
    CursorBlinkingChange,
    CursorBlinkingChangeOnRoute(usize),
    Bell,
    Exit,
    Quit,
    CloseTerminal(usize),
    BlinkCursor(u64, usize),
    UpdateTitles,
    Noop,
}

#[derive(Debug, Clone, Copy)]
pub struct WinsizeInfo {
    pub cols: u16,
    pub rows: u16,
    pub width: u16,
    pub height: u16,
}

impl Debug for RioEvent {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            RioEvent::ClipboardStore(ty, text) => {
                write!(f, "ClipboardStore({ty:?}, {text})")
            }
            RioEvent::ClipboardLoad(ty, _) => write!(f, "ClipboardLoad({ty:?})"),
            RioEvent::TextAreaSizeRequest(_) => write!(f, "TextAreaSizeRequest"),
            RioEvent::ColorRequest(index, _) => write!(f, "ColorRequest({index})"),
            RioEvent::PtyWrite(text) => write!(f, "PtyWrite({text})"),
            RioEvent::Title(title) => write!(f, "Title({title})"),
            RioEvent::TitleWithSubtitle(title, subtitle) => {
                write!(f, "TitleWithSubtitle({title}, {subtitle})")
            }
            RioEvent::Minimize(cond) => write!(f, "Minimize({cond})"),
            RioEvent::Hide => write!(f, "Hide)"),
            RioEvent::HideOtherApplications => write!(f, "HideOtherApplications)"),
            RioEvent::CursorBlinkingChange => write!(f, "CursorBlinkingChange"),
            RioEvent::CursorBlinkingChangeOnRoute(route_id) => {
                write!(f, "CursorBlinkingChangeOnRoute {route_id}")
            }
            RioEvent::MouseCursorDirty => write!(f, "MouseCursorDirty"),
            RioEvent::ResetTitle => write!(f, "ResetTitle"),
            RioEvent::CurrentDirectoryChanged(path) => {
                write!(f, "CurrentDirectoryChanged({:?})", path)
            }
            RioEvent::CommandExecuted(cmd) => write!(f, "CommandExecuted({cmd})"),
            RioEvent::PrepareUpdateConfig => write!(f, "PrepareUpdateConfig"),
            RioEvent::PrepareRender(millis) => write!(f, "PrepareRender({millis})"),
            RioEvent::PrepareRenderOnRoute(millis, route) => {
                write!(f, "PrepareRender({millis} on route {route})")
            }
            RioEvent::Render => write!(f, "Render"),
            RioEvent::RenderRoute(route) => write!(f, "Render route {route}"),
            RioEvent::Wakeup(route) => {
                write!(f, "Wakeup route {route}")
            }
            RioEvent::Scroll(scroll) => write!(f, "Scroll {scroll:?}"),
            RioEvent::Bell => write!(f, "Bell"),
            RioEvent::Exit => write!(f, "Exit"),
            RioEvent::Quit => write!(f, "Quit"),
            RioEvent::CloseTerminal(route) => write!(f, "CloseTerminal {route}"),
            RioEvent::CreateWindow => write!(f, "CreateWindow"),
            RioEvent::CloseWindow => write!(f, "CloseWindow"),
            RioEvent::CreateNativeTab(_) => write!(f, "CreateNativeTab"),
            RioEvent::SelectNativeTabByIndex(tab_index) => {
                write!(f, "SelectNativeTabByIndex({tab_index})")
            }
            RioEvent::SelectNativeTabLast => write!(f, "SelectNativeTabLast"),
            RioEvent::SelectNativeTabNext => write!(f, "SelectNativeTabNext"),
            RioEvent::SelectNativeTabPrev => write!(f, "SelectNativeTabPrev"),
            RioEvent::CreateConfigEditor => write!(f, "CreateConfigEditor"),
            RioEvent::UpdateConfig => write!(f, "ReloadConfiguration"),
            RioEvent::ReportToAssistant(report) => {
                write!(f, "ReportToAssistant({})", report)
            }
            RioEvent::ToggleFullScreen => write!(f, "FullScreen"),
            RioEvent::BlinkCursor(timeout, route_id) => {
                write!(f, "BlinkCursor {timeout} {route_id}")
            }
            RioEvent::UpdateTitles => write!(f, "UpdateTitles"),
            RioEvent::Noop => write!(f, "Noop"),
            RioEvent::Copy(_) => write!(f, "Copy"),
            RioEvent::Paste => write!(f, "Paste"),
            RioEvent::UpdateFontSize(action) => write!(f, "UpdateFontSize({action:?})"),
            RioEvent::UpdateGraphics { route_id, .. } => {
                write!(f, "UpdateGraphics({route_id})")
            }
            RioEvent::ShellCommandStarted { command, .. } => {
                write!(f, "ShellCommandStarted({command})")
            }
            RioEvent::ShellCommandFinished { exit_code, .. } => {
                write!(f, "ShellCommandFinished({exit_code:?})")
            }
        }
    }
}

pub trait EventListener {
    fn event(&self) -> (Option<RioEvent>, bool);

    fn send_event(&self, _event: RioEvent, _id: WindowId) {
        eprintln!("[EventListener] DEFAULT send_event called - THIS IS A BUG!");
    }

    fn send_event_with_high_priority(&self, _event: RioEvent, _id: WindowId) {}

    fn send_redraw(&self, _id: WindowId) {}

    fn send_global_event(&self, _event: RioEvent) {}
}

#[derive(Clone)]
pub struct VoidListener;

impl From<RioEvent> for RioEventType {
    fn from(rio_event: RioEvent) -> Self {
        Self::Rio(rio_event)
    }
}

impl EventListener for VoidListener {
    fn event(&self) -> (std::option::Option<RioEvent>, bool) {
        (None, false)
    }
}

#[derive(Debug)]
pub struct SearchState {
    pub direction: Direction,
    pub history_index: Option<usize>,
    pub display_offset_delta: i32,
    pub origin: Pos,
    pub focused_match: Option<Match>,
    pub all_matches: Vec<Match>,
    pub focused_index: usize,
    pub history: VecDeque<String>,
    pub dfas: Option<RegexSearch>,
    pub is_regex: bool,
    pub case_sensitive: bool,
}

impl SearchState {
    pub fn regex(&self) -> Option<&String> {
        self.history_index.and_then(|index| self.history.get(index))
    }

    pub fn direction(&self) -> Direction {
        self.direction
    }

    pub fn focused_match(&self) -> Option<&Match> {
        self.focused_match.as_ref()
    }

    pub fn clear_focused_match(&mut self) {
        self.focused_match = None;
    }

    pub fn dfas_mut(&mut self) -> Option<&mut RegexSearch> {
        self.dfas.as_mut()
    }

    pub fn dfas(&self) -> Option<&RegexSearch> {
        self.dfas.as_ref()
    }

    pub fn regex_mut(&mut self) -> Option<&mut String> {
        self.history_index
            .and_then(move |index| self.history.get_mut(index))
    }
}

impl Default for SearchState {
    fn default() -> Self {
        Self {
            direction: Direction::Right,
            display_offset_delta: Default::default(),
            focused_match: Default::default(),
            all_matches: Default::default(),
            focused_index: Default::default(),
            history_index: Default::default(),
            history: Default::default(),
            origin: Default::default(),
            dfas: Default::default(),
            is_regex: false,
            case_sensitive: false,
        }
    }
}

pub mod sync {
    use parking_lot::{Mutex, MutexGuard};

    pub struct FairMutex<T> {
        data: Mutex<T>,
        next: Mutex<()>,
    }

    impl<T> FairMutex<T> {
        pub fn new(data: T) -> FairMutex<T> {
            FairMutex {
                data: Mutex::new(data),
                next: Mutex::new(()),
            }
        }

        pub fn lease(&self) -> MutexGuard<'_, ()> {
            self.next.lock()
        }

        pub fn lock(&self) -> MutexGuard<'_, T> {
            let _next = self.next.lock();
            self.data.lock()
        }

        pub fn lock_unfair(&self) -> MutexGuard<'_, T> {
            self.data.lock()
        }

        pub fn try_lock_unfair(&self) -> Option<MutexGuard<'_, T>> {
            self.data.try_lock()
        }
    }
}
