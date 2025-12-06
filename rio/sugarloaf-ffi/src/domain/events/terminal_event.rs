//! Terminal Events
//!
//! 职责：定义终端事件类型
//!
//! 核心原则：
//! - 简化的事件类型，只包含必要信息
//! - 从 rio-backend 的 RioEvent 转换而来


#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalEvent {
    /// 终端响铃
    Bell,

    /// 标题变化
    Title(String),

    /// 终端退出
    Exit,

    /// 需要渲染（唤醒）
    Wakeup,
}
