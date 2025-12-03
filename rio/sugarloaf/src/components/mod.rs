//! # Components - 渲染组件
//!
//! 当前状态: 仅保留 Skia 渲染所需的数据结构
//!
//! 已清理 (2025-12):
//! - filters: WGPU 滤镜系统
//! - layer: WGPU layer 渲染器
//! - quad: WGPU quad 渲染器 (保留 Quad 数据结构)
//! - rich_text: WGPU 文本渲染器
//!
//! TODO: 待清理项 (第二阶段):
//! - [ ] core 模块中是否有冗余的抽象层

pub mod core;
// pub mod filters; // WGPU-based filters
// pub mod layer; // WGPU-based renderer
// pub mod quad; // WGPU-based renderer
// pub mod rich_text; // WGPU-based renderer

// Re-export data structures needed by Skia renderer
use bytemuck::{Pod, Zeroable};

/// The properties of a quad (used by Skia renderer for backgrounds/borders)
#[derive(Clone, Copy, Debug, Pod, Zeroable, PartialEq, Default)]
#[repr(C)]
pub struct Quad {
    pub color: [f32; 4],
    pub position: [f32; 2],
    pub size: [f32; 2],
    pub border_color: [f32; 4],
    pub border_radius: [f32; 4],
    pub border_width: f32,
    pub shadow_color: [f32; 4],
    pub shadow_offset: [f32; 2],
    pub shadow_blur_radius: f32,
}
