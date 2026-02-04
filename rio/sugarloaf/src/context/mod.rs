// Copyright (c) 2023-present, Raphael Amorim.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
//! # Context - Skia 渲染上下文 (macOS only)
//!
//! 历史: 原为 Skia + WGPU 混合架构，WGPU 部分已于 2025-12 清理
//!
//! 当前状态: 仅保留 Skia 相关字段和方法
//!
//! 注释的 WGPU 代码将在长期稳定后删除

use crate::sugarloaf::{SugarloafWindow, SugarloafWindowSize};

#[cfg(target_os = "macos")]
use objc2::runtime::{AnyObject, AnyClass};
#[cfg(target_os = "macos")]
use objc2::msg_send;
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

    /// 上次 Skia GPU 缓存清理的时间（用于节流，避免每帧都调用）
    #[cfg(target_os = "macos")]
    last_gpu_cleanup: std::time::Instant,

    /// 上次 Skia CPU 缓存清理的时间（清理 SkMallocPixelRef 等 CPU 侧缓存）
    #[cfg(target_os = "macos")]
    last_cpu_cleanup: std::time::Instant,

    pub size: SugarloafWindowSize,
    pub scale: f32,

    // ===== WGPU fields (kept for filters/rio-backend compatibility) =====
    // #[cfg(feature = "wgpu-backend")]
    // pub device: wgpu::Device,
    // #[cfg(feature = "wgpu-backend")]
    // pub surface: wgpu::Surface<'a>,
    // #[cfg(feature = "wgpu-backend")]
    // pub queue: wgpu::Queue,
    // #[cfg(feature = "wgpu-backend")]
    // pub format: wgpu::TextureFormat,
    // #[cfg(feature = "wgpu-backend")]
    // alpha_mode: wgpu::CompositeAlphaMode,
    // #[cfg(feature = "wgpu-backend")]
    // pub adapter_info: wgpu::AdapterInfo,
    // #[cfg(feature = "wgpu-backend")]
    // surface_caps: wgpu::SurfaceCapabilities,
    // #[cfg(feature = "wgpu-backend")]
    // pub supports_f16: bool,
    // #[cfg(feature = "wgpu-backend")]
    // pub colorspace: crate::Colorspace,
    // #[cfg(feature = "wgpu-backend")]
    // pub max_texture_dimension_2d: u32,

    #[allow(dead_code)]
    phantom: std::marker::PhantomData<&'a ()>,
}

#[cfg(target_os = "macos")]
impl Context<'_> {
    pub fn new<'a>(
        sugarloaf_window: SugarloafWindow,
        _renderer_config: crate::SugarloafRenderer,
    ) -> Context<'a> {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};

        let size = sugarloaf_window.size;
        let scale = sugarloaf_window.scale;

        // ===== Initialize Skia =====
        let window_handle = sugarloaf_window.window_handle().unwrap();
        let layer_ptr = match window_handle.as_raw() {
            RawWindowHandle::AppKit(handle) => {
                let ns_view = handle.ns_view.as_ptr() as *mut AnyObject;

                unsafe {
                    let layer: *mut AnyObject = msg_send![ns_view, layer];

                    // Get CAMetalLayer class
                    let metal_layer_class = AnyClass::get("CAMetalLayer")
                        .expect("CAMetalLayer class not found");
                    let is_metal_layer: bool = msg_send![layer, isKindOfClass: metal_layer_class];

                    if is_metal_layer {
                        layer as *mut std::ffi::c_void
                    } else {
                        // Create a new CAMetalLayer
                        let metal_layer: *mut AnyObject = msg_send![metal_layer_class, layer];
                        let _: () = msg_send![ns_view, setLayer: metal_layer];
                        let _: () = msg_send![ns_view, setWantsLayer: true];
                        metal_layer as *mut std::ffi::c_void
                    }
                }
            }
            _ => panic!("Unsupported window handle type"),
        };

        let device: *mut std::ffi::c_void = unsafe {
            msg_send![layer_ptr as *mut AnyObject, device]
        };

        let device = if device.is_null() {
            // Use C function to create system default Metal device
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

        let command_queue: *mut std::ffi::c_void = unsafe {
            msg_send![device as *mut AnyObject, newCommandQueue]
        };

        if command_queue.is_null() {
            panic!("Failed to create Metal command queue");
        }

        unsafe {
            // 1. 设置 drawable 尺寸 (必须先设置，否则 drawable 池可能已存在)
            use objc2_foundation::CGSize;
            let drawable_size = CGSize::new(
                (size.width * scale) as f64,
                (size.height * scale) as f64,
            );
            let _: () = msg_send![layer_ptr as *mut AnyObject, setDrawableSize: drawable_size];
            let _: () = msg_send![layer_ptr as *mut AnyObject, setContentsScale: scale as f64];

            // 2. 设置像素格式 - 80 = BGRA8Unorm (Skia 需要非 sRGB 格式)
            let pixel_format: u64 = 80;
            let _: () = msg_send![layer_ptr as *mut AnyObject, setPixelFormat: pixel_format];

            // 3. 设置 maximumDrawableCount 来重置 drawable 池
            // 使用 3 个 drawable：1 显示中 + 1 等待显示 + 1 空闲可用
            let _: () = msg_send![layer_ptr as *mut AnyObject, setMaximumDrawableCount: 3u64];

            // 4. 禁用 displaySync，避免 nextDrawable 等待 VSync
            let _: () = msg_send![layer_ptr as *mut AnyObject, setDisplaySyncEnabled: false];
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
        // #[cfg(feature = "wgpu-backend")]
        // let (wgpu_device, wgpu_queue, wgpu_surface, format, surface_caps, alpha_mode, adapter_info, supports_f16, colorspace, max_texture_dimension_2d) = {
        //     use futures::executor::block_on;
        //
        //     // Recreate SugarloafWindow for WGPU (RawWindowHandle is Copy)
        //     let wgpu_window = crate::SugarloafWindow {
        //         handle: sugarloaf_window.handle,
        //         display: sugarloaf_window.display,
        //         size: sugarloaf_window.size,
        //         scale: sugarloaf_window.scale,
        //     };
        //
        //     let backends = wgpu::Backends::all();
        //     let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
        //         backends,
        //         ..Default::default()
        //     });
        //
        //     let wgpu_surface = instance
        //         .create_surface(wgpu_window)
        //         .expect("Failed to create WGPU surface");
        //
        //     let adapter = block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        //         power_preference: wgpu::PowerPreference::HighPerformance,
        //         force_fallback_adapter: false,
        //         compatible_surface: Some(&wgpu_surface),
        //     }))
        //     .expect("Failed to find a WGPU adapter");
        //
        //     let adapter_info = adapter.get_info();
        //     tracing::info!("WGPU adapter: {:?}", adapter_info);
        //
        //     let (wgpu_device, wgpu_queue) = block_on(adapter.request_device(
        //         &wgpu::DeviceDescriptor {
        //             label: Some("sugarloaf-device"),
        //             required_features: wgpu::Features::empty(),
        //             required_limits: wgpu::Limits::default(),
        //             memory_hints: wgpu::MemoryHints::Performance,
        //             experimental_features: Default::default(),
        //             trace: Default::default(),
        //         },
        //     ))
        //     .expect("Failed to get WGPU device");
        //
        //     let surface_caps = wgpu_surface.get_capabilities(&adapter);
        //     let alpha_mode = if surface_caps
        //         .alpha_modes
        //         .contains(&wgpu::CompositeAlphaMode::PostMultiplied)
        //     {
        //         wgpu::CompositeAlphaMode::PostMultiplied
        //     } else {
        //         wgpu::CompositeAlphaMode::Auto
        //     };
        //
        //     let format = surface_caps
        //         .formats
        //         .iter()
        //         .find(|f| f.is_srgb())
        //         .copied()
        //         .unwrap_or(surface_caps.formats[0]);
        //
        //     let surface_config = wgpu::SurfaceConfiguration {
        //         usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        //         format,
        //         width: (size.width * scale) as u32,
        //         height: (size.height * scale) as u32,
        //         present_mode: wgpu::PresentMode::AutoVsync,
        //         alpha_mode,
        //         view_formats: vec![],
        //         desired_maximum_frame_latency: 2,
        //     };
        //     wgpu_surface.configure(&wgpu_device, &surface_config);
        //
        //     let supports_f16 = adapter.features().contains(wgpu::Features::SHADER_F16);
        //     let colorspace = crate::Colorspace::default();
        //     let max_texture_dimension_2d = wgpu_device.limits().max_texture_dimension_2d;
        //
        //     (wgpu_device, wgpu_queue, wgpu_surface, format, surface_caps, alpha_mode, adapter_info, supports_f16, colorspace, max_texture_dimension_2d)
        // };

        Context {
            skia_context,
            layer_ptr,
            command_queue_ptr: command_queue,
            last_gpu_cleanup: std::time::Instant::now(),
            last_cpu_cleanup: std::time::Instant::now(),
            size,
            scale,
            // #[cfg(feature = "wgpu-backend")]
            // device: wgpu_device,
            // #[cfg(feature = "wgpu-backend")]
            // surface: wgpu_surface,
            // #[cfg(feature = "wgpu-backend")]
            // queue: wgpu_queue,
            // #[cfg(feature = "wgpu-backend")]
            // format,
            // #[cfg(feature = "wgpu-backend")]
            // alpha_mode,
            // #[cfg(feature = "wgpu-backend")]
            // adapter_info,
            // #[cfg(feature = "wgpu-backend")]
            // surface_caps,
            // #[cfg(feature = "wgpu-backend")]
            // supports_f16,
            // #[cfg(feature = "wgpu-backend")]
            // colorspace,
            // #[cfg(feature = "wgpu-backend")]
            // max_texture_dimension_2d,
            phantom: std::marker::PhantomData,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        self.size.width = width as f32;
        self.size.height = height as f32;

        unsafe {
            use objc2_foundation::CGSize;
            let drawable_size = CGSize::new(
                (width as f32 * self.scale) as f64,
                (height as f32 * self.scale) as f64,
            );
            let _: () = msg_send![self.layer_ptr as *mut AnyObject, setDrawableSize: drawable_size];
        }

        // #[cfg(feature = "wgpu-backend")]
        // {
        //     let surface_config = wgpu::SurfaceConfiguration {
        //         usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        //         format: self.format,
        //         width: (width as f32 * self.scale) as u32,
        //         height: (height as f32 * self.scale) as u32,
        //         present_mode: wgpu::PresentMode::AutoVsync,
        //         alpha_mode: self.alpha_mode,
        //         view_formats: vec![],
        //         desired_maximum_frame_latency: 2,
        //     };
        //     self.surface.configure(&self.device, &surface_config);
        // }
    }

    pub fn begin_frame(&mut self) -> Option<(Surface, mtl::Handle)> {
        // 每次渲染前强制确保像素格式正确
        unsafe {
            let current_format: u64 = msg_send![self.layer_ptr as *mut AnyObject, pixelFormat];
            if current_format != 80 {
                let _: () = msg_send![self.layer_ptr as *mut AnyObject, setPixelFormat: 80u64];
            }
        }

        let drawable: *mut AnyObject = unsafe { msg_send![self.layer_ptr as *mut AnyObject, nextDrawable] };

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

        // 节流：每 2 秒执行一次 Skia GPU 资源清理
        // 避免每帧都调用导致频繁的缓存检查（60fps = 每秒 60 次）
        // 清理超过 30 秒未使用的资源，平衡性能和内存
        if self.last_gpu_cleanup.elapsed() >= std::time::Duration::from_secs(2) {
            self.skia_context
                .perform_deferred_cleanup(std::time::Duration::from_secs(30), None);
            self.last_gpu_cleanup = std::time::Instant::now();
        }

        // 节流：每 60 秒执行一次 Skia CPU 资源清理
        // 清理 SkMallocPixelRef 等 CPU 侧像素缓存（Malloc 80KB 块）
        // 间隔较长是因为 CPU 缓存重建成本较高
        if self.last_cpu_cleanup.elapsed() >= std::time::Duration::from_secs(60) {
            skia_safe::graphics::purge_resource_cache();
            self.last_cpu_cleanup = std::time::Instant::now();
        }

        unsafe {
            let command_buffer: *mut AnyObject =
                msg_send![self.command_queue_ptr as *mut AnyObject, commandBuffer];

            if !command_buffer.is_null() {
                let _: () = msg_send![command_buffer, presentDrawable: drawable as *mut AnyObject];
                let _: () = msg_send![command_buffer, commit];
                // 背压：等待 GPU 调度完成，防止 command buffer 队列无限积压
                // 这比 waitUntilCompleted 轻量，不会阻塞到 GPU 执行完毕
                let _: () = msg_send![command_buffer, waitUntilScheduled];
            } else {
                tracing::error!("Failed to create command buffer for presentation");
            }
        }
    }
}

// WGPU compatibility methods
// #[cfg(feature = "wgpu-backend")]
// impl Context<'_> {
//     pub fn surface_caps(&self) -> &wgpu::SurfaceCapabilities {
//         &self.surface_caps
//     }
//
//     pub fn supports_f16(&self) -> bool {
//         self.supports_f16
//     }
//
//     pub fn get_optimal_texture_format(&self, channels: u32) -> wgpu::TextureFormat {
//         if self.supports_f16 {
//             match channels {
//                 1 => wgpu::TextureFormat::R16Float,
//                 2 => wgpu::TextureFormat::Rg16Float,
//                 4 => wgpu::TextureFormat::Rgba16Float,
//                 _ => wgpu::TextureFormat::Rgba8Unorm,
//             }
//         } else {
//             wgpu::TextureFormat::Rgba8Unorm
//         }
//     }
//
//     pub fn max_texture_dimension_2d(&self) -> u32 {
//         self.max_texture_dimension_2d
//     }
//
//     pub fn get_optimal_texture_sample_type(&self) -> wgpu::TextureSampleType {
//         wgpu::TextureSampleType::Float { filterable: true }
//     }
//
//     pub fn convert_rgba8_to_optimal_format(&self, rgba8_data: &[u8]) -> Vec<u8> {
//         if self.supports_f16 {
//             let mut f16_data = Vec::with_capacity(rgba8_data.len() * 2);
//             for chunk in rgba8_data.chunks(4) {
//                 if chunk.len() == 4 {
//                     let r = half::f16::from_f32(chunk[0] as f32 / 255.0);
//                     let g = half::f16::from_f32(chunk[1] as f32 / 255.0);
//                     let b = half::f16::from_f32(chunk[2] as f32 / 255.0);
//                     let a = half::f16::from_f32(chunk[3] as f32 / 255.0);
//
//                     f16_data.extend_from_slice(&r.to_le_bytes());
//                     f16_data.extend_from_slice(&g.to_le_bytes());
//                     f16_data.extend_from_slice(&b.to_le_bytes());
//                     f16_data.extend_from_slice(&a.to_le_bytes());
//                 }
//             }
//             f16_data
//         } else {
//             rgba8_data.to_vec()
//         }
//     }
// }

// #[cfg(not(target_os = "macos"))]
// impl Context<'_> {
//     pub fn new<'a>(
//         sugarloaf_window: SugarloafWindow,
//         _renderer_config: crate::SugarloafRenderer,
//     ) -> Context<'a> {
//         let size = sugarloaf_window.size;
//         let scale = sugarloaf_window.scale;
//
//         // Non-macOS: would need to implement for other platforms
//         // For now, panic
//         panic!("Skia backend currently only supported on macOS. Size: {:?}, Scale: {}", size, scale);
//     }
//
//     pub fn resize(&mut self, _width: u32, _height: u32) {
//         panic!("Skia backend currently only supported on macOS");
//     }
// }
