//! Terminal Domain
//!
//! 职责：管理终端状态，处理 PTY I/O
//!
//! 核心原则：
//! - 不知道渲染的存在，只产出状态
//! - 充血模型（Terminal 聚合根包含所有行为）
//! - 状态是只读快照（TerminalState），跨线程安全
//!
//! 核心概念：
//! - `Terminal`: 聚合根，包含所有终端行为（tick, write, resize, scroll, selection, search 等）
//! - `TerminalState`: 值对象，只读快照，包含 grid/cursor/selection/search 等所有状态
//! - `GridView`: 值对象，网格视图，支持行哈希和延迟加载
//! - `RowView`: 值对象，行视图，延迟加载 cells
//! - `TerminalEvent`: 事件，Bell/Title/Exit 等
//!
//! 设计原则（参考 ARCHITECTURE_REFACTOR.md Phase 1）：
//! - 复用基础设施（teletypewriter/Crosswords/copa）
//! - 封装而非重写
//! - 提供清晰的充血模型接口
//!

pub mod point;
pub mod state;
pub mod cursor;
pub mod grid;
pub mod selection;
pub mod search;

// Re-export key types
pub use point::{AbsolutePoint, Absolute, GridPoint, Screen, ScreenPoint};
pub use state::TerminalState;
pub use cursor::CursorView;
pub use grid::{GridView, RowView, GridData};
pub use selection::{SelectionView, SelectionPoint, SelectionType};
pub use search::{SearchView, MatchRange};
