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
