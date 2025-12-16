//! Infrastructure Layer - 基础设施层
//!
//! 职责：提供底层基础设施支持
//!
//! 模块：
//! - spsc_queue: 无锁单生产者单消费者队列
//! - atomic_cache: 原子缓存（光标位置、脏标记等）
//! - stress_tests: 压力测试（仅测试构建）

pub mod spsc_queue;
pub mod atomic_cache;
pub mod selection_overlay;

#[cfg(test)]
mod stress_tests;

#[cfg(test)]
mod pipeline_bench;

pub use spsc_queue::SpscQueue;
pub use atomic_cache::{
    AtomicCursorCache,
    AtomicDirtyFlag,
    AtomicSelectionCache,
    AtomicTitleCache,
    AtomicScrollCache,
};
pub use selection_overlay::{SelectionOverlay, SelectionSnapshot, SelectionType};
