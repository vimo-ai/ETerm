//! Compositor Domain
//!
//! 职责：将多个终端的 Frame 合成到最终窗口
//!
//! 核心原则：
//! - 不知道单个终端的细节，只处理布局和合成
//! - 支持多终端场景（Split View）
//! - 处理窗口级布局计算
//!
//! 核心概念：
//! - `Compositor`: 服务，合成器
//! - `FinalImage`: 值对象，最终输出到窗口的图像
//! - `Layout`: 布局信息（每个终端的 Rect）
//!
//! 合成流程：
//!
//! ```text
//! Terminal 1 Frame (Rect1) ┐
//! Terminal 2 Frame (Rect2) ├─→ Compositor → FinalImage → Metal drawable → 屏幕
//! Terminal 3 Frame (Rect3) ┘
//! ```
//!
//! 设计原则（参考 ARCHITECTURE_REFACTOR.md Phase 5）：
//! - 简单的 blit 合成
//! - 支持多终端布局
//! - 复用 Skia 合成 API
