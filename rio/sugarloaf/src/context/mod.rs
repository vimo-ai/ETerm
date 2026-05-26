// Copyright (c) 2023-present, Raphael Amorim.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
//! # Context - Skia GPU rendering context (platform-dispatched)
//!
//! Each platform has its own backend implementation:
//! - macOS: Metal via `MetalContext`
//! - Windows: Direct3D 12 via `Dx12Context`
//!
//! The `Context` type alias selects the correct implementation at compile time.
//! All backends implement the `GpuContext` trait for a uniform rendering API.

use crate::sugarloaf::SugarloafWindowSize;
use skia_safe::{gpu::DirectContext, Surface};

/// Platform-agnostic GPU rendering context trait.
///
/// Each platform backend (Metal, D3D12) implements this trait to provide
/// Skia-based rendering through a consistent interface.
pub trait GpuContext {
    /// Opaque handle representing a single in-flight frame.
    /// Returned by `begin_frame()` and consumed by `end_frame()`.
    type FrameHandle;

    /// Resize the rendering surface (in logical pixels).
    fn resize(&mut self, width: u32, height: u32);

    /// Acquire the next drawable frame. Returns a Skia `Surface` to draw on
    /// and an opaque handle to pass to `end_frame()` for presentation.
    /// Returns `None` if no drawable is available (e.g. window minimized).
    fn begin_frame(&mut self) -> Option<(Surface, Self::FrameHandle)>;

    /// Present the frame identified by `handle` and perform post-frame cleanup.
    fn end_frame(&mut self, handle: Self::FrameHandle);

    /// Borrow the Skia `DirectContext` (for read-only GPU queries).
    fn skia_context(&self) -> &DirectContext;

    /// Mutably borrow the Skia `DirectContext` (for flushing, cache management, etc.).
    fn skia_context_mut(&mut self) -> &mut DirectContext;

    /// Current logical size of the rendering surface.
    fn size(&self) -> SugarloafWindowSize;

    /// Current display scale factor (e.g. 2.0 for Retina).
    fn scale(&self) -> f32;

    /// Update the display scale factor.
    fn set_scale(&mut self, scale: f32);

    /// Get raw pointer to the platform swap chain (for composition).
    /// Returns null on platforms that don't support it.
    fn swap_chain_ptr(&self) -> *mut std::ffi::c_void {
        std::ptr::null_mut()
    }
}

// ===== Platform dispatch =====

#[cfg(target_os = "macos")]
mod metal;
#[cfg(target_os = "macos")]
pub use metal::MetalContext;
#[cfg(target_os = "macos")]
pub type Context = MetalContext;

#[cfg(target_os = "ios")]
mod metal_ios;
#[cfg(target_os = "ios")]
pub use metal_ios::MetalIosContext;
#[cfg(target_os = "ios")]
pub type Context = MetalIosContext;

#[cfg(target_os = "windows")]
mod dx12;
#[cfg(target_os = "windows")]
pub use dx12::Dx12Context;
#[cfg(target_os = "windows")]
pub type Context = Dx12Context;
