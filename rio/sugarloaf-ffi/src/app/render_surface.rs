//! RenderSurface - 渲染表面（纯渲染，无状态管理）
//!
//! 职责：
//! - 持有 Sugarloaf（Metal context）
//! - 管理渲染布局
//! - 从 TerminalStore 读取状态进行渲染
//! - 每个窗口/渲染区域一个 RenderSurface

use crate::render::{Renderer, RenderConfig};
use crate::render::font::FontContext;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use sugarloaf::font::FontLibrary;
use sugarloaf::{Sugarloaf, SugarloafWindow, SugarloafWindowSize, SugarloafRenderer, Object, ImageObject, layout::RootStyle};

use super::terminal_store::TerminalStore;
use super::ffi::AppConfig;

/// 单个终端的渲染缓存
struct TerminalRenderCache {
    /// 缓存的渲染结果
    cached_image: skia_safe::Image,
    /// 缓存对应的尺寸（物理像素）
    width: u32,
    height: u32,
}

/// 渲染表面
///
/// 每个 Metal 渲染区域（窗口）一个实例
pub struct RenderSurface {
    /// Sugarloaf 渲染引擎
    sugarloaf: Mutex<Sugarloaf<'static>>,

    /// 渲染器
    renderer: Mutex<Renderer>,

    /// 字体上下文
    font_context: Arc<FontContext>,

    /// 终端存储引用
    store: Arc<TerminalStore>,

    /// 渲染缓存（每个终端一个）
    render_caches: Mutex<HashMap<usize, TerminalRenderCache>>,

    /// 待渲染的 objects（每帧累积）
    pending_objects: Mutex<Vec<Object>>,

    /// 是否需要渲染（与 TerminalStore 共享）
    needs_render: Arc<AtomicBool>,

    /// 渲染布局
    /// Vec<(terminal_id, x, y, width, height)>
    render_layout: Mutex<Vec<(usize, f32, f32, f32, f32)>>,

    /// 容器高度（用于坐标转换）
    container_height: Mutex<f32>,

    /// 配置
    config: AppConfig,
}

// Safety: Sugarloaf 内部管理线程安全
unsafe impl Send for RenderSurface {}
unsafe impl Sync for RenderSurface {}

impl RenderSurface {
    /// 创建渲染表面
    pub fn new(config: AppConfig, store: Arc<TerminalStore>) -> Result<Self, super::ffi::ErrorCode> {
        // 验证配置
        if config.window_handle.is_null() {
            return Err(super::ffi::ErrorCode::InvalidConfig);
        }

        // 获取全局共享的 FontLibrary
        let font_library = crate::get_shared_font_library(config.font_size);

        // 创建字体上下文
        let font_context = Arc::new(FontContext::new(font_library.clone()));

        // 创建渲染配置
        use crate::domain::primitives::LogicalPixels;
        use rio_backend::config::colors::Colors;
        let colors = Arc::new(Colors::default());
        let render_config = RenderConfig::new(
            LogicalPixels::new(config.font_size),
            config.line_height,
            config.scale,
            colors,
        );

        // 创建渲染器
        let renderer = Renderer::new(font_context.clone(), render_config.clone());

        // 创建 Sugarloaf
        let sugarloaf = Self::create_sugarloaf(&config, &font_library, &render_config)?;

        // 共享 TerminalStore 的 needs_render 标记
        let needs_render = store.needs_render_flag();

        Ok(Self {
            sugarloaf: Mutex::new(sugarloaf),
            renderer: Mutex::new(renderer),
            font_context,
            store,
            render_caches: Mutex::new(HashMap::new()),
            pending_objects: Mutex::new(Vec::new()),
            needs_render,
            render_layout: Mutex::new(Vec::new()),
            container_height: Mutex::new(0.0),
            config,
        })
    }

    /// 创建 Sugarloaf 实例
    fn create_sugarloaf(
        config: &AppConfig,
        font_library: &FontLibrary,
        render_config: &RenderConfig,
    ) -> Result<Sugarloaf<'static>, super::ffi::ErrorCode> {
        #[cfg(target_os = "macos")]
        let raw_window_handle = {
            use raw_window_handle::{AppKitWindowHandle, RawWindowHandle};
            match std::ptr::NonNull::new(config.window_handle) {
                Some(nn_ptr) => {
                    let handle = AppKitWindowHandle::new(nn_ptr);
                    RawWindowHandle::AppKit(handle)
                }
                None => return Err(super::ffi::ErrorCode::InvalidConfig),
            }
        };

        #[cfg(target_os = "macos")]
        let raw_display_handle = {
            use raw_window_handle::{AppKitDisplayHandle, RawDisplayHandle};
            RawDisplayHandle::AppKit(AppKitDisplayHandle::new())
        };

        let window = SugarloafWindow {
            handle: raw_window_handle,
            display: raw_display_handle,
            size: SugarloafWindowSize {
                width: config.window_width,
                height: config.window_height,
            },
            scale: config.scale,
        };

        let renderer = SugarloafRenderer::default();
        let layout = RootStyle {
            font_size: config.font_size,
            line_height: config.line_height,
            scale_factor: config.scale,
        };

        let mut sugarloaf = match Sugarloaf::new(window, renderer, font_library, layout) {
            Ok(instance) => instance,
            Err(with_errors) => with_errors.instance,
        };

        sugarloaf.set_background_color(Some(render_config.background_color));

        Ok(sugarloaf)
    }

    /// 创建临时 Surface 用于渲染
    fn create_temp_surface(&self, width: u32, height: u32) -> Option<skia_safe::Surface> {
        if width == 0 || height == 0 {
            return None;
        }

        let sugarloaf = self.sugarloaf.lock();
        let context = sugarloaf.get_context();

        #[cfg(target_os = "macos")]
        {
            use skia_safe::{
                gpu::{SurfaceOrigin, surfaces, Budgeted},
                ColorType, ImageInfo, AlphaType, ColorSpace,
            };

            let image_info = ImageInfo::new(
                (width as i32, height as i32),
                ColorType::RGBA8888,
                AlphaType::Premul,
                ColorSpace::new_srgb(),
            );

            let mut skia_context = context.skia_context.clone();
            let surface = surfaces::render_target(
                &mut skia_context,
                Budgeted::Yes,
                &image_info,
                None,
                SurfaceOrigin::TopLeft,
                None,
                false,
                false,
            )?;

            Some(surface)
        }

        #[cfg(not(target_os = "macos"))]
        {
            None
        }
    }

    // MARK: - 渲染

    /// 设置渲染布局
    pub fn set_render_layout(&self, layout: Vec<(usize, f32, f32, f32, f32)>, container_height: f32) {
        *self.render_layout.lock() = layout;
        *self.container_height.lock() = container_height;
    }

    /// 获取渲染布局引用
    pub fn render_layout_ref(&self) -> Vec<(usize, f32, f32, f32, f32)> {
        self.render_layout.lock().clone()
    }

    /// 开始新的一帧
    pub fn begin_frame(&self) {
        self.pending_objects.lock().clear();
    }

    /// 渲染单个终端
    pub fn render_terminal(&self, id: usize, _x: f32, _y: f32, width: f32, height: f32) -> bool {
        // 获取字体度量
        let font_metrics = {
            let renderer = self.renderer.lock();
            crate::render::config::FontMetrics::compute(
                renderer.config(),
                &self.font_context,
            )
        };

        let scale = self.config.scale;

        // 如果提供了 width/height，自动计算 cols/rows 并 resize
        if width > 0.0 && height > 0.0 {
            use crate::domain::primitives::PhysicalPixels;

            let physical_width = PhysicalPixels::new(width * scale);
            let physical_height = PhysicalPixels::new(height * scale);
            let physical_line_height = font_metrics.cell_height.value * self.config.line_height;

            let new_cols = (physical_width.value / font_metrics.cell_width.value).floor() as u16;
            let new_rows = (physical_height.value / physical_line_height).floor() as u16;

            if new_cols > 0 && new_rows > 0 {
                if let Some((cols, rows)) = self.store.get_terminal_size(id) {
                    if cols != new_cols || rows != new_rows {
                        self.store.resize_terminal(id, new_cols, new_rows, width, height);
                    }
                }
            }
        }

        // 计算所需尺寸（物理像素）
        use crate::domain::primitives::PhysicalPixels;
        let physical_width = PhysicalPixels::new(width * scale);
        let physical_height = PhysicalPixels::new(height * scale);
        let cache_width = physical_width.value as u32;
        let cache_height = physical_height.value as u32;

        // 检查缓存是否有效
        let cache_valid = {
            let caches = self.render_caches.lock();
            match caches.get(&id) {
                Some(cache) => cache.width == cache_width && cache.height == cache_height,
                None => false,
            }
        };

        // 检查是否有 damage
        let is_damaged = self.store.with_terminal(id, |t| t.is_damaged()).unwrap_or(false);

        // 如果缓存有效且没有 damage，跳过渲染
        if cache_valid && !is_damaged {
            return true;
        }

        // 获取终端状态进行渲染
        let (state, rows) = match self.store.with_terminal(id, |t| (t.state(), t.rows())) {
            Some(v) => v,
            None => return false,
        };

        // 创建临时 Surface
        let mut temp_surface = match self.create_temp_surface(cache_width, cache_height) {
            Some(s) => s,
            None => {
                eprintln!("❌ [RenderSurface] Failed to create temp surface for terminal {}", id);
                return false;
            }
        };

        // 渲染所有行
        {
            let canvas = temp_surface.canvas();
            canvas.clear(skia_safe::Color::TRANSPARENT);

            let mut renderer = self.renderer.lock();
            let logical_cell_size = font_metrics.to_logical_size(scale);
            let logical_line_height = logical_cell_size.height * self.config.line_height;

            for line in 0..rows {
                let image = renderer.render_line(line, &state);
                let y_offset_pixels = (logical_line_height * (line as f32)) * scale;
                let y_offset = y_offset_pixels.value;
                canvas.draw_image(&image, (0.0f32, y_offset), None);
            }
        }

        // 缓存渲染结果
        let cached_image = temp_surface.image_snapshot();
        {
            let mut caches = self.render_caches.lock();
            caches.insert(id, TerminalRenderCache {
                cached_image,
                width: cache_width,
                height: cache_height,
            });
        }

        // 重置 damage 状态
        self.store.with_terminal_mut(id, |t| t.reset_damage());

        true
    }

    /// 结束帧（合成渲染）
    pub fn end_frame(&self) {
        let layout = self.render_layout.lock().clone();
        if layout.is_empty() {
            return;
        }

        let mut sugarloaf = self.sugarloaf.lock();

        // 从缓存获取 Image 构建 objects
        let mut objects = Vec::new();
        {
            let caches = self.render_caches.lock();
            for (terminal_id, x, y, _width, _height) in &layout {
                if let Some(cache) = caches.get(terminal_id) {
                    let image_obj = ImageObject {
                        position: [*x, *y],
                        image: cache.cached_image.clone(),
                    };
                    objects.push(Object::Image(image_obj));
                }
            }
        }

        sugarloaf.set_objects(objects);
        sugarloaf.render();
    }

    /// 渲染所有终端（根据布局）
    pub fn render_all(&self) {
        let frame_start = std::time::Instant::now();

        let layout = self.render_layout.lock().clone();
        if layout.is_empty() {
            return;
        }

        self.begin_frame();

        for (terminal_id, x, y, width, height) in &layout {
            self.render_terminal(*terminal_id, *x, *y, *width, *height);
        }

        self.end_frame();

        // 🔧 PERF DEBUG: 打印帧级缓存统计
        {
            let mut renderer = self.renderer.lock();
            renderer.print_frame_stats("render_all");
        }

        let frame_time = frame_start.elapsed().as_micros();
        eprintln!("⚡️ FRAME_PERF render_all() took {}μs ({:.2}ms)",
                  frame_time, frame_time as f32 / 1000.0);
    }

    // MARK: - Sugarloaf 管理

    /// 调整 Sugarloaf 尺寸
    pub fn resize_sugarloaf(&self, width: f32, height: f32) {
        let mut sugarloaf = self.sugarloaf.lock();
        sugarloaf.resize(width as u32, height as u32);
    }

    /// 设置 DPI 缩放
    pub fn set_scale(&self, scale: f32) {
        // 更新渲染器
        let mut renderer = self.renderer.lock();
        renderer.set_scale(scale);
        drop(renderer);

        // 更新 Sugarloaf
        let mut sugarloaf = self.sugarloaf.lock();
        sugarloaf.rescale(scale);
        drop(sugarloaf);

        // 清除缓存（scale 变化需要重新渲染）
        self.render_caches.lock().clear();

        self.needs_render.store(true, Ordering::Release);
    }

    // MARK: - 字体

    /// 获取字体度量
    pub fn get_font_metrics(&self) -> (f32, f32, f32) {
        let renderer = self.renderer.lock();
        let metrics = crate::render::config::FontMetrics::compute(
            renderer.config(),
            &self.font_context,
        );

        (
            metrics.cell_width.value,
            metrics.cell_height.value,
            metrics.cell_height.value * self.config.line_height,
        )
    }

    /// 调整字体大小
    pub fn change_font_size(&self, operation: u8) {
        use crate::domain::primitives::LogicalPixels;

        let mut renderer = self.renderer.lock();
        let current_size = renderer.config().font_size;

        let new_size = match operation {
            0 => current_size.value + 1.0, // Increase
            1 => (current_size.value - 1.0).max(6.0), // Decrease
            2 => 14.0, // Reset
            _ => return,
        };

        renderer.set_font_size(LogicalPixels::new(new_size));
        drop(renderer);

        // 注：Sugarloaf 不直接处理字体大小
        // 我们的 Renderer 独立管理字体渲染

        // 清除缓存
        self.render_caches.lock().clear();

        self.needs_render.store(true, Ordering::Release);
    }

    /// 获取当前字体大小
    pub fn get_font_size(&self) -> f32 {
        let renderer = self.renderer.lock();
        renderer.config().font_size.value
    }

    // MARK: - 渲染标记

    /// 检查是否需要渲染
    #[inline]
    pub fn needs_render(&self) -> bool {
        self.needs_render.load(Ordering::Acquire)
    }

    /// 清除渲染标记
    #[inline]
    pub fn clear_render_flag(&self) {
        self.needs_render.store(false, Ordering::Release);
    }

    /// 获取 needs_render 的 Arc 引用
    pub fn needs_render_flag(&self) -> Arc<AtomicBool> {
        self.needs_render.clone()
    }

    /// 标记需要渲染
    #[inline]
    pub fn mark_needs_render(&self) {
        self.needs_render.store(true, Ordering::Release);
    }

    /// 清除指定终端的缓存
    pub fn invalidate_cache(&self, terminal_id: usize) {
        self.render_caches.lock().remove(&terminal_id);
    }

    /// 清除所有缓存
    pub fn clear_all_caches(&self) {
        self.render_caches.lock().clear();
    }
}
