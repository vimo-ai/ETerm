//! 锁竞争测试 - 验证 RwLock 在 PTY 批量处理时是否会被渲染线程"插队"
//!
//! 这个测试模拟：
//! 1. PTY 线程：循环 try_write，处理多个数据包
//! 2. 渲染线程：尝试获取读锁
//!
//! 预期问题：渲染线程可能在 PTY 处理多个包之间获取到锁，
//! 导致渲染中间状态（部分闪烁）

use parking_lot::RwLock;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// 模拟终端状态
struct TerminalState {
    /// 当前已处理的"行数"
    lines_processed: usize,
    /// 本次批量更新的目标行数
    target_lines: usize,
    /// 更新是否完成
    update_complete: bool,
}

/// 测试结果
struct TestResult {
    /// 渲染次数
    render_count: usize,
    /// 渲染到中间状态的次数（lines_processed < target_lines 且 update_complete = false）
    partial_render_count: usize,
    /// PTY 批量处理次数
    pty_batch_count: usize,
}

/// 测试当前的 RwLock 行为（无 lease）
fn test_rwlock_without_lease() -> TestResult {
    let terminal = Arc::new(RwLock::new(TerminalState {
        lines_processed: 0,
        target_lines: 0,
        update_complete: true,
    }));

    let running = Arc::new(AtomicBool::new(true));
    let render_count = Arc::new(AtomicUsize::new(0));
    let partial_render_count = Arc::new(AtomicUsize::new(0));
    let pty_batch_count = Arc::new(AtomicUsize::new(0));

    // 渲染线程
    let terminal_render = terminal.clone();
    let running_render = running.clone();
    let render_count_clone = render_count.clone();
    let partial_render_clone = partial_render_count.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            // 模拟 VSync 间隔 (~16ms，但为了测试加快)
            thread::sleep(Duration::from_micros(500));

            // 尝试获取读锁进行渲染
            let state = terminal_render.read();
            render_count_clone.fetch_add(1, Ordering::Relaxed);

            // 检查是否渲染到了中间状态
            if !state.update_complete && state.lines_processed < state.target_lines {
                partial_render_clone.fetch_add(1, Ordering::Relaxed);
            }

            // 模拟渲染耗时
            thread::sleep(Duration::from_micros(100));
            drop(state);
        }
    });

    // PTY 线程
    let terminal_pty = terminal.clone();
    let pty_batch_clone = pty_batch_count.clone();

    let pty_thread = thread::spawn(move || {
        for batch in 0..100 {
            pty_batch_clone.fetch_add(1, Ordering::Relaxed);

            // 模拟一次批量更新（10行）
            let target = 10;

            // 开始批量更新
            {
                if let Some(mut state) = terminal_pty.try_write() {
                    state.target_lines = target;
                    state.lines_processed = 0;
                    state.update_complete = false;
                }
            }

            // 模拟逐行处理（类似 PTY 读取多个数据包）
            for line in 0..target {
                // 模拟数据到达的间隔
                thread::sleep(Duration::from_micros(50));

                // 尝试获取写锁处理这一行
                // 注意：这里用 try_write，如果获取不到就继续尝试
                let mut attempts = 0;
                loop {
                    if let Some(mut state) = terminal_pty.try_write() {
                        state.lines_processed = line + 1;
                        if line + 1 == target {
                            state.update_complete = true;
                        }
                        break;
                    }
                    attempts += 1;
                    if attempts > 100 {
                        // 强制获取
                        let mut state = terminal_pty.write();
                        state.lines_processed = line + 1;
                        if line + 1 == target {
                            state.update_complete = true;
                        }
                        break;
                    }
                    thread::yield_now();
                }
            }

            // 批量之间的间隔
            thread::sleep(Duration::from_micros(200));
        }
    });

    // 等待 PTY 线程完成
    pty_thread.join().unwrap();

    // 停止渲染线程
    running.store(false, Ordering::Relaxed);
    render_thread.join().unwrap();

    TestResult {
        render_count: render_count.load(Ordering::Relaxed),
        partial_render_count: partial_render_count.load(Ordering::Relaxed),
        pty_batch_count: pty_batch_count.load(Ordering::Relaxed),
    }
}

/// 模拟有 lease 机制的 FairMutex 行为
fn test_with_lease_simulation() -> TestResult {
    let terminal = Arc::new(RwLock::new(TerminalState {
        lines_processed: 0,
        target_lines: 0,
        update_complete: true,
    }));

    // 模拟 lease 的预约锁
    let lease = Arc::new(parking_lot::Mutex::new(()));

    let running = Arc::new(AtomicBool::new(true));
    let render_count = Arc::new(AtomicUsize::new(0));
    let partial_render_count = Arc::new(AtomicUsize::new(0));
    let pty_batch_count = Arc::new(AtomicUsize::new(0));

    // 渲染线程
    let terminal_render = terminal.clone();
    let lease_render = lease.clone();
    let running_render = running.clone();
    let render_count_clone = render_count.clone();
    let partial_render_clone = partial_render_count.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_micros(500));

            // 模拟 FairMutex::lock() - 需要先获取 lease
            let _lease_guard = lease_render.lock();
            let state = terminal_render.read();
            render_count_clone.fetch_add(1, Ordering::Relaxed);

            if !state.update_complete && state.lines_processed < state.target_lines {
                partial_render_clone.fetch_add(1, Ordering::Relaxed);
            }

            thread::sleep(Duration::from_micros(100));
            drop(state);
            drop(_lease_guard);
        }
    });

    // PTY 线程
    let terminal_pty = terminal.clone();
    let lease_pty = lease.clone();
    let pty_batch_clone = pty_batch_count.clone();

    let pty_thread = thread::spawn(move || {
        for batch in 0..100 {
            pty_batch_clone.fetch_add(1, Ordering::Relaxed);

            // 获取 lease（预约锁）- 整个批量处理期间持有
            let _lease_guard = lease_pty.lock();

            let target = 10;

            {
                let mut state = terminal_pty.write();
                state.target_lines = target;
                state.lines_processed = 0;
                state.update_complete = false;
            }

            for line in 0..target {
                thread::sleep(Duration::from_micros(50));

                // 有 lease 保护，可以直接获取写锁
                let mut state = terminal_pty.write();
                state.lines_processed = line + 1;
                if line + 1 == target {
                    state.update_complete = true;
                }
            }

            // 释放 lease
            drop(_lease_guard);

            thread::sleep(Duration::from_micros(200));
        }
    });

    pty_thread.join().unwrap();
    running.store(false, Ordering::Relaxed);
    render_thread.join().unwrap();

    TestResult {
        render_count: render_count.load(Ordering::Relaxed),
        partial_render_count: partial_render_count.load(Ordering::Relaxed),
        pty_batch_count: pty_batch_count.load(Ordering::Relaxed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_lock_contention_without_lease() {
        println!("\n========================================");
        println!("测试 1: 当前实现（无 lease）");
        println!("========================================");

        let result = test_rwlock_without_lease();

        println!("PTY 批量处理次数: {}", result.pty_batch_count);
        println!("渲染次数: {}", result.render_count);
        println!("渲染到中间状态次数: {}", result.partial_render_count);
        println!("中间状态渲染比例: {:.2}%",
                 result.partial_render_count as f64 / result.render_count as f64 * 100.0);

        // 预期：无 lease 时，会有较多中间状态渲染
        if result.partial_render_count > 0 {
            println!("⚠️  检测到 {} 次中间状态渲染 - 这就是闪烁的原因！", result.partial_render_count);
        }
    }

    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_lock_contention_with_lease() {
        println!("\n========================================");
        println!("测试 2: 模拟 FairMutex lease 机制");
        println!("========================================");

        let result = test_with_lease_simulation();

        println!("PTY 批量处理次数: {}", result.pty_batch_count);
        println!("渲染次数: {}", result.render_count);
        println!("渲染到中间状态次数: {}", result.partial_render_count);
        println!("中间状态渲染比例: {:.2}%",
                 result.partial_render_count as f64 / result.render_count.max(1) as f64 * 100.0);

        // 预期：有 lease 时，不应该有中间状态渲染
        if result.partial_render_count == 0 {
            println!("✅ 没有中间状态渲染 - lease 机制有效！");
        }
    }

    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn compare_with_and_without_lease() {
        println!("\n========================================");
        println!("对比测试：有无 lease 的差异");
        println!("========================================\n");

        // 多次运行取平均
        let mut without_lease_partial = 0;
        let mut with_lease_partial = 0;
        let runs = 5;

        for i in 0..runs {
            println!("运行 #{}", i + 1);

            let r1 = test_rwlock_without_lease();
            without_lease_partial += r1.partial_render_count;

            let r2 = test_with_lease_simulation();
            with_lease_partial += r2.partial_render_count;
        }

        println!("\n========== 结果汇总 ==========");
        println!("无 lease - 中间状态渲染总次数: {}", without_lease_partial);
        println!("有 lease - 中间状态渲染总次数: {}", with_lease_partial);

        if without_lease_partial > 0 && with_lease_partial == 0 {
            println!("\n✅ 结论：lease 机制可以有效防止中间状态渲染");
            println!("   当前无 lease 实现确实存在竞态条件导致的闪烁问题");
        }

        // 断言：无 lease 应该有中间状态，有 lease 应该没有
        assert!(without_lease_partial > 0, "无 lease 时应该检测到中间状态渲染");
        assert_eq!(with_lease_partial, 0, "有 lease 时不应该有中间状态渲染");
    }
}

// 供外部调用的公共函数
pub fn run_contention_test() {
    println!("运行锁竞争测试...\n");

    let r1 = test_rwlock_without_lease();
    println!("无 lease: {} 次中间状态渲染 / {} 次渲染",
             r1.partial_render_count, r1.render_count);

    let r2 = test_with_lease_simulation();
    println!("有 lease: {} 次中间状态渲染 / {} 次渲染",
             r2.partial_render_count, r2.render_count);
}

// ============================================================================
// Resize 卡死场景测试
// ============================================================================
//
// 问题场景：
// 1. CVDisplayLink 回调（非主线程）调用 render_all() → render_terminal()
// 2. render_terminal() 获取 terminals.write() 并在锁内渲染所有行（慢操作）
// 3. 主线程 layout() 触发 resize，需要获取 terminals.write()
// 4. 主线程被阻塞等待 VSync 回调释放锁
//
// 当终端有大量内容时（如 Claude CLI 对话后），渲染时间长，阻塞严重

/// 模拟终端渲染缓存
struct MockRenderCache {
    /// 已渲染的行数
    rendered_lines: usize,
    /// 缓存尺寸
    width: u32,
    height: u32,
}

/// 模拟终端条目（简化版）
struct MockTerminalEntry {
    /// 终端状态（模拟大量行）
    lines: Vec<String>,
    /// 渲染缓存
    render_cache: Option<MockRenderCache>,
    /// 终端尺寸
    cols: u16,
    rows: u16,
}

/// Resize 阻塞测试结果
#[derive(Debug)]
pub struct ResizeBlockingResult {
    /// 渲染帧数
    pub render_frames: usize,
    /// resize 次数
    pub resize_count: usize,
    /// resize 平均阻塞时间 (微秒)
    pub resize_avg_block_us: u64,
    /// resize 最大阻塞时间 (微秒)
    pub resize_max_block_us: u64,
    /// resize 超过 16ms (1帧) 的次数
    pub resize_over_frame_count: usize,
    /// resize 超过 100ms 的次数
    pub resize_over_100ms_count: usize,
}

/// 模拟当前架构下的 resize 阻塞情况
///
/// 复现问题：render_terminal() 在锁内渲染所有行，阻塞 resize
pub fn test_resize_blocking_current_architecture(terminal_lines: usize) -> ResizeBlockingResult {
    use std::collections::HashMap;
    use std::time::Instant;

    // 模拟 terminals: RwLock<HashMap<usize, MockTerminalEntry>>
    let terminals: Arc<RwLock<HashMap<usize, MockTerminalEntry>>> = Arc::new(RwLock::new({
        let mut map = HashMap::new();
        // 创建一个有大量行的终端（模拟 Claude CLI 对话后）
        let entry = MockTerminalEntry {
            lines: (0..terminal_lines).map(|i| format!("Line {}: some terminal content here with ANSI sequences...", i)).collect(),
            render_cache: None,
            cols: 80,
            rows: 24,
        };
        map.insert(1, entry);
        map
    }));

    let running = Arc::new(AtomicBool::new(true));
    let render_frames = Arc::new(AtomicUsize::new(0));
    let resize_count = Arc::new(AtomicUsize::new(0));
    let resize_total_block_us = Arc::new(AtomicUsize::new(0));
    let resize_max_block_us = Arc::new(AtomicUsize::new(0));
    let resize_over_frame = Arc::new(AtomicUsize::new(0));
    let resize_over_100ms = Arc::new(AtomicUsize::new(0));

    // 模拟 CVDisplayLink 回调线程（VSync，~60Hz）
    let terminals_render = terminals.clone();
    let running_render = running.clone();
    let render_frames_clone = render_frames.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            // 模拟 VSync 间隔 (~16ms，测试加速)
            thread::sleep(Duration::from_millis(2));

            // 模拟 render_terminal() - 获取写锁并在锁内渲染所有行
            let mut terminals_guard = terminals_render.write();

            if let Some(entry) = terminals_guard.get_mut(&1) {
                let line_count = entry.lines.len();

                // 模拟渲染每一行
                // 真实场景中 renderer.render_line() 涉及字体光栅化、Metal 操作
                // 每行大约 50-200μs，这里模拟 ~100μs/行（每 10 行 sleep 1ms）
                for i in 0..line_count {
                    // 模拟 renderer.render_line() 的开销
                    std::hint::black_box(&entry.lines[i]);
                    // 增加延迟模拟真实渲染开销
                    if i % 10 == 0 {
                        thread::sleep(Duration::from_micros(100));
                    }
                }

                // 更新渲染缓存
                entry.render_cache = Some(MockRenderCache {
                    rendered_lines: line_count,
                    width: 800,
                    height: 600,
                });
            }

            render_frames_clone.fetch_add(1, Ordering::Relaxed);
            drop(terminals_guard);
        }
    });

    // 模拟主线程 resize 操作
    let terminals_resize = terminals.clone();
    let resize_count_clone = resize_count.clone();
    let resize_total = resize_total_block_us.clone();
    let resize_max = resize_max_block_us.clone();
    let resize_over_frame_clone = resize_over_frame.clone();
    let resize_over_100ms_clone = resize_over_100ms.clone();

    let resize_thread = thread::spawn(move || {
        // 模拟用户连续 resize 窗口（拖动边缘）
        for _ in 0..50 {
            // 模拟 resize 触发间隔（~33ms，用户拖动速度）
            thread::sleep(Duration::from_millis(5));

            let start = Instant::now();

            // 尝试获取写锁进行 resize（这里会被渲染阻塞！）
            let mut terminals_guard = terminals_resize.write();

            let block_time = start.elapsed();
            let block_us = block_time.as_micros() as usize;

            // 更新统计
            resize_count_clone.fetch_add(1, Ordering::Relaxed);
            resize_total.fetch_add(block_us, Ordering::Relaxed);

            // 更新最大阻塞时间
            let mut current_max = resize_max.load(Ordering::Relaxed);
            while block_us > current_max {
                match resize_max.compare_exchange_weak(
                    current_max, block_us, Ordering::Relaxed, Ordering::Relaxed
                ) {
                    Ok(_) => break,
                    Err(x) => current_max = x,
                }
            }

            // 统计超过阈值的次数
            if block_us > 16_000 {  // > 16ms (1帧)
                resize_over_frame_clone.fetch_add(1, Ordering::Relaxed);
            }
            if block_us > 100_000 {  // > 100ms
                resize_over_100ms_clone.fetch_add(1, Ordering::Relaxed);
            }

            // 模拟 resize 操作
            if let Some(entry) = terminals_guard.get_mut(&1) {
                entry.cols = 100;
                entry.rows = 30;
                entry.render_cache = None;  // 清除缓存
            }

            drop(terminals_guard);
        }
    });

    // 等待 resize 完成
    resize_thread.join().unwrap();

    // 停止渲染
    running.store(false, Ordering::Relaxed);
    render_thread.join().unwrap();

    let total_resizes = resize_count.load(Ordering::Relaxed);

    ResizeBlockingResult {
        render_frames: render_frames.load(Ordering::Relaxed),
        resize_count: total_resizes,
        resize_avg_block_us: if total_resizes > 0 {
            resize_total_block_us.load(Ordering::Relaxed) as u64 / total_resizes as u64
        } else { 0 },
        resize_max_block_us: resize_max_block_us.load(Ordering::Relaxed) as u64,
        resize_over_frame_count: resize_over_frame.load(Ordering::Relaxed),
        resize_over_100ms_count: resize_over_100ms.load(Ordering::Relaxed),
    }
}

/// 模拟优化后的架构（渲染在锁外进行）
///
/// 优化：在锁外完成渲染，只在更新缓存时短暂持锁
pub fn test_resize_blocking_optimized_architecture(terminal_lines: usize) -> ResizeBlockingResult {
    use std::collections::HashMap;
    use std::time::Instant;

    let terminals: Arc<RwLock<HashMap<usize, MockTerminalEntry>>> = Arc::new(RwLock::new({
        let mut map = HashMap::new();
        let entry = MockTerminalEntry {
            lines: (0..terminal_lines).map(|i| format!("Line {}: some terminal content here with ANSI sequences...", i)).collect(),
            render_cache: None,
            cols: 80,
            rows: 24,
        };
        map.insert(1, entry);
        map
    }));

    let running = Arc::new(AtomicBool::new(true));
    let render_frames = Arc::new(AtomicUsize::new(0));
    let resize_count = Arc::new(AtomicUsize::new(0));
    let resize_total_block_us = Arc::new(AtomicUsize::new(0));
    let resize_max_block_us = Arc::new(AtomicUsize::new(0));
    let resize_over_frame = Arc::new(AtomicUsize::new(0));
    let resize_over_100ms = Arc::new(AtomicUsize::new(0));

    // 模拟优化后的 CVDisplayLink 回调
    let terminals_render = terminals.clone();
    let running_render = running.clone();
    let render_frames_clone = render_frames.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(2));

            // 优化：先用读锁获取数据快照
            let lines_snapshot: Vec<String> = {
                let terminals_guard = terminals_render.read();
                if let Some(entry) = terminals_guard.get(&1) {
                    entry.lines.clone()  // 克隆数据快照
                } else {
                    continue;
                }
            };
            // 读锁已释放！

            // 在锁外进行渲染（模拟）
            // 渲染开销与当前架构相同，但在锁外进行
            let line_count = lines_snapshot.len();
            for i in 0..line_count {
                std::hint::black_box(&lines_snapshot[i]);
                if i % 10 == 0 {
                    thread::sleep(Duration::from_micros(100));
                }
            }

            // 只在更新缓存时短暂持锁
            {
                let mut terminals_guard = terminals_render.write();
                if let Some(entry) = terminals_guard.get_mut(&1) {
                    entry.render_cache = Some(MockRenderCache {
                        rendered_lines: line_count,
                        width: 800,
                        height: 600,
                    });
                }
            }

            render_frames_clone.fetch_add(1, Ordering::Relaxed);
        }
    });

    // 模拟主线程 resize（与之前相同）
    let terminals_resize = terminals.clone();
    let resize_count_clone = resize_count.clone();
    let resize_total = resize_total_block_us.clone();
    let resize_max = resize_max_block_us.clone();
    let resize_over_frame_clone = resize_over_frame.clone();
    let resize_over_100ms_clone = resize_over_100ms.clone();

    let resize_thread = thread::spawn(move || {
        for _ in 0..50 {
            thread::sleep(Duration::from_millis(5));

            let start = Instant::now();
            let mut terminals_guard = terminals_resize.write();
            let block_time = start.elapsed();
            let block_us = block_time.as_micros() as usize;

            resize_count_clone.fetch_add(1, Ordering::Relaxed);
            resize_total.fetch_add(block_us, Ordering::Relaxed);

            let mut current_max = resize_max.load(Ordering::Relaxed);
            while block_us > current_max {
                match resize_max.compare_exchange_weak(
                    current_max, block_us, Ordering::Relaxed, Ordering::Relaxed
                ) {
                    Ok(_) => break,
                    Err(x) => current_max = x,
                }
            }

            if block_us > 16_000 {
                resize_over_frame_clone.fetch_add(1, Ordering::Relaxed);
            }
            if block_us > 100_000 {
                resize_over_100ms_clone.fetch_add(1, Ordering::Relaxed);
            }

            if let Some(entry) = terminals_guard.get_mut(&1) {
                entry.cols = 100;
                entry.rows = 30;
                entry.render_cache = None;
            }

            drop(terminals_guard);
        }
    });

    resize_thread.join().unwrap();
    running.store(false, Ordering::Relaxed);
    render_thread.join().unwrap();

    let total_resizes = resize_count.load(Ordering::Relaxed);

    ResizeBlockingResult {
        render_frames: render_frames.load(Ordering::Relaxed),
        resize_count: total_resizes,
        resize_avg_block_us: if total_resizes > 0 {
            resize_total_block_us.load(Ordering::Relaxed) as u64 / total_resizes as u64
        } else { 0 },
        resize_max_block_us: resize_max_block_us.load(Ordering::Relaxed) as u64,
        resize_over_frame_count: resize_over_frame.load(Ordering::Relaxed),
        resize_over_100ms_count: resize_over_100ms.load(Ordering::Relaxed),
    }
}

// ============================================================================
// 死锁场景测试
// ============================================================================
//
// 问题场景：layout() 和 end_frame() 以不同顺序获取锁
//
// 主线程 (layout):
//   1. resizeSugarloaf() → sugarloaf.lock()
//   2. syncLayoutToRust() → render_layout.lock()
//
// 渲染线程 (CVDisplayLink end_frame):
//   1. render_layout.lock()
//   2. sugarloaf.lock()
//
// 这是典型的死锁模式：锁获取顺序不一致

use parking_lot::Mutex as ParkingMutex;

/// 死锁测试结果
#[derive(Debug)]
pub struct DeadlockTestResult {
    /// 是否检测到死锁（超时）
    pub deadlock_detected: bool,
    /// 完成的 resize 次数
    pub completed_resizes: usize,
    /// 完成的渲染帧数
    pub completed_frames: usize,
    /// 测试耗时 (ms)
    pub elapsed_ms: u64,
}

/// 测试死锁场景 - 复现 layout() 和 end_frame() 的锁顺序冲突
///
/// 返回 true 表示发生死锁（超时）
pub fn test_deadlock_scenario() -> DeadlockTestResult {
    use std::time::{Duration, Instant};

    // 模拟两个锁
    let sugarloaf: Arc<ParkingMutex<u32>> = Arc::new(ParkingMutex::new(0));
    let render_layout: Arc<ParkingMutex<Vec<(usize, f32, f32)>>> = Arc::new(ParkingMutex::new(vec![]));

    let running = Arc::new(AtomicBool::new(true));
    let completed_resizes = Arc::new(AtomicUsize::new(0));
    let completed_frames = Arc::new(AtomicUsize::new(0));

    let start = Instant::now();

    // 渲染线程 - 模拟 end_frame()
    // 锁顺序：render_layout → sugarloaf
    let sugarloaf_render = sugarloaf.clone();
    let layout_render = render_layout.clone();
    let running_render = running.clone();
    let frames = completed_frames.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            // 模拟 VSync 间隔
            thread::sleep(Duration::from_millis(2));

            // 模拟 end_frame() 锁顺序
            // 1. 先获取 render_layout
            let _layout = layout_render.lock();
            thread::sleep(Duration::from_micros(100));

            // 2. 再获取 sugarloaf
            let mut sugar = sugarloaf_render.lock();
            *sugar += 1;
            drop(sugar);
            drop(_layout);

            frames.fetch_add(1, Ordering::Relaxed);
        }
    });

    // 主线程 - 模拟 layout()
    // 锁顺序：sugarloaf → render_layout（与渲染线程相反！）
    let sugarloaf_main = sugarloaf.clone();
    let layout_main = render_layout.clone();
    let running_main = running.clone();
    let resizes = completed_resizes.clone();

    let main_thread = thread::spawn(move || {
        for _ in 0..100 {
            if !running_main.load(Ordering::Relaxed) {
                break;
            }

            thread::sleep(Duration::from_millis(3));

            // 模拟 layout() 锁顺序
            // 1. 先获取 sugarloaf (resizeSugarloaf)
            let mut sugar = sugarloaf_main.lock();
            *sugar += 1;
            thread::sleep(Duration::from_micros(100));

            // 2. 再获取 render_layout (syncLayoutToRust)
            // 这里可能发生死锁！
            let mut layout = layout_main.lock();
            layout.push((1, 0.0, 0.0));
            drop(layout);
            drop(sugar);

            resizes.fetch_add(1, Ordering::Relaxed);
        }

        running_main.store(false, Ordering::Relaxed);
    });

    // 设置超时检测
    let timeout = Duration::from_secs(3);
    let deadline = Instant::now() + timeout;

    // 等待主线程完成或超时
    loop {
        if !running.load(Ordering::Relaxed) {
            break;
        }
        if Instant::now() > deadline {
            // 超时 = 死锁
            running.store(false, Ordering::Relaxed);
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    let elapsed = start.elapsed();
    let deadlock_detected = elapsed >= timeout;

    // 强制终止（如果死锁，线程可能无法正常退出）
    // 注意：真正的死锁无法被终止，这里只是尽力等待
    let _ = render_thread.join();
    let _ = main_thread.join();

    DeadlockTestResult {
        deadlock_detected,
        completed_resizes: completed_resizes.load(Ordering::Relaxed),
        completed_frames: completed_frames.load(Ordering::Relaxed),
        elapsed_ms: elapsed.as_millis() as u64,
    }
}

/// 测试修复后的锁顺序 - 统一为 sugarloaf → render_layout
///
/// 修复方案：确保所有线程以相同顺序获取锁
pub fn test_fixed_lock_order() -> DeadlockTestResult {
    use std::time::{Duration, Instant};

    let sugarloaf: Arc<ParkingMutex<u32>> = Arc::new(ParkingMutex::new(0));
    let render_layout: Arc<ParkingMutex<Vec<(usize, f32, f32)>>> = Arc::new(ParkingMutex::new(vec![]));

    let running = Arc::new(AtomicBool::new(true));
    let completed_resizes = Arc::new(AtomicUsize::new(0));
    let completed_frames = Arc::new(AtomicUsize::new(0));

    let start = Instant::now();

    // 渲染线程 - 修复后的 end_frame()
    // 锁顺序改为：sugarloaf → render_layout（与主线程一致）
    let sugarloaf_render = sugarloaf.clone();
    let layout_render = render_layout.clone();
    let running_render = running.clone();
    let frames = completed_frames.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(2));

            // 修复：先获取 sugarloaf（与主线程顺序一致）
            let mut sugar = sugarloaf_render.lock();
            thread::sleep(Duration::from_micros(50));

            // 再获取 render_layout
            let _layout = layout_render.lock();

            *sugar += 1;
            drop(_layout);
            drop(sugar);

            frames.fetch_add(1, Ordering::Relaxed);
        }
    });

    // 主线程 - layout()
    let sugarloaf_main = sugarloaf.clone();
    let layout_main = render_layout.clone();
    let running_main = running.clone();
    let resizes = completed_resizes.clone();

    let main_thread = thread::spawn(move || {
        for _ in 0..100 {
            if !running_main.load(Ordering::Relaxed) {
                break;
            }

            thread::sleep(Duration::from_millis(3));

            // 锁顺序：sugarloaf → render_layout
            let mut sugar = sugarloaf_main.lock();
            *sugar += 1;
            thread::sleep(Duration::from_micros(50));

            let mut layout = layout_main.lock();
            layout.push((1, 0.0, 0.0));
            drop(layout);
            drop(sugar);

            resizes.fetch_add(1, Ordering::Relaxed);
        }

        running_main.store(false, Ordering::Relaxed);
    });

    let timeout = Duration::from_secs(3);
    let deadline = Instant::now() + timeout;

    loop {
        if !running.load(Ordering::Relaxed) {
            break;
        }
        if Instant::now() > deadline {
            running.store(false, Ordering::Relaxed);
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    let elapsed = start.elapsed();
    let deadlock_detected = elapsed >= timeout;

    let _ = render_thread.join();
    let _ = main_thread.join();

    DeadlockTestResult {
        deadlock_detected,
        completed_resizes: completed_resizes.load(Ordering::Relaxed),
        completed_frames: completed_frames.load(Ordering::Relaxed),
        elapsed_ms: elapsed.as_millis() as u64,
    }
}

#[cfg(test)]
mod deadlock_tests {
    use super::*;

    /// 测试：复现死锁场景
    ///
    /// 注意：这个测试可能会挂起（死锁），所以有 3 秒超时
    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_deadlock_reproduction() {
        println!("\n========================================");
        println!("死锁场景复现测试");
        println!("========================================\n");

        println!("场景：模拟 layout() 和 end_frame() 的锁顺序冲突");
        println!("- 主线程 (layout): sugarloaf → render_layout");
        println!("- 渲染线程 (end_frame): render_layout → sugarloaf\n");

        let result = test_deadlock_scenario();

        println!("测试结果：");
        println!("- 死锁检测: {}", if result.deadlock_detected { "⚠️ 发生死锁（超时）" } else { "✅ 未发生死锁" });
        println!("- 完成的 resize 次数: {}/100", result.completed_resizes);
        println!("- 完成的渲染帧数: {}", result.completed_frames);
        println!("- 测试耗时: {}ms", result.elapsed_ms);

        // 注意：死锁是否发生取决于线程调度，不做强断言
        // 但如果完成次数远低于预期，说明存在问题
        if result.completed_resizes < 50 {
            println!("\n⚠️ 警告：resize 完成次数过低，可能存在锁竞争或死锁风险");
        }
    }

    /// 测试：验证修复后的锁顺序不会死锁
    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_fixed_lock_order_no_deadlock() {
        println!("\n========================================");
        println!("修复后的锁顺序测试");
        println!("========================================\n");

        println!("修复方案：统一锁顺序为 sugarloaf → render_layout");
        println!("- 主线程 (layout): sugarloaf → render_layout");
        println!("- 渲染线程 (end_frame): sugarloaf → render_layout\n");

        let result = test_fixed_lock_order();

        println!("测试结果：");
        println!("- 死锁检测: {}", if result.deadlock_detected { "⚠️ 发生死锁（超时）" } else { "✅ 未发生死锁" });
        println!("- 完成的 resize 次数: {}/100", result.completed_resizes);
        println!("- 完成的渲染帧数: {}", result.completed_frames);
        println!("- 测试耗时: {}ms", result.elapsed_ms);

        // 断言：修复后不应该死锁
        assert!(!result.deadlock_detected, "修复后不应该发生死锁");
        assert!(result.completed_resizes >= 90, "应该完成大部分 resize 操作");
    }

    /// 对比测试
    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_deadlock_comparison() {
        println!("\n========================================");
        println!("死锁对比测试");
        println!("========================================\n");

        println!("运行原始场景（可能死锁）...");
        let original = test_deadlock_scenario();

        println!("运行修复场景...");
        let fixed = test_fixed_lock_order();

        println!("\n========== 结果对比 ==========\n");

        println!("| 指标 | 原始实现 | 修复后 |");
        println!("|------|----------|--------|");
        println!("| 死锁 | {} | {} |",
                 if original.deadlock_detected { "⚠️ 是" } else { "否" },
                 if fixed.deadlock_detected { "⚠️ 是" } else { "否" });
        println!("| resize 完成 | {}/100 | {}/100 |",
                 original.completed_resizes, fixed.completed_resizes);
        println!("| 渲染帧数 | {} | {} |",
                 original.completed_frames, fixed.completed_frames);
        println!("| 耗时 | {}ms | {}ms |",
                 original.elapsed_ms, fixed.elapsed_ms);

        println!("\n========== 结论 ==========\n");

        if original.deadlock_detected || original.completed_resizes < 50 {
            println!("⚠️  原始实现存在死锁风险！");
            println!("   锁顺序不一致会导致随机死锁");
        }

        if !fixed.deadlock_detected && fixed.completed_resizes >= 90 {
            println!("✅ 修复方案有效：统一锁顺序消除死锁");
        }
    }
}

#[cfg(test)]
mod resize_blocking_tests {
    use super::*;

    /// 测试：复现 resize 卡死问题
    ///
    /// 场景：终端有 1000 行内容（模拟 Claude CLI 对话后）
    /// 预期：当前架构下 resize 会被渲染严重阻塞
    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_resize_blocking_with_large_terminal() {
        println!("\n========================================");
        println!("Resize 卡死场景测试");
        println!("========================================\n");

        // 测试不同终端大小
        let test_cases = [
            (100, "小型终端 (100行)"),
            (500, "中型终端 (500行)"),
            (1000, "大型终端 (1000行) - Claude CLI 对话后"),
            (2000, "超大终端 (2000行) - 长时间运行后"),
        ];

        println!("| 场景 | 行数 | 平均阻塞 | 最大阻塞 | >16ms次数 | >100ms次数 |");
        println!("|------|------|----------|----------|-----------|------------|");

        for (lines, desc) in test_cases {
            let result = test_resize_blocking_current_architecture(lines);

            println!("| {} | {} | {}μs | {}μs | {} | {} |",
                     desc, lines,
                     result.resize_avg_block_us,
                     result.resize_max_block_us,
                     result.resize_over_frame_count,
                     result.resize_over_100ms_count);
        }

        println!("\n说明：");
        println!("- >16ms 表示阻塞超过 1 帧，用户会感到卡顿");
        println!("- >100ms 表示严重卡顿，用户体验极差");
    }

    /// 测试：对比当前架构 vs 优化架构
    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_resize_blocking_comparison() {
        println!("\n========================================");
        println!("Resize 阻塞对比测试：当前 vs 优化");
        println!("========================================\n");

        let terminal_lines = 1000;  // Claude CLI 对话后典型场景

        println!("测试场景：终端有 {} 行内容\n", terminal_lines);

        // 当前架构
        println!("测试当前架构（渲染在锁内）...");
        let current = test_resize_blocking_current_architecture(terminal_lines);

        // 优化架构
        println!("测试优化架构（渲染在锁外）...");
        let optimized = test_resize_blocking_optimized_architecture(terminal_lines);

        println!("\n========== 结果对比 ==========\n");

        println!("| 指标 | 当前架构 | 优化架构 | 改进 |");
        println!("|------|----------|----------|------|");
        println!("| 平均阻塞 (μs) | {} | {} | {:.1}x |",
                 current.resize_avg_block_us,
                 optimized.resize_avg_block_us,
                 if optimized.resize_avg_block_us > 0 {
                     current.resize_avg_block_us as f64 / optimized.resize_avg_block_us as f64
                 } else { f64::INFINITY });
        println!("| 最大阻塞 (μs) | {} | {} | {:.1}x |",
                 current.resize_max_block_us,
                 optimized.resize_max_block_us,
                 if optimized.resize_max_block_us > 0 {
                     current.resize_max_block_us as f64 / optimized.resize_max_block_us as f64
                 } else { f64::INFINITY });
        println!("| >16ms 次数 | {} | {} | -{}次 |",
                 current.resize_over_frame_count,
                 optimized.resize_over_frame_count,
                 current.resize_over_frame_count.saturating_sub(optimized.resize_over_frame_count));
        println!("| >100ms 次数 | {} | {} | -{}次 |",
                 current.resize_over_100ms_count,
                 optimized.resize_over_100ms_count,
                 current.resize_over_100ms_count.saturating_sub(optimized.resize_over_100ms_count));

        println!("\n========== 结论 ==========\n");

        if current.resize_max_block_us > 16_000 {
            println!("⚠️  当前架构：最大阻塞 {}ms，超过 1 帧，会导致 UI 卡顿",
                     current.resize_max_block_us / 1000);
        }

        if current.resize_over_frame_count > 0 {
            println!("⚠️  当前架构：{} 次 resize 超过 16ms，用户会感到卡顿",
                     current.resize_over_frame_count);
        }

        if optimized.resize_max_block_us < current.resize_max_block_us / 2 {
            println!("✅ 优化架构：最大阻塞降低 {:.1}x，显著改善用户体验",
                     current.resize_max_block_us as f64 / optimized.resize_max_block_us.max(1) as f64);
        }

        // 断言：优化架构应该比当前架构阻塞更短
        // 注意：由于测试环境的变化，不对绝对数值做断言
        // 只验证优化架构确实减少了阻塞
        assert!(optimized.resize_avg_block_us <= current.resize_avg_block_us,
                "优化架构应该降低或保持 resize 阻塞 (当前: {}μs, 优化: {}μs)",
                current.resize_avg_block_us, optimized.resize_avg_block_us);

        // 如果当前架构有明显阻塞，优化架构应该显著改善
        if current.resize_avg_block_us > 100 {
            let improvement = current.resize_avg_block_us as f64 / optimized.resize_avg_block_us.max(1) as f64;
            assert!(improvement >= 2.0,
                    "当有明显阻塞时，优化架构应至少改善 2x (实际: {:.1}x)",
                    improvement);
        }
    }

    /// 测试：验证问题复现 - Claude CLI 场景
    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn test_claude_cli_resize_scenario() {
        println!("\n========================================");
        println!("Claude CLI 场景复现测试");
        println!("========================================\n");

        println!("场景：用户在 ETerm 中运行 Claude CLI，");
        println!("完成一段对话后（产生大量输出），");
        println!("尝试 resize 窗口时遇到卡死。\n");

        // 模拟 Claude CLI 对话后的终端状态
        // 典型对话可能产生 500-2000 行输出
        let result = test_resize_blocking_current_architecture(1500);

        println!("测试结果：");
        println!("- 渲染帧数: {}", result.render_frames);
        println!("- resize 次数: {}", result.resize_count);
        println!("- 平均阻塞: {}μs ({:.2}ms)",
                 result.resize_avg_block_us,
                 result.resize_avg_block_us as f64 / 1000.0);
        println!("- 最大阻塞: {}μs ({:.2}ms)",
                 result.resize_max_block_us,
                 result.resize_max_block_us as f64 / 1000.0);
        println!("- 超过 1 帧 (16ms) 的次数: {}", result.resize_over_frame_count);
        println!("- 超过 100ms 的次数: {}", result.resize_over_100ms_count);

        println!("\n诊断：");
        if result.resize_max_block_us > 100_000 {
            println!("❌ 严重问题：resize 最大阻塞超过 100ms，用户体验为「卡死」");
            println!("   原因：render_terminal() 在 terminals.write() 锁内渲染所有行");
            println!("   建议：将渲染操作移出锁范围，只在更新缓存时短暂持锁");
        } else if result.resize_max_block_us > 16_000 {
            println!("⚠️  问题：resize 阻塞超过 16ms，用户会感到卡顿");
        } else {
            println!("✅ 正常：resize 阻塞在可接受范围内");
        }
    }
}

// ============================================================================
// 性能对比测试：RwLock vs FairRwLock
// ============================================================================

use crate::FairRwLock;
use std::time::Instant;

/// 性能测试结果
struct PerfResult {
    /// 总写入次数
    write_count: usize,
    /// 总读取次数
    read_count: usize,
    /// 中间状态读取次数
    partial_read_count: usize,
    /// 写入总耗时 (微秒)
    write_time_us: u64,
    /// 读取平均延迟 (微秒)
    read_avg_latency_us: u64,
    /// 读取最大延迟 (微秒)
    read_max_latency_us: u64,
}

/// 测试普通 RwLock 的性能
fn bench_rwlock_performance() -> PerfResult {
    let lock = Arc::new(RwLock::new(TerminalState {
        lines_processed: 0,
        target_lines: 0,
        update_complete: true,
    }));

    let running = Arc::new(AtomicBool::new(true));
    let read_count = Arc::new(AtomicUsize::new(0));
    let partial_count = Arc::new(AtomicUsize::new(0));
    let read_latency_sum = Arc::new(AtomicUsize::new(0));
    let read_max_latency = Arc::new(AtomicUsize::new(0));

    // 渲染线程
    let lock_render = lock.clone();
    let running_render = running.clone();
    let read_count_clone = read_count.clone();
    let partial_clone = partial_count.clone();
    let latency_sum = read_latency_sum.clone();
    let max_latency = read_max_latency.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_micros(200));

            let start = Instant::now();
            let state = lock_render.read();
            let latency = start.elapsed().as_micros() as usize;

            read_count_clone.fetch_add(1, Ordering::Relaxed);
            latency_sum.fetch_add(latency, Ordering::Relaxed);

            // 更新最大延迟
            let mut current_max = max_latency.load(Ordering::Relaxed);
            while latency > current_max {
                match max_latency.compare_exchange_weak(
                    current_max, latency, Ordering::Relaxed, Ordering::Relaxed
                ) {
                    Ok(_) => break,
                    Err(x) => current_max = x,
                }
            }

            if !state.update_complete && state.lines_processed < state.target_lines {
                partial_clone.fetch_add(1, Ordering::Relaxed);
            }
            drop(state);
        }
    });

    // PTY 线程
    let lock_pty = lock.clone();
    let write_start = Instant::now();

    const BATCHES: usize = 200;
    const LINES_PER_BATCH: usize = 10;

    for _batch in 0..BATCHES {
        // 开始批量更新
        {
            if let Some(mut state) = lock_pty.try_write() {
                state.target_lines = LINES_PER_BATCH;
                state.lines_processed = 0;
                state.update_complete = false;
            }
        }

        for line in 0..LINES_PER_BATCH {
            thread::sleep(Duration::from_micros(20));

            loop {
                if let Some(mut state) = lock_pty.try_write() {
                    state.lines_processed = line + 1;
                    if line + 1 == LINES_PER_BATCH {
                        state.update_complete = true;
                    }
                    break;
                }
                thread::yield_now();
            }
        }
    }

    let write_time = write_start.elapsed().as_micros() as u64;

    running.store(false, Ordering::Relaxed);
    render_thread.join().unwrap();

    let total_reads = read_count.load(Ordering::Relaxed);

    PerfResult {
        write_count: BATCHES * LINES_PER_BATCH,
        read_count: total_reads,
        partial_read_count: partial_count.load(Ordering::Relaxed),
        write_time_us: write_time,
        read_avg_latency_us: if total_reads > 0 {
            read_latency_sum.load(Ordering::Relaxed) as u64 / total_reads as u64
        } else { 0 },
        read_max_latency_us: read_max_latency.load(Ordering::Relaxed) as u64,
    }
}

/// 测试 FairRwLock 的性能
fn bench_fair_rwlock_performance() -> PerfResult {
    let lock = Arc::new(FairRwLock::new(TerminalState {
        lines_processed: 0,
        target_lines: 0,
        update_complete: true,
    }));

    let running = Arc::new(AtomicBool::new(true));
    let read_count = Arc::new(AtomicUsize::new(0));
    let partial_count = Arc::new(AtomicUsize::new(0));
    let read_latency_sum = Arc::new(AtomicUsize::new(0));
    let read_max_latency = Arc::new(AtomicUsize::new(0));

    // 渲染线程
    let lock_render = lock.clone();
    let running_render = running.clone();
    let read_count_clone = read_count.clone();
    let partial_clone = partial_count.clone();
    let latency_sum = read_latency_sum.clone();
    let max_latency = read_max_latency.clone();

    let render_thread = thread::spawn(move || {
        while running_render.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_micros(200));

            let start = Instant::now();
            let state = lock_render.read(); // FairRwLock::read() 会等待 lease
            let latency = start.elapsed().as_micros() as usize;

            read_count_clone.fetch_add(1, Ordering::Relaxed);
            latency_sum.fetch_add(latency, Ordering::Relaxed);

            let mut current_max = max_latency.load(Ordering::Relaxed);
            while latency > current_max {
                match max_latency.compare_exchange_weak(
                    current_max, latency, Ordering::Relaxed, Ordering::Relaxed
                ) {
                    Ok(_) => break,
                    Err(x) => current_max = x,
                }
            }

            if !state.update_complete && state.lines_processed < state.target_lines {
                partial_clone.fetch_add(1, Ordering::Relaxed);
            }
            drop(state);
        }
    });

    // PTY 线程
    let lock_pty = lock.clone();
    let write_start = Instant::now();

    const BATCHES: usize = 200;
    const LINES_PER_BATCH: usize = 10;

    for _batch in 0..BATCHES {
        // 获取 lease 开始批量处理
        let _lease = lock_pty.lease();

        // 开始批量更新
        {
            let mut state = lock_pty.write_unfair();
            state.target_lines = LINES_PER_BATCH;
            state.lines_processed = 0;
            state.update_complete = false;
        }

        for line in 0..LINES_PER_BATCH {
            thread::sleep(Duration::from_micros(20));

            let mut state = lock_pty.write_unfair();
            state.lines_processed = line + 1;
            if line + 1 == LINES_PER_BATCH {
                state.update_complete = true;
            }
        }

        // 释放 lease
    }

    let write_time = write_start.elapsed().as_micros() as u64;

    running.store(false, Ordering::Relaxed);
    render_thread.join().unwrap();

    let total_reads = read_count.load(Ordering::Relaxed);

    PerfResult {
        write_count: BATCHES * LINES_PER_BATCH,
        read_count: total_reads,
        partial_read_count: partial_count.load(Ordering::Relaxed),
        write_time_us: write_time,
        read_avg_latency_us: if total_reads > 0 {
            read_latency_sum.load(Ordering::Relaxed) as u64 / total_reads as u64
        } else { 0 },
        read_max_latency_us: read_max_latency.load(Ordering::Relaxed) as u64,
    }
}

#[cfg(test)]
mod perf_tests {
    use super::*;

    #[test]
    #[ignore = "压力测试，运行: cargo test lock_contention -- --ignored"]
    fn benchmark_rwlock_vs_fair_rwlock() {
        println!("\n========================================");
        println!("性能对比：RwLock vs FairRwLock");
        println!("========================================\n");

        // 多次运行取平均
        const RUNS: usize = 3;
        let mut rwlock_results = Vec::new();
        let mut fair_results = Vec::new();

        for i in 0..RUNS {
            println!("运行 #{}", i + 1);

            let r1 = bench_rwlock_performance();
            rwlock_results.push(r1);

            let r2 = bench_fair_rwlock_performance();
            fair_results.push(r2);
        }

        // 计算平均值
        let rwlock_avg_partial: f64 = rwlock_results.iter()
            .map(|r| r.partial_read_count as f64)
            .sum::<f64>() / RUNS as f64;
        let rwlock_avg_read_latency: f64 = rwlock_results.iter()
            .map(|r| r.read_avg_latency_us as f64)
            .sum::<f64>() / RUNS as f64;
        let rwlock_max_read_latency: u64 = rwlock_results.iter()
            .map(|r| r.read_max_latency_us)
            .max()
            .unwrap_or(0);
        let rwlock_avg_write_time: f64 = rwlock_results.iter()
            .map(|r| r.write_time_us as f64)
            .sum::<f64>() / RUNS as f64;

        let fair_avg_partial: f64 = fair_results.iter()
            .map(|r| r.partial_read_count as f64)
            .sum::<f64>() / RUNS as f64;
        let fair_avg_read_latency: f64 = fair_results.iter()
            .map(|r| r.read_avg_latency_us as f64)
            .sum::<f64>() / RUNS as f64;
        let fair_max_read_latency: u64 = fair_results.iter()
            .map(|r| r.read_max_latency_us)
            .max()
            .unwrap_or(0);
        let fair_avg_write_time: f64 = fair_results.iter()
            .map(|r| r.write_time_us as f64)
            .sum::<f64>() / RUNS as f64;

        println!("\n========== 结果对比 ==========\n");

        println!("| 指标                  | RwLock      | FairRwLock  | 差异      |");
        println!("|----------------------|-------------|-------------|-----------|");
        println!("| 中间状态读取 (平均)   | {:<11.1} | {:<11.1} | {:<9} |",
                 rwlock_avg_partial, fair_avg_partial,
                 if fair_avg_partial < rwlock_avg_partial { "✅ 更好" } else { "❌ 更差" });
        println!("| 读取延迟-平均 (µs)    | {:<11.1} | {:<11.1} | {:<+9.1} |",
                 rwlock_avg_read_latency, fair_avg_read_latency,
                 fair_avg_read_latency - rwlock_avg_read_latency);
        println!("| 读取延迟-最大 (µs)    | {:<11} | {:<11} | {:<+9} |",
                 rwlock_max_read_latency, fair_max_read_latency,
                 fair_max_read_latency as i64 - rwlock_max_read_latency as i64);
        println!("| 写入总耗时 (ms)       | {:<11.2} | {:<11.2} | {:<+9.2} |",
                 rwlock_avg_write_time / 1000.0, fair_avg_write_time / 1000.0,
                 (fair_avg_write_time - rwlock_avg_write_time) / 1000.0);

        println!("\n========== 结论 ==========\n");

        if fair_avg_partial == 0.0 && rwlock_avg_partial > 0.0 {
            println!("✅ FairRwLock 完全消除了中间状态读取（闪烁）");
        }

        let latency_increase_pct = if rwlock_avg_read_latency > 0.0 {
            (fair_avg_read_latency - rwlock_avg_read_latency) / rwlock_avg_read_latency * 100.0
        } else { 0.0 };

        if latency_increase_pct < 50.0 {
            println!("✅ 读取延迟增加可接受 ({:.1}%)", latency_increase_pct);
        } else {
            println!("⚠️  读取延迟增加较多 ({:.1}%)，需要关注", latency_increase_pct);
        }

        let write_time_diff_pct = if rwlock_avg_write_time > 0.0 {
            (fair_avg_write_time - rwlock_avg_write_time) / rwlock_avg_write_time * 100.0
        } else { 0.0 };

        if write_time_diff_pct.abs() < 10.0 {
            println!("✅ 写入性能基本无影响 ({:+.1}%)", write_time_diff_pct);
        } else if write_time_diff_pct < 0.0 {
            println!("✅ 写入性能甚至有所提升 ({:+.1}%)", write_time_diff_pct);
        } else {
            println!("⚠️  写入性能有所下降 ({:+.1}%)", write_time_diff_pct);
        }

        // 断言：FairRwLock 不应该有中间状态读取
        assert_eq!(fair_avg_partial, 0.0,
                   "FairRwLock 不应该有中间状态读取");
    }
}
