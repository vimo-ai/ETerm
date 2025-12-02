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
