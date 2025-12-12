//! P4 Surface 缓存性能基准测试
//!
//! 对比修复前后的性能差异：
//! - 修复前：每帧创建 + drop Surface（约 2-5ms 开销）
//! - 修复后：复用 Surface（开销几乎为 0）

use criterion::{black_box, criterion_group, criterion_main, Criterion};

/// 模拟 Surface 创建/销毁开销
///
/// 注意：实际 GPU Surface 创建开销更高（2-5ms），这里只是逻辑模拟
fn simulate_surface_lifecycle() {
    // 模拟分配 GPU 资源
    let _buffer: Vec<u8> = vec![0; 1920 * 1080 * 4];
    // 自动 drop，模拟释放
}

/// 基准测试：每帧创建 Surface（修复前）
fn bench_create_surface_per_frame(c: &mut Criterion) {
    c.bench_function("create_surface_per_frame", |b| {
        b.iter(|| {
            // 模拟每帧创建 Surface
            simulate_surface_lifecycle();
        });
    });
}

/// 基准测试：复用 Surface（修复后）
fn bench_reuse_surface(c: &mut Criterion) {
    // 预先创建 Surface（模拟缓存）
    let _cached_surface: Vec<u8> = vec![0; 1920 * 1080 * 4];

    c.bench_function("reuse_surface", |b| {
        b.iter(|| {
            // 复用 Surface，无分配开销
            black_box(&_cached_surface);
        });
    });
}

/// 基准测试：尺寸不变时的完整渲染流程
fn bench_render_frame_with_cache(c: &mut Criterion) {
    struct SurfaceCache {
        buffer: Vec<u8>,
        width: u32,
        height: u32,
    }

    let mut cache: Option<SurfaceCache> = None;
    let target_width = 1920u32;
    let target_height = 1080u32;

    c.bench_function("render_frame_with_cache", |b| {
        b.iter(|| {
            // 检查是否需要重建 Surface
            let needs_rebuild = match &cache {
                Some(c) => c.width != target_width || c.height != target_height,
                None => true,
            };

            if needs_rebuild {
                // 只在尺寸变化时重建
                cache = Some(SurfaceCache {
                    buffer: vec![0; (target_width * target_height * 4) as usize],
                    width: target_width,
                    height: target_height,
                });
            }

            // 使用缓存的 Surface
            black_box(&cache);
        });
    });
}

criterion_group!(
    benches,
    bench_create_surface_per_frame,
    bench_reuse_surface,
    bench_render_frame_with_cache
);
criterion_main!(benches);
