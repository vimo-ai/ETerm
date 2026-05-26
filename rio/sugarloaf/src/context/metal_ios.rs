use super::GpuContext;
use crate::sugarloaf::{SugarloafWindow, SugarloafWindowSize};
use objc2::msg_send;
use objc2::runtime::AnyObject;
use skia_safe::{
    gpu::{self, direct_contexts, mtl, DirectContext, SurfaceOrigin},
    ColorType, Surface,
};

pub struct MetalIosContext {
    skia_context: DirectContext,
    layer_ptr: *mut std::ffi::c_void,
    command_queue_ptr: *mut std::ffi::c_void,
    last_gpu_cleanup: std::time::Instant,
    size: SugarloafWindowSize,
    scale: f32,
}

unsafe impl Send for MetalIosContext {}

impl MetalIosContext {
    pub fn new(
        sugarloaf_window: SugarloafWindow,
        _renderer_config: crate::SugarloafRenderer,
    ) -> Self {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};

        let size = sugarloaf_window.size;
        let scale = sugarloaf_window.scale;

        let window_handle = sugarloaf_window.window_handle().unwrap();
        let layer_ptr = match window_handle.as_raw() {
            RawWindowHandle::UiKit(handle) => {
                let ui_view = handle.ui_view.as_ptr() as *mut AnyObject;
                unsafe {
                    let layer: *mut AnyObject = msg_send![ui_view, layer];
                    layer as *mut std::ffi::c_void
                }
            }
            _ => panic!("Unsupported window handle type for MetalIosContext"),
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

            let pixel_format: u64 = 80; // BGRA8Unorm
            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setPixelFormat: pixel_format];

            let _: () =
                msg_send![layer_ptr as *mut AnyObject, setMaximumDrawableCount: 3u64];
        }

        let backend = unsafe {
            mtl::BackendContext::new(device as mtl::Handle, command_queue as mtl::Handle)
        };

        let skia_context = direct_contexts::make_metal(&backend, None)
            .expect("Failed to create Skia DirectContext");

        MetalIosContext {
            skia_context,
            layer_ptr,
            command_queue_ptr: command_queue,
            last_gpu_cleanup: std::time::Instant::now(),
            size,
            scale,
        }
    }
}

impl GpuContext for MetalIosContext {
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
        static mut FRAME_LOG_COUNT: u64 = 0;
        let should_log = unsafe {
            FRAME_LOG_COUNT += 1;
            FRAME_LOG_COUNT <= 5 || FRAME_LOG_COUNT % 120 == 0
        };

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
            if should_log { eprintln!("[metal_ios] begin_frame: drawable is NULL"); }
            return None;
        }

        let texture: *mut AnyObject = unsafe { msg_send![drawable, texture] };
        if texture.is_null() {
            if should_log { eprintln!("[metal_ios] begin_frame: texture is NULL"); }
            return None;
        }

        let tex_width: u64 = unsafe { msg_send![texture, width] };
        let tex_height: u64 = unsafe { msg_send![texture, height] };
        let tex_pixel_format: u64 = unsafe { msg_send![texture, pixelFormat] };

        if should_log {
            eprintln!("[metal_ios] begin_frame: tex={}x{} fmt={}", tex_width, tex_height, tex_pixel_format);
        }

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
                if should_log { eprintln!("[metal_ios] begin_frame: wrap_backend_render_target returned None"); }
                None
            }
        }
    }

    fn end_frame(&mut self, drawable: mtl::Handle) {
        self.skia_context.flush_and_submit();

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
                let _: () = msg_send![command_buffer, waitUntilScheduled];
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
