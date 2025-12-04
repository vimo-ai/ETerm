//! Render Domain
//!
//! 职责：将 TerminalState 转换为可显示的 Frame（最终图像）
//!
//! 核心原则：
//! - 不知道终端逻辑，只处理"状态 → 像素"
//! - 纯函数式（state → frame），容易测试
//! - 两层缓存架构（高性能渲染）
//!
//! 核心概念：
//! - `Renderer`: 渲染引擎，管理缓存和渲染流程
//! - `RenderContext`: 渲染上下文（坐标转换、配置参数）
//! - `LineCache`: 两层缓存（文本布局 + 最终渲染）
//! - `GlyphLayout`: 字形布局（字体选择 + 文本整形结果）
//!
//! 两层缓存架构（核心创新）：
//!
//! ```text
//! 外层缓存：text_hash → GlyphLayout
//!   ↓ 跳过昂贵的字体选择 + 文本整形（70% 性能提升）
//!
//! 内层缓存：state_hash → SkImage
//!   ↓ 跳过所有操作（100% 性能提升，零开销）
//!
//! 剪枝优化：state_hash 只包含影响本行的状态参数
//!   - 光标在其他行移动 → 本行 state_hash 不变 → 内层缓存命中
//! ```
//!
//! 性能收益（参考 ARCHITECTURE_REFACTOR.md Phase 2）：
//! - 光标移动：12x 性能提升（24 行 × 100% → 2 行 × 30%）
//! - 选区拖动：3x+ 性能提升（跳过 70% 昂贵操作）
//! - 内层缓存命中：零开销（0% 耗时）
//!
//! Phase 2 实现计划：
//! - Step 1: RenderContext + 坐标转换
//! - Step 2: 两层缓存结构（LineCache）
//! - Step 3: Hash 计算（剪枝优化）
//! - Step 4: 渲染流程（Mock 版本）
//! - Step 5: 关键测试（验证架构）

// Phase 2: 实现各个模块
// TODO: 添加 context.rs - RenderContext
// TODO: 添加 cache.rs - LineCache（两层缓存）
// TODO: 添加 renderer.rs - Renderer（渲染引擎）
