//! Terminal Domain - 终端领域
//!
//! DDD 分层架构：
//! - **aggregates/** - 聚合根（Terminal）
//! - **events/** - 领域事件（TerminalEvent）
//! - **state.rs** - 核心状态契约（TerminalState）
//! - **views/** - 视图层（GridView, CursorView, SelectionView, SearchView）
//! - **primitives/** - 基础类型（GridPoint）
//!
//! 设计原则：
//! - Terminal 是充血模型，包含所有终端行为
//! - TerminalState 是只读快照，可安全跨线程传递
//! - Views 是零拷贝视图（Arc 共享）
//! - 复用基础设施（teletypewriter/Crosswords/copa）

// 聚合根

pub mod aggregates;

// 事件

pub mod events;

// 核心状态契约

pub mod state;

// 视图层

pub mod views;

// 基础类型

pub mod primitives;

// Re-exports for convenience

pub use aggregates::{Terminal, TerminalId};


pub use events::TerminalEvent;


pub use state::TerminalState;


pub use views::{GridView, RowView, GridData, CursorView, SelectionView, SelectionType, SearchView, MatchRange, HyperlinkHoverView, ImeView};


pub use primitives::{GridPoint, Absolute, AbsolutePoint, Screen, ScreenPoint};
