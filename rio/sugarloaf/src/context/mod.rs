// Copyright (c) 2023-present, Raphael Amorim.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
// Hybrid Context: Skia for rendering, WGPU fields kept for compatibility

use crate::sugarloaf::{SugarloafWindow, SugarloafWindowSize};

#[cfg(target_os = "macos")]
use cocoa::base::id;
#[cfg(target_os = "macos")]
use skia_safe::{
    gpu::{self, direct_contexts, mtl, DirectContext, SurfaceOrigin},
    ColorType, Surface,
};

pub struct Context<'a> {
    // ===== Skia fields (used for actual rendering) =====
    #[cfg(target_os = "macos")]
    pub skia_context: DirectContext,

    #[cfg(target_os = "macos")]
    layer_ptr: *mut std::ffi::c_void,

    #[cfg(target_os = "macos")]
    command_queue_ptr: *mut std::ffi::c_void,

    pub size: SugarloafWindowSize,
    pub scale: f32,

    // ===== WGPU fields (kept for filters/rio-backend compatibility) =====
    #[cfg(feature = "wgpu-backend")]
    pub device: wgpu::Device,
    #[cfg(feature = "wgpu-backend")]
    pub surface: wgpu::Surface<'a>,
    #[cfg(feature = "wgpu-backend")]
    pub queue: wgpu::Queue,
    #[cfg(feature = "wgpu-backend")]
    pub format: wgpu::TextureFormat,
    #[cfg(feature = "wgpu-backend")]
    alpha_mode: wgpu::CompositeAlphaMode,
    #[cfg(feature = "wgpu-backend")]
    pub adapter_info: wgpu::AdapterInfo,
    #[cfg(feature = "wgpu-backend")]
    surface_caps: wgpu::SurfaceCapabilities,
    #[cfg(feature = "wgpu-backend")]
    pub supports_f16: bool,
    #[cfg(feature = "wgpu-backend")]
    pub colorspace: crate::Colorspace,
    #[cfg(feature = "wgpu-backend")]
    pub max_texture_dimension_2d: u32,

    #[allow(dead_code)]
    phantom: std::marker::PhantomData<&'a ()>,
}

#[cfg(target_os = "macos")]
impl Context<'_> {
    pub fn new<'a>(
        sugarloaf_window: SugarloafWindow,
        renderer_config: crate::SugarloafRenderer,
    ) -> Context<'a> {
        use raw_window_handle::{HasDisplayHandle, HasWindowHandle, RawWindowHandle};

        let size = sugarloaf_window.size;
        let scale = sugarloaf_window.scale;

        // ===== Initialize Skia =====
        let window_handle = sugarloaf_window.window_handle().unwrap();
        let layer_ptr = match window_handle.as_raw() {
            RawWindowHandle::AppKit(handle) => {
                let ns_view = handle.ns_view.as_ptr();

                unsafe {
                    let layer: id = msg_send![ns_view as id, layer];
                    let is_metal_layer: bool = msg_send![layer, isKindOfClass: class!(CAMetalLayer)];

                    if is_metal_layer {
                        layer as *mut std::ffi::c_void
                    } else {
                        let metal_layer: id = msg_send![class!(CAMetalLayer), layer];
                        let _: () = msg_send![ns_view as id, setLayer: metal_layer];
                        let _: () = msg_send![ns_view as id, setWantsLayer: true];
                        metal_layer as *mut std::ffi::c_void
                    }
                }
            }
            _ => panic!("Unsupported window handle type"),
        };

        let device: *mut std::ffi::c_void = unsafe {
            msg_send![layer_ptr as id, device]
        };

        let device = if device.is_null() {
            let default_device: id = unsafe {
                msg_send![class!(MTLCreateSystemDefaultDevice), alloc]
            };
            unsafe {
                let _: () = msg_send![layer_ptr as id, setDevice: default_device];
            }
            default_device as *mut std::ffi::c_void
        } else {
            device
        };

        let command_queue: *mut std::ffi::c_void = unsafe {
            msg_send![device as id, newCommandQueue]
        };

        if command_queue.is_null() {
            panic!("Failed to create Metal command queue");
        }

        unsafe {
            // 1. 设置 drawable 尺寸 (必须先设置，否则 drawable 池可能已存在)
            let drawable_size = cocoa::foundation::NSSize::new(
                (size.width * scale) as f64,
                (size.height * scale) as f64,
            );
            let _: () = msg_send![layer_ptr as id, setDrawableSize: drawable_size];
            let _: () = msg_send![layer_ptr as id, setContentsScale: scale as f64];

            // 2. 设置像素格式 - 80 = BGRA8Unorm (Skia 需要非 sRGB 格式)
            let pixel_format: u64 = 80;
            let _: () = msg_send![layer_ptr as id, setPixelFormat: pixel_format];

            // 3. 设置 maximumDrawableCount 来重置 drawable 池
            let _: () = msg_send![layer_ptr as id, setMaximumDrawableCount: 2u64];
        }

        let backend = unsafe {
            mtl::BackendContext::new(
                device as mtl::Handle,
                command_queue as mtl::Handle,
            )
        };

        let skia_context = direct_contexts::make_metal(&backend, None)
            .expect("Failed to create Skia DirectContext");

        tracing::info!("Skia Context initialized successfully");

        // ===== Initialize WGPU (for filters/compatibility) =====
        #[cfg(feature = "wgpu-backend")]
        let (wgpu_device, wgpu_queue, wgpu_surface, format, surface_caps, alpha_mode, adapter_info, supports_f16, colorspace, max_texture_dimension_2d) = {
            use futures::executor::block_on;

            // Recreate SugarloafWindow for WGPU (RawWindowHandle is Copy)
            let wgpu_window = crate::SugarloafWindow {
                handle: sugarloaf_window.handle,
                display: sugarloaf_window.display,
                size: sugarloaf_window.size,
                scale: sugarloaf_window.scale,
            };

            let backends = wgpu::Backends::all();
            let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
                backends,
                ..Default::default()
            });

            let wgpu_surface = instance
                .create_surface(wgpu_window)
                .expect("Failed to create WGPU surface");

            let adapter = block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: Some(&wgpu_surface),
            }))
            .expect("Failed to find a WGPU adapter");

            let adapter_info = adapter.get_info();
            tracing::info!("WGPU adapter: {:?}", adapter_info);

            let (wgpu_device, wgpu_queue) = block_on(adapter.request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("sugarloaf-device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::default(),
                    memory_hints: wgpu::MemoryHints::Performance,
                    experimental_features: Default::default(),
                    trace: Default::default(),
                },
            ))
            .expect("Failed to get WGPU device");

            let surface_caps = wgpu_surface.get_capabilities(&adapter);
            let alpha_mode = if surface_caps
                .alpha_modes
                .contains(&wgpu::CompositeAlphaMode::PostMultiplied)
            {
                wgpu::CompositeAlphaMode::PostMultiplied
            } else {
                wgpu::CompositeAlphaMode::Auto
            };

            let format = surface_caps
                .formats
                .iter()
                .find(|f| f.is_srgb())
                .copied()
                .unwrap_or(surface_caps.formats[0]);

            let surface_config = wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format,
                width: (size.width * scale) as u32,
                height: (size.height * scale) as u32,
                present_mode: wgpu::PresentMode::AutoVsync,
                alpha_mode,
                view_formats: vec![],
                desired_maximum_frame_latency: 2,
            };
            wgpu_surface.configure(&wgpu_device, &surface_config);

            let supports_f16 = adapter.features().contains(wgpu::Features::SHADER_F16);
            let colorspace = crate::Colorspace::default();
            let max_texture_dimension_2d = wgpu_device.limits().max_texture_dimension_2d;

            (wgpu_device, wgpu_queue, wgpu_surface, format, surface_caps, alpha_mode, adapter_info, supports_f16, colorspace, max_texture_dimension_2d)
        };

        Context {
            skia_context,
            layer_ptr,
            command_queue_ptr: command_queue,
            size,
            scale,
            #[cfg(feature = "wgpu-backend")]
            device: wgpu_device,
            #[cfg(feature = "wgpu-backend")]
            surface: wgpu_surface,
            #[cfg(feature = "wgpu-backend")]
            queue: wgpu_queue,
            #[cfg(feature = "wgpu-backend")]
            format,
            #[cfg(feature = "wgpu-backend")]
            alpha_mode,
            #[cfg(feature = "wgpu-backend")]
            adapter_info,
            #[cfg(feature = "wgpu-backend")]
            surface_caps,
            #[cfg(feature = "wgpu-backend")]
            supports_f16,
            #[cfg(feature = "wgpu-backend")]
            colorspace,
            #[cfg(feature = "wgpu-backend")]
            max_texture_dimension_2d,
            phantom: std::marker::PhantomData,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        self.size.width = width as f32;
        self.size.height = height as f32;

        unsafe {
            let drawable_size = cocoa::foundation::NSSize::new(
                (width as f32 * self.scale) as f64,
                (height as f32 * self.scale) as f64,
            );
            let _: () = msg_send![self.layer_ptr as id, setDrawableSize: drawable_size];
        }

        #[cfg(feature = "wgpu-backend")]
        {
            let surface_config = wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: self.format,
                width: (width as f32 * self.scale) as u32,
                height: (height as f32 * self.scale) as u32,
                present_mode: wgpu::PresentMode::AutoVsync,
                alpha_mode: self.alpha_mode,
                view_formats: vec![],
                desired_maximum_frame_latency: 2,
            };
            self.surface.configure(&self.device, &surface_config);
        }
    }

    pub fn begin_frame(&mut self) -> Option<(Surface, mtl::Handle)> {
        // 每次渲染前强制确保像素格式正确
        unsafe {
            let current_format: u64 = msg_send![self.layer_ptr as id, pixelFormat];
            if current_format != 80 {
                let _: () = msg_send![self.layer_ptr as id, setPixelFormat: 80u64];
            }
        }

        let drawable: id = unsafe { msg_send![self.layer_ptr as id, nextDrawable] };

        if drawable.is_null() {
            return None;
        }

        let texture: id = unsafe { msg_send![drawable, texture] };
        if texture.is_null() {
            return None;
        }

        let tex_width: u64 = unsafe { msg_send![texture, width] };
        let tex_height: u64 = unsafe { msg_send![texture, height] };
        let tex_pixel_format: u64 = unsafe { msg_send![texture, pixelFormat] };

        // 如果纹理格式不对，跳过此帧
        if tex_pixel_format != 80 {
            return None;
        }

        let texture_info = unsafe {
            mtl::TextureInfo::new(texture as mtl::Handle)
        };

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

    pub fn end_frame(&mut self, drawable: mtl::Handle) {
        self.skia_context.flush_and_submit();

        unsafe {
            let command_buffer: id =
                msg_send![self.command_queue_ptr as id, commandBuffer];

            if !command_buffer.is_null() {
                let _: () = msg_send![command_buffer, presentDrawable: drawable as id];
                let _: () = msg_send![command_buffer, commit];
            } else {
                tracing::error!("Failed to create command buffer for presentation");
            }
        }
    }
}

// WGPU compatibility methods
#[cfg(feature = "wgpu-backend")]
impl Context<'_> {
    pub fn surface_caps(&self) -> &wgpu::SurfaceCapabilities {
        &self.surface_caps
    }

    pub fn supports_f16(&self) -> bool {
        self.supports_f16
    }

    pub fn get_optimal_texture_format(&self, channels: u32) -> wgpu::TextureFormat {
        if self.supports_f16 {
            match channels {
                1 => wgpu::TextureFormat::R16Float,
                2 => wgpu::TextureFormat::Rg16Float,
                4 => wgpu::TextureFormat::Rgba16Float,
                _ => wgpu::TextureFormat::Rgba8Unorm,
            }
        } else {
            wgpu::TextureFormat::Rgba8Unorm
        }
    }

    pub fn max_texture_dimension_2d(&self) -> u32 {
        self.max_texture_dimension_2d
    }

    pub fn get_optimal_texture_sample_type(&self) -> wgpu::TextureSampleType {
        wgpu::TextureSampleType::Float { filterable: true }
    }

    pub fn convert_rgba8_to_optimal_format(&self, rgba8_data: &[u8]) -> Vec<u8> {
        if self.supports_f16 {
            let mut f16_data = Vec::with_capacity(rgba8_data.len() * 2);
            for chunk in rgba8_data.chunks(4) {
                if chunk.len() == 4 {
                    let r = half::f16::from_f32(chunk[0] as f32 / 255.0);
                    let g = half::f16::from_f32(chunk[1] as f32 / 255.0);
                    let b = half::f16::from_f32(chunk[2] as f32 / 255.0);
                    let a = half::f16::from_f32(chunk[3] as f32 / 255.0);

                    f16_data.extend_from_slice(&r.to_le_bytes());
                    f16_data.extend_from_slice(&g.to_le_bytes());
                    f16_data.extend_from_slice(&b.to_le_bytes());
                    f16_data.extend_from_slice(&a.to_le_bytes());
                }
            }
            f16_data
        } else {
            rgba8_data.to_vec()
        }
    }
}

#[cfg(not(target_os = "macos"))]
impl Context<'_> {
    pub fn new<'a>(
        sugarloaf_window: SugarloafWindow,
        _renderer_config: crate::SugarloafRenderer,
    ) -> Context<'a> {
        let size = sugarloaf_window.size;
        let scale = sugarloaf_window.scale;

        // Non-macOS: would need to implement for other platforms
        // For now, panic
        panic!("Skia backend currently only supported on macOS. Size: {:?}, Scale: {}", size, scale);
    }

    pub fn resize(&mut self, _width: u32, _height: u32) {
        panic!("Skia backend currently only supported on macOS");
    }
}
