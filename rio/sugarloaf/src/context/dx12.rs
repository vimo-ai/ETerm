// Copyright (c) 2023-present, Raphael Amorim.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
//! # Dx12Context - Skia Direct3D 12 backend for Windows
//!
//! Mirrors MetalContext's structure but uses DXGI swap chains and D3D12
//! resources instead of CAMetalLayer and Metal drawables.

use super::GpuContext;
use crate::sugarloaf::{SugarloafWindow, SugarloafWindowSize};
use skia_safe::{
    gpu::{
        d3d::{BackendContext, TextureResourceInfo},
        surfaces, BackendRenderTarget, DirectContext, Protected, SurfaceOrigin,
    },
    ColorType, Surface,
};
use windows::{
    core::Interface,
    Win32::{
        Foundation::HWND,
        Graphics::{
            Direct3D::D3D_FEATURE_LEVEL_11_0,
            Direct3D12::{
                D3D12CreateDevice, ID3D12CommandQueue, ID3D12Device,
                D3D12_FENCE_FLAG_NONE, D3D12_RESOURCE_STATE_COMMON,
            },
            Dxgi::{
                Common::{
                    DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC,
                    DXGI_STANDARD_MULTISAMPLE_QUALITY_PATTERN,
                },
                CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory4, IDXGISwapChain3,
                DXGI_ADAPTER_FLAG, DXGI_ADAPTER_FLAG_NONE, DXGI_ADAPTER_FLAG_SOFTWARE,
                DXGI_PRESENT, DXGI_SWAP_CHAIN_DESC1, DXGI_SWAP_CHAIN_FLAG,
                DXGI_SWAP_EFFECT_FLIP_DISCARD, DXGI_USAGE_RENDER_TARGET_OUTPUT,
            },
        },
    },
};

/// Number of back buffers in the swap chain (double buffering).
const BUFFER_COUNT: u32 = 2;

/// Handle identifying the current frame for presentation.
///
/// Contains the swap chain back buffer index so `end_frame` knows
/// which surface to present.
pub struct Dx12FrameHandle {
    buffer_index: u32,
}

/// Windows rendering context backed by Direct3D 12 + Skia.
///
/// Follows the same lifecycle as MetalContext:
/// `new()` -> `begin_frame()` -> draw on Surface -> `end_frame(handle)`.
enum SwapChainMode {
    Hwnd(HWND),
    Composition,
}

pub struct Dx12Context {
    skia_context: DirectContext,
    swap_chain: IDXGISwapChain3,
    factory: IDXGIFactory4,
    device: ID3D12Device,
    queue: ID3D12CommandQueue,
    mode: SwapChainMode,
    /// Pre-created Skia surfaces + their backing render targets, one per back buffer.
    surfaces: Vec<(Surface, BackendRenderTarget)>,
    /// Timestamp of last Skia GPU cache cleanup (throttled)
    last_gpu_cleanup: std::time::Instant,
    size: SugarloafWindowSize,
    scale: f32,
}

impl Dx12Context {
    pub fn new(
        sugarloaf_window: SugarloafWindow,
        _renderer_config: crate::SugarloafRenderer,
    ) -> Self {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};

        let size = sugarloaf_window.size;
        let scale = sugarloaf_window.scale;

        let window_handle = sugarloaf_window.window_handle().unwrap();
        let hwnd = match window_handle.as_raw() {
            RawWindowHandle::Win32(handle) => HWND(handle.hwnd.get() as *mut _),
            _ => panic!("Unsupported window handle type for Dx12Context"),
        };

        let pixel_width = (size.width * scale) as u32;
        let pixel_height = (size.height * scale) as u32;

        // --- Create DXGI factory and find a hardware adapter ---
        // SAFETY: CreateDXGIFactory1 is the standard entry point for DXGI.
        let factory: IDXGIFactory4 =
            unsafe { CreateDXGIFactory1() }.expect("Failed to create DXGI factory");

        let (adapter, device) = find_hardware_adapter(&factory)
            .expect("No suitable D3D12 hardware adapter found");

        // SAFETY: CreateCommandQueue with default descriptor creates a direct queue.
        let queue: ID3D12CommandQueue = unsafe { device.CreateCommandQueue(&Default::default()) }
            .expect("Failed to create D3D12 command queue");

        // --- Initialize Skia D3D12 backend ---
        let backend_context = BackendContext {
            adapter,
            device: device.clone(),
            queue: queue.clone(),
            memory_allocator: None,
            protected_context: Protected::No,
        };

        // SAFETY: backend_context references valid D3D12 objects created above.
        let mut skia_context = unsafe { DirectContext::new_d3d(&backend_context, None) }
            .expect("Failed to create Skia D3D12 DirectContext");

        // --- Create swap chain ---
        let swap_chain_desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: pixel_width,
            Height: pixel_height,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: BUFFER_COUNT,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            ..Default::default()
        };

        // SAFETY: CreateSwapChainForHwnd requires a valid HWND and command queue.
        // Both are guaranteed valid at this point.
        let swap_chain: IDXGISwapChain3 = unsafe {
            factory.CreateSwapChainForHwnd(&queue, hwnd, &swap_chain_desc, None, None)
        }
        .expect("Failed to create DXGI swap chain")
        .cast()
        .expect("Failed to cast to IDXGISwapChain3");

        // --- Wrap each back buffer as a Skia surface ---
        let surfaces = create_surfaces_for_swap_chain(
            &swap_chain,
            &mut skia_context,
            pixel_width,
            pixel_height,
        );

        tracing::info!(
            "Dx12Context initialized: {}x{} @ {:.1}x scale, {} back buffers",
            pixel_width,
            pixel_height,
            scale,
            BUFFER_COUNT
        );

        Dx12Context {
            skia_context,
            swap_chain,
            factory,
            device,
            queue,
            mode: SwapChainMode::Hwnd(hwnd),
            surfaces,
            last_gpu_cleanup: std::time::Instant::now(),
            size,
            scale,
        }
    }

    pub fn new_for_composition(
        width: f32,
        height: f32,
        scale: f32,
    ) -> Self {
        let pixel_width = (width * scale) as u32;
        let pixel_height = (height * scale) as u32;

        let factory: IDXGIFactory4 =
            unsafe { CreateDXGIFactory1() }.expect("Failed to create DXGI factory");

        let (_adapter, device) = find_hardware_adapter(&factory)
            .expect("No suitable D3D12 hardware adapter found");

        let queue: ID3D12CommandQueue = unsafe { device.CreateCommandQueue(&Default::default()) }
            .expect("Failed to create D3D12 command queue");

        let backend_context = BackendContext {
            adapter: _adapter,
            device: device.clone(),
            queue: queue.clone(),
            memory_allocator: None,
            protected_context: Protected::No,
        };

        let mut skia_context = unsafe { DirectContext::new_d3d(&backend_context, None) }
            .expect("Failed to create Skia D3D12 DirectContext");

        let swap_chain_desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: pixel_width,
            Height: pixel_height,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: BUFFER_COUNT,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            ..Default::default()
        };

        let swap_chain: IDXGISwapChain3 = unsafe {
            factory.CreateSwapChainForComposition(&queue, &swap_chain_desc, None)
        }
        .expect("Failed to create DXGI composition swap chain")
        .cast()
        .expect("Failed to cast to IDXGISwapChain3");

        let surfaces = create_surfaces_for_swap_chain(
            &swap_chain,
            &mut skia_context,
            pixel_width,
            pixel_height,
        );

        Dx12Context {
            skia_context,
            swap_chain,
            factory,
            device,
            queue,
            mode: SwapChainMode::Composition,
            surfaces,
            last_gpu_cleanup: std::time::Instant::now(),
            size: SugarloafWindowSize { width, height },
            scale,
        }
    }

    pub fn swap_chain_ptr(&self) -> *mut std::ffi::c_void {
        use windows::core::Interface;
        self.swap_chain.as_raw()
    }
}

impl GpuContext for Dx12Context {
    type FrameHandle = Dx12FrameHandle;

    fn resize(&mut self, width: u32, height: u32) {
        self.size.width = width as f32;
        self.size.height = height as f32;

        let pixel_width = (width as f32 * self.scale) as u32;
        let pixel_height = (height as f32 * self.scale) as u32;

        if pixel_width == 0 || pixel_height == 0 {
            return;
        }

        self.surfaces.clear();
        self.skia_context.flush_and_submit();
        self.skia_context.free_gpu_resources();

        unsafe {
            if let Ok(fence) = self.device.CreateFence::<windows::Win32::Graphics::Direct3D12::ID3D12Fence>(0, D3D12_FENCE_FLAG_NONE) {
                let _ = self.queue.Signal(&fence, 1);
                while fence.GetCompletedValue() < 1 {
                    std::hint::spin_loop();
                }
            }
        }

        let swap_chain_desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: pixel_width,
            Height: pixel_height,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: BUFFER_COUNT,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            ..Default::default()
        };

        let new_swap_chain: Option<IDXGISwapChain3> = match &self.mode {
            SwapChainMode::Composition => {
                unsafe {
                    self.factory
                        .CreateSwapChainForComposition(&self.queue, &swap_chain_desc, None)
                }
                .ok()
                .and_then(|sc| sc.cast().ok())
            }
            SwapChainMode::Hwnd(hwnd) => {
                unsafe {
                    self.factory
                        .CreateSwapChainForHwnd(&self.queue, *hwnd, &swap_chain_desc, None, None)
                }
                .ok()
                .and_then(|sc| sc.cast().ok())
            }
        };

        if let Some(sc) = new_swap_chain {
            self.swap_chain = sc;
        }

        self.surfaces = create_surfaces_for_swap_chain(
            &self.swap_chain,
            &mut self.skia_context,
            pixel_width,
            pixel_height,
        );
    }

    fn begin_frame(&mut self) -> Option<(Surface, Dx12FrameHandle)> {
        // SAFETY: GetCurrentBackBufferIndex is always safe to call on a valid swap chain.
        let buffer_index = unsafe { self.swap_chain.GetCurrentBackBufferIndex() };

        if let Some((surface, _)) = self.surfaces.get(buffer_index as usize) {
            // Clone the surface so the caller can draw on it while we retain ownership
            // of the backing render target for presentation.
            Some((surface.clone(), Dx12FrameHandle { buffer_index }))
        } else {
            tracing::error!(
                "Back buffer index {} out of range (have {} surfaces)",
                buffer_index,
                self.surfaces.len()
            );
            None
        }
    }

    fn end_frame(&mut self, handle: Dx12FrameHandle) {
        // Flush Skia drawing commands for the current back buffer
        if let Some((surface, _)) = self.surfaces.get_mut(handle.buffer_index as usize) {
            self.skia_context
                .flush_and_submit_surface(surface, None);
        }

        // Present the swap chain (1 = sync to VSync)
        // SAFETY: Present is safe to call after flushing all GPU work.
        unsafe {
            self.swap_chain
                .Present(1, DXGI_PRESENT::default())
                .ok()
                .expect("Swap chain Present failed");
        }

        // Throttled cleanup: every 120s, purge GPU resources unused for 5 minutes.
        if self.last_gpu_cleanup.elapsed() >= std::time::Duration::from_secs(120) {
            self.skia_context
                .perform_deferred_cleanup(std::time::Duration::from_secs(300), None);
            self.last_gpu_cleanup = std::time::Instant::now();
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

    fn swap_chain_ptr(&self) -> *mut std::ffi::c_void {
        self.swap_chain_ptr()
    }
}

/// Create Skia surfaces wrapping each swap chain back buffer.
fn create_surfaces_for_swap_chain(
    swap_chain: &IDXGISwapChain3,
    skia_context: &mut DirectContext,
    width: u32,
    height: u32,
) -> Vec<(Surface, BackendRenderTarget)> {
    (0..BUFFER_COUNT)
        .map(|i| {
            // SAFETY: GetBuffer returns the ID3D12Resource for the i-th back buffer.
            let resource = unsafe { swap_chain.GetBuffer(i) }
                .unwrap_or_else(|e| panic!("Failed to get swap chain buffer {}: {}", i, e));

            let texture_info = TextureResourceInfo {
                resource,
                alloc: None,
                resource_state: D3D12_RESOURCE_STATE_COMMON,
                format: DXGI_FORMAT_R8G8B8A8_UNORM,
                sample_count: 1,
                level_count: 0,
                sample_quality_pattern: DXGI_STANDARD_MULTISAMPLE_QUALITY_PATTERN,
                protected: Protected::No,
            };

            let backend_rt =
                BackendRenderTarget::new_d3d((width as i32, height as i32), &texture_info);

            let surface = surfaces::wrap_backend_render_target(
                skia_context,
                &backend_rt,
                SurfaceOrigin::TopLeft,
                ColorType::RGBA8888,
                None,
                None,
            )
            .unwrap_or_else(|| {
                panic!("Failed to create Skia surface for back buffer {}", i)
            });

            (surface, backend_rt)
        })
        .collect()
}

/// Enumerate DXGI adapters and find a hardware adapter that supports D3D12.
fn find_hardware_adapter(
    factory: &IDXGIFactory4,
) -> windows::core::Result<(IDXGIAdapter1, ID3D12Device)> {
    for i in 0.. {
        let adapter = match unsafe { factory.EnumAdapters1(i) } {
            Ok(adapter) => adapter,
            Err(_) => break, // No more adapters
        };

        // SAFETY: GetDesc1 retrieves adapter metadata.
        let desc = unsafe { adapter.GetDesc1() }?;

        // Skip software rasterizer
        if (DXGI_ADAPTER_FLAG(desc.Flags as _) & DXGI_ADAPTER_FLAG_SOFTWARE)
            != DXGI_ADAPTER_FLAG_NONE
        {
            continue;
        }

        // Try to create a D3D12 device with feature level 11.0
        let mut device: Option<ID3D12Device> = None;
        // SAFETY: D3D12CreateDevice probes whether the adapter supports
        // the requested feature level. If it fails, we try the next adapter.
        if unsafe { D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_11_0, &mut device) }.is_ok()
        {
            tracing::info!(
                "D3D12 adapter: {:?}",
                String::from_utf16_lossy(&desc.Description)
                    .trim_end_matches('\0')
            );
            return Ok((adapter, device.unwrap()));
        }
    }

    Err(windows::core::Error::new(
        windows::core::HRESULT(-1),
        "No suitable D3D12 hardware adapter found",
    ))
}
