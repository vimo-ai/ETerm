// Copyright (c) 2023-present, Raphael Amorim.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
//! # MetalContext - Skia Metal backend for macOS

use super::GpuContext;
use crate::sugarloaf::{SugarloafWindow, SugarloafWindowSize};
use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject};
use skia_safe::{
    gpu::{self, direct_contexts, mtl, DirectContext, SurfaceOrigin},
    ColorType, Surface,
};

/// macOS rendering context backed by Metal + Skia.
///
/// `FrameHandle` is an `mtl::Handle` pointing to the current CAMetalDrawable.
pub struct MetalContext {
    skia_context: DirectContext,
    layer_ptr: *mut std::ffi::c_void,
    command_queue_ptr: *mut std::ffi::c_void,
    /// Timestamp of last Skia GPU cache cleanup (throttled to avoid per-frame overhead)
    last_gpu_cleanup: std::time::Instant,
    size: SugarloafWindowSize,
    scale: f32,
}

// SAFETY: Metal objects are thread-safe when accessed via command queues.
// The raw pointers reference Metal objects managed by the Metal runtime
// which handles thread safety through command buffer serialization.
unsafe impl Send for MetalContext {}

impl MetalContext {
    pub fn new(
        sugarloaf_window: SugarloafWindow,
        _renderer_config: crate::SugarloafRenderer,
    ) -> Self {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};

        let size = sugarloaf_window.size;
        let scale = sugarloaf_window.scale;

        let window_handle = sugarloaf_window.window_handle().unwrap();
        let layer_ptr = match window_handle.as_raw() {
            RawWindowHandle::AppKit(handle) => {
                let ns_view = handle.ns_view.as_ptr() as *mut AnyObject;

                unsafe {
                    let layer: *mut AnyObject = msg_send![ns_view, layer];

                    let metal_layer_class =
                        AnyClass::get("CAMetalLayer").expect("CAMetalLayer class not found");
                    let is_metal_layer: bool =
                        msg_send![layer, isKindOfClass: metal_layer_class];

                    if is_metal_layer {
                        layer as *mut std::ffi::c_void
                    } else {
                        let metal_layer: *mut AnyObject = msg_send![metal_layer_class, layer];
                        let _: () = msg_send![ns_view, setLayer: metal_layer];
                        let _: () = msg_send![ns_view, setWantsLayer: true];
                        metal_layer as *mut std::ffi::c_void
                    }
                }
            }
            _ => panic!("Unsupported window handle type for MetalContext"),
        };

        let device: *mut std::ffi::c_void =
            unsafe { msg_send![layer_ptr as *mut AnyObject, device] };

        let device = if device.is_null() {
            extern "C" {
                fn MTLCreateSystemDefaultDevice() -> *mut std::ffi::c_void;
            }
            unsafe {
                let default_device = MTLCreateSystemDefaultDevice();
                let _: () = msg_send![layer_ptr as *mut AnyObject, setDevice: default_device as *mut AnyObject];
                default_device
            }
        } else {
            device
        };

        let command_queue: *mut std::ffi::c_void =
            unsafe { msg_send![device as *mut AnyObject, newCommandQueue] };

        if command_queue.is_null() {
            panic!("Failed to create Metal command queue");
        }

        unsafe {
            use objc2_foundation::CGSize;
            let drawable_size = CGSize::new(
                (size.width * scale) as f64,
                (size.height * scale) as f64,
            );
            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setDrawableSize: drawable_size];
            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setContentsScale: scale as f64];

            // Pixel format 80 = BGRA8Unorm (Skia requires non-sRGB format)
            let pixel_format: u64 = 80;
            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setPixelFormat: pixel_format];

            // Triple buffering: 1 displayed + 1 pending + 1 available
            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setMaximumDrawableCount: 3u64];

            // Disable displaySync to avoid nextDrawable blocking on VSync
            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setDisplaySyncEnabled: false];
        }

        let backend = unsafe {
            mtl::BackendContext::new(device as mtl::Handle, command_queue as mtl::Handle)
        };

        let skia_context = direct_contexts::make_metal(&backend, None)
            .expect("Failed to create Skia DirectContext");

        tracing::info!("MetalContext initialized successfully");

        MetalContext {
            skia_context,
            layer_ptr,
            command_queue_ptr: command_queue,
            last_gpu_cleanup: std::time::Instant::now(),
            size,
            scale,
        }
    }
}

impl GpuContext for MetalContext {
    type FrameHandle = mtl::Handle;

    fn resize(&mut self, width: u32, height: u32) {
        self.size.width = width as f32;
        self.size.height = height as f32;

        unsafe {
            use objc2_foundation::CGSize;
            let drawable_size = CGSize::new(
                (width as f32 * self.scale) as f64,
                (height as f32 * self.scale) as f64,
            );
            let _: () =
                msg_send![self.layer_ptr as *mut AnyObject, setDrawableSize: drawable_size];
        }
    }

    fn begin_frame(&mut self) -> Option<(Surface, mtl::Handle)> {
        // Ensure correct pixel format before each frame
        unsafe {
            let current_format: u64 =
                msg_send![self.layer_ptr as *mut AnyObject, pixelFormat];
            if current_format != 80 {
                let _: () =
                    msg_send![self.layer_ptr as *mut AnyObject, setPixelFormat: 80u64];
            }
        }

        let drawable: *mut AnyObject =
            unsafe { msg_send![self.layer_ptr as *mut AnyObject, nextDrawable] };

        if drawable.is_null() {
            return None;
        }

        let texture: *mut AnyObject = unsafe { msg_send![drawable, texture] };
        if texture.is_null() {
            return None;
        }

        let tex_width: u64 = unsafe { msg_send![texture, width] };
        let tex_height: u64 = unsafe { msg_send![texture, height] };
        let tex_pixel_format: u64 = unsafe { msg_send![texture, pixelFormat] };

        // Skip frame if texture format is wrong
        if tex_pixel_format != 80 {
            return None;
        }

        let texture_info = unsafe { mtl::TextureInfo::new(texture as mtl::Handle) };

        let backend_rt = gpu::backend_render_targets::make_mtl(
            (tex_width as i32, tex_height as i32),
            &texture_info,
        );

        let surface = gpu::surfaces::wrap_backend_render_target(
            &mut self.skia_context,
            &backend_rt,
            SurfaceOrigin::TopLeft,
            ColorType::BGRA8888,
            None,
            None,
        );

        match surface {
            Some(s) => Some((s, drawable as mtl::Handle)),
            None => {
                tracing::error!("Failed to create Skia surface");
                None
            }
        }
    }

    fn end_frame(&mut self, drawable: mtl::Handle) {
        self.skia_context.flush_and_submit();

        // Throttled cleanup: every 120s, purge GPU resources unused for 5 minutes.
        // Skia's built-in LRU evicts at budget (default 256MB); this is supplementary.
        if self.last_gpu_cleanup.elapsed() >= std::time::Duration::from_secs(120) {
            self.skia_context
                .perform_deferred_cleanup(std::time::Duration::from_secs(300), None);
            self.last_gpu_cleanup = std::time::Instant::now();
        }

        unsafe {
            let command_buffer: *mut AnyObject =
                msg_send![self.command_queue_ptr as *mut AnyObject, commandBuffer];

            if !command_buffer.is_null() {
                let _: () =
                    msg_send![command_buffer, presentDrawable: drawable as *mut AnyObject];
                let _: () = msg_send![command_buffer, commit];
                // Back-pressure: wait until GPU scheduling completes (lighter than
                // waitUntilCompleted, does not block until GPU execution finishes)
                let _: () = msg_send![command_buffer, waitUntilScheduled];
            } else {
                tracing::error!("Failed to create command buffer for presentation");
            }
        }
    }

    fn skia_context(&self) -> &DirectContext {
        &self.skia_context
    }

    fn skia_context_mut(&mut self) -> &mut DirectContext {
        &mut self.skia_context
    }

    fn size(&self) -> SugarloafWindowSize {
        self.size
    }

    fn scale(&self) -> f32 {
        self.scale
    }

    fn set_scale(&mut self, scale: f32) {
        self.scale = scale;
    }
}
