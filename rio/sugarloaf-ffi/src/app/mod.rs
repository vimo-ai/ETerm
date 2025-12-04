//! Application Layer
//!
//! 职责：协调各领域，处理事件分发
//!
//! 核心原则：
//! - 无业务逻辑，只做编排
//! - 管理终端生命周期（创建/关闭）
//! - 驱动所有终端的 tick 和 render
//! - 处理跨终端的事件路由
//!
//! 核心概念：
//! - `TerminalApp`: 应用服务，顶层协调器
//! - `AppEvent`: 事件，应用级事件（Title/Bell/Close 等）
//!
//! 数据流：
//!
//! ```text
//! Swift/FFI
//!     ↓
//! TerminalApp (协调者)
//!     ├─→ Terminal Domain (状态管理)
//!     ├─→ Render Domain (渲染)
//!     └─→ Compositor Domain (合成)
//!         ↓
//!     Metal drawable
//! ```
//!
//! 关键方法：
//! - `tick() -> [AppEvent]`: 驱动所有终端，返回事件
//! - `render(layouts) -> FinalImage`: 渲染所有终端
//! - `create_terminal() -> TerminalId`: 创建终端
//! - `close_terminal(id)`: 关闭终端
//!
//! 设计原则（参考 ARCHITECTURE_REFACTOR.md Phase 6）：
//! - 薄协调层，不包含业务逻辑
//! - 提供 FFI 友好的接口
//! - 线程安全（支持跨线程调用）
