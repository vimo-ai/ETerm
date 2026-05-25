use bitflags::bitflags;
use serde::{Deserialize, Serialize};

#[derive(Default, Clone, Serialize, Deserialize, Copy, Debug, Eq, PartialEq)]
pub enum CursorShape {
    #[default]
    #[serde(alias = "block")]
    Block,
    #[serde(alias = "underline")]
    Underline,
    #[serde(alias = "beam")]
    Beam,
    #[serde(alias = "hidden")]
    Hidden,
}

impl CursorShape {
    pub fn from_char(c: char) -> CursorShape {
        match c {
            '_' => CursorShape::Underline,
            '|' => CursorShape::Beam,
            _ => CursorShape::Block,
        }
    }
}

impl From<CursorShape> for char {
    fn from(value: CursorShape) -> Self {
        match value {
            CursorShape::Underline => '_',
            CursorShape::Beam => '|',
            _ => '▇',
        }
    }
}

#[derive(Debug)]
pub enum ClearMode {
    Below,
    Above,
    All,
    Saved,
}

#[derive(Debug)]
pub enum TabulationClearMode {
    Current,
    All,
}

#[derive(Debug)]
pub enum LineClearMode {
    Right,
    Left,
    All,
}

bitflags! {
    #[derive(Default, Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct KeyboardModes : u8 {
        const NO_MODE                 = 0b0000_0000;
        const DISAMBIGUATE_ESC_CODES  = 0b0000_0001;
        const REPORT_EVENT_TYPES      = 0b0000_0010;
        const REPORT_ALTERNATE_KEYS   = 0b0000_0100;
        const REPORT_ALL_KEYS_AS_ESC  = 0b0000_1000;
        const REPORT_ASSOCIATED_TEXT  = 0b0001_0000;
    }
}

#[repr(u8)]
#[derive(Default, Clone, Copy, PartialEq, Eq)]
pub enum KeyboardModesApplyBehavior {
    #[default]
    Replace,
    Union,
    Difference,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Mode {
    Named(NamedMode),
    Unknown(u16),
}

impl Mode {
    pub fn new(mode: u16) -> Self {
        match mode {
            4 => Self::Named(NamedMode::Insert),
            20 => Self::Named(NamedMode::LineFeedNewLine),
            _ => Self::Unknown(mode),
        }
    }

    pub fn raw(self) -> u16 {
        match self {
            Self::Named(named) => named as u16,
            Self::Unknown(mode) => mode,
        }
    }
}

impl From<NamedMode> for Mode {
    fn from(value: NamedMode) -> Self {
        Self::Named(value)
    }
}

#[repr(u16)]
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum NamedMode {
    Insert = 4,
    LineFeedNewLine = 20,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum PrivateMode {
    Named(NamedPrivateMode),
    Unknown(u16),
}

impl PrivateMode {
    pub fn new(mode: u16) -> Self {
        match mode {
            1 => Self::Named(NamedPrivateMode::CursorKeys),
            3 => Self::Named(NamedPrivateMode::ColumnMode),
            6 => Self::Named(NamedPrivateMode::Origin),
            7 => Self::Named(NamedPrivateMode::LineWrap),
            12 => Self::Named(NamedPrivateMode::BlinkingCursor),
            25 => Self::Named(NamedPrivateMode::ShowCursor),
            1000 => Self::Named(NamedPrivateMode::ReportMouseClicks),
            1002 => Self::Named(NamedPrivateMode::ReportCellMouseMotion),
            1003 => Self::Named(NamedPrivateMode::ReportAllMouseMotion),
            1004 => Self::Named(NamedPrivateMode::ReportFocusInOut),
            1005 => Self::Named(NamedPrivateMode::Utf8Mouse),
            1006 => Self::Named(NamedPrivateMode::SgrMouse),
            1007 => Self::Named(NamedPrivateMode::AlternateScroll),
            1042 => Self::Named(NamedPrivateMode::UrgencyHints),
            1049 => Self::Named(NamedPrivateMode::SwapScreenAndSetRestoreCursor),
            2004 => Self::Named(NamedPrivateMode::BracketedPaste),
            2026 => Self::Named(NamedPrivateMode::SyncUpdate),
            _ => Self::Unknown(mode),
        }
    }

    pub fn raw(self) -> u16 {
        match self {
            Self::Named(named) => named as u16,
            Self::Unknown(mode) => mode,
        }
    }
}

impl From<NamedPrivateMode> for PrivateMode {
    fn from(value: NamedPrivateMode) -> Self {
        Self::Named(value)
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum NamedPrivateMode {
    CursorKeys = 1,
    ColumnMode = 3,
    Origin = 6,
    LineWrap = 7,
    BlinkingCursor = 12,
    ShowCursor = 25,
    ReportMouseClicks = 1000,
    ReportCellMouseMotion = 1002,
    ReportAllMouseMotion = 1003,
    ReportFocusInOut = 1004,
    Utf8Mouse = 1005,
    SgrMouse = 1006,
    AlternateScroll = 1007,
    UrgencyHints = 1042,
    SwapScreenAndSetRestoreCursor = 1049,
    BracketedPaste = 2004,
    SyncUpdate = 2026,
}
