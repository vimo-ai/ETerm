//! Render Domain
//!
//! 职责：将 TerminalState 转换为可显示的 Frame
//!
//! 核心原则：
//! - 不知道终端逻辑，只处理"状态 → 像素"
//! - 纯函数式（state → frame），容易测试
//! - Overlay 分离架构（Base Layer + Overlays）
//!
//! 核心概念：
//! - `RenderContext`: 服务，渲染上下文，管理缓存
//! - `Frame`: 值对象，渲染输出 = Base + Overlays
//! - `BaseLayer`: 值对象，纯内容图像（不含状态混入）
//! - `Overlay`: 值对象，叠加层（光标/选区/搜索高亮等）
//! - `LineCache`: 内部，hash → LineImage，唯一缓存
//!
//! Overlay 分离架构（核心创新）：
//!
//! ```text
//! ┌─────────────────────────────────────┐
//! │          最终 Surface               │
//! ├─────────────────────────────────────┤
//! │  Overlay 3: 搜索高亮 (半透明矩形)    │
//! │  Overlay 2: 选区 (半透明矩形)        │
//! │  Overlay 1: 光标 (Block/Caret/...)  │
//! ├─────────────────────────────────────┤
//! │  Base Layer: 纯内容 Image           │
//! │  (hash → Image, 不含任何状态)        │
//! └─────────────────────────────────────┘
//! ```
//!
//! 收益：
//! - Base Layer 缓存命中率极高（内容很少变）
//! - Overlay 每帧重绘，但只是简单矩形
//! - 添加新 Overlay 不影响缓存
//! - 状态变化（光标移动/选区变化）不导致 Base Layer 缓存失效
//!
//! 设计原则（参考 ARCHITECTURE_REFACTOR.md Phase 2）：
//! - 单一缓存策略（LineCache）
//! - Overlay 是简单几何数据（Rect + Color）
//! - 复用 Skia primitives（绘制 API）

pub mod frame;

pub use frame::{Frame, BaseLayer, Overlay};
