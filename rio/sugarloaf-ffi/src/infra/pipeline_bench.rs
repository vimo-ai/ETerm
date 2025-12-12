//! Pipeline Benchmark - 渲染管线性能测试
//!
//! 测量各阶段耗时，数据可作为架构优化参考

#[cfg(test)]
mod tests {
    use crate::domain::aggregates::{Terminal, TerminalId};
    use std::time::Instant;

    /// 生成测试用 ANSI 数据
    fn generate_ansi_data(size: usize) -> Vec<u8> {
        let mut data = Vec::with_capacity(size);
        let line = b"\x1b[31mHello \x1b[32mWorld \x1b[0m123456789\r\n";
        while data.len() < size {
            data.extend_from_slice(line);
        }
        data.truncate(size);
        data
    }

    /// 生成纯文本数据（无 ANSI）
    fn generate_plain_text(size: usize) -> Vec<u8> {
        let mut data = Vec::with_capacity(size);
        let line = b"Hello World 1234567890 abcdefghij\r\n";
        while data.len() < size {
            data.extend_from_slice(line);
        }
        data.truncate(size);
        data
    }

    /// 生成高复杂度 ANSI 数据（大量颜色切换）
    fn generate_complex_ansi(size: usize) -> Vec<u8> {
        let mut data = Vec::with_capacity(size);
        // 每个字符都切换颜色
        for i in 0..size {
            let color = 31 + (i % 7) as u8; // 31-37 循环
            data.extend_from_slice(format!("\x1b[{}m{}", color, (b'A' + (i % 26) as u8) as char).as_bytes());
        }
        data
    }

    // =========================================================================
    // Stage 1: ANSI 解析 + Grid 写入
    // =========================================================================

    #[test]
    fn bench_write_plain_text_1kb() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        let data = generate_plain_text(1024);

        let iterations = 1000;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(&data);
        }
        let elapsed = start.elapsed();

        let total_bytes = 1024 * iterations;
        let throughput_mb = (total_bytes as f64) / elapsed.as_secs_f64() / 1_000_000.0;

        println!("\n📊 [Plain Text 1KB × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per write: {:?}", elapsed / iterations);
        println!("   Throughput: {:.2} MB/s", throughput_mb);
    }

    #[test]
    fn bench_write_ansi_1kb() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        let data = generate_ansi_data(1024);

        let iterations = 1000;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(&data);
        }
        let elapsed = start.elapsed();

        let total_bytes = 1024 * iterations;
        let throughput_mb = (total_bytes as f64) / elapsed.as_secs_f64() / 1_000_000.0;

        println!("\n📊 [ANSI 1KB × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per write: {:?}", elapsed / iterations);
        println!("   Throughput: {:.2} MB/s", throughput_mb);
    }

    #[test]
    fn bench_write_complex_ansi_1kb() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        let data = generate_complex_ansi(1024);

        let iterations = 1000;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(&data);
        }
        let elapsed = start.elapsed();

        let total_bytes = 1024 * iterations;
        let throughput_mb = (total_bytes as f64) / elapsed.as_secs_f64() / 1_000_000.0;

        println!("\n📊 [Complex ANSI 1KB × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per write: {:?}", elapsed / iterations);
        println!("   Throughput: {:.2} MB/s", throughput_mb);
    }

    #[test]
    fn bench_write_ansi_10kb() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        let data = generate_ansi_data(10 * 1024);

        let iterations = 100;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(&data);
        }
        let elapsed = start.elapsed();

        let total_bytes = 10 * 1024 * iterations;
        let throughput_mb = (total_bytes as f64) / elapsed.as_secs_f64() / 1_000_000.0;

        println!("\n📊 [ANSI 10KB × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per write: {:?}", elapsed / iterations);
        println!("   Throughput: {:.2} MB/s", throughput_mb);
    }

    // =========================================================================
    // Stage 2: State 快照获取
    // =========================================================================

    #[test]
    fn bench_state_snapshot() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 先填充一些数据
        let data = generate_ansi_data(10 * 1024);
        terminal.write(&data);

        let iterations = 10000;
        let start = Instant::now();
        for _ in 0..iterations {
            let _state = terminal.state();
        }
        let elapsed = start.elapsed();

        println!("\n📊 [State Snapshot × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per snapshot: {:?}", elapsed / iterations);
    }

    #[test]
    fn bench_state_snapshot_large_history() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 填充大量历史（模拟长时间使用）
        for _ in 0..1000 {
            terminal.write(b"This is a line of text that will go into history\r\n");
        }

        let iterations = 10000;
        let start = Instant::now();
        for _ in 0..iterations {
            let _state = terminal.state();
        }
        let elapsed = start.elapsed();

        println!("\n📊 [State Snapshot (Large History) × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per snapshot: {:?}", elapsed / iterations);
    }

    // =========================================================================
    // Stage 3: Damage 检测
    // =========================================================================

    #[test]
    fn bench_damage_check() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 填充数据
        terminal.write(b"Hello World\r\n");

        let iterations = 100000;
        let start = Instant::now();
        for _ in 0..iterations {
            let _damaged = terminal.is_damaged();
        }
        let elapsed = start.elapsed();

        println!("\n📊 [Damage Check × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per check: {:?}", elapsed / iterations);
    }

    #[test]
    fn bench_damage_reset() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        let iterations = 100000;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(b"x"); // 触发 damage
            terminal.reset_damage();
        }
        let elapsed = start.elapsed();

        println!("\n📊 [Write + Reset Damage × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per cycle: {:?}", elapsed / iterations);
    }

    // =========================================================================
    // 综合场景
    // =========================================================================

    #[test]
    fn bench_realistic_frame() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 模拟真实帧：少量写入 + state 快照 + damage 检测
        let small_write = b"$ ls -la\r\n";

        let iterations = 10000;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(small_write);
            let _damaged = terminal.is_damaged();
            let _state = terminal.state();
            terminal.reset_damage();
        }
        let elapsed = start.elapsed();

        println!("\n📊 [Realistic Frame × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per frame: {:?}", elapsed / iterations);
        println!("   Max FPS: {:.0}", iterations as f64 / elapsed.as_secs_f64());
    }

    #[test]
    fn bench_high_throughput_frame() {
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);

        // 模拟高负载帧：大量写入 + state 快照
        let large_write = generate_ansi_data(4096);

        let iterations = 1000;
        let start = Instant::now();
        for _ in 0..iterations {
            terminal.write(&large_write);
            let _damaged = terminal.is_damaged();
            let _state = terminal.state();
            terminal.reset_damage();
        }
        let elapsed = start.elapsed();

        println!("\n📊 [High Throughput Frame (4KB) × {}]", iterations);
        println!("   Total: {:?}", elapsed);
        println!("   Per frame: {:?}", elapsed / iterations);
        println!("   Max FPS: {:.0}", iterations as f64 / elapsed.as_secs_f64());
    }

    // =========================================================================
    // 单次全流程测试 - 快速定位瓶颈
    // =========================================================================

    /// 创建测试用 Renderer
    fn create_test_renderer() -> crate::render::Renderer {
        use crate::render::{Renderer, RenderConfig};
        use crate::render::font::FontContext;
        use crate::domain::primitives::LogicalPixels;
        use sugarloaf::font::FontLibrary;
        use sugarloaf::font::SugarloafFonts;
        use rio_backend::config::colors::Colors;
        use std::sync::Arc;

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = Arc::new(FontContext::new(font_library));
        let colors = Arc::new(Colors::default());
        let config = RenderConfig::new(LogicalPixels::new(14.0), 1.0, 1.0, colors);
        Renderer::new(font_context, config)
    }

    #[test]
    fn bench_single_frame_breakdown() {
        println!("\n🔬 [Single Frame Breakdown] 单次全流程耗时分析\n");

        // 1. 创建终端并填充数据
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        for i in 0..24 {
            terminal.write(format!("Line {}: Hello World with some text content here\r\n", i).as_bytes());
        }

        // 2. 创建渲染器
        let mut renderer = create_test_renderer();

        // === Stage 1: is_damaged ===
        let t1 = Instant::now();
        let damaged = terminal.is_damaged();
        let d1 = t1.elapsed();
        println!("1. is_damaged()       : {:?} (result: {})", d1, damaged);

        // === Stage 2: state() ===
        let t2 = Instant::now();
        let state = terminal.state();
        let d2 = t2.elapsed();
        println!("2. state()            : {:?}", d2);

        // === Stage 3: render_line × 24 (首次，全 miss) ===
        let t3 = Instant::now();
        let mut images = Vec::with_capacity(24);
        for line in 0..24 {
            let img = renderer.render_line(line, &state);
            images.push(img);
        }
        let d3 = t3.elapsed();
        println!("3. render_line × 24   : {:?} (首次全 miss)", d3);

        // === Stage 4: render_line × 24 (第二次，应该全 hit) ===
        let t4 = Instant::now();
        for line in 0..24 {
            let _img = renderer.render_line(line, &state);
        }
        let d4 = t4.elapsed();
        println!("4. render_line × 24   : {:?} (二次全 hit)", d4);

        // === Stage 5: reset_damage ===
        let t5 = Instant::now();
        terminal.reset_damage();
        let d5 = t5.elapsed();
        println!("5. reset_damage()     : {:?}", d5);

        // === 汇总 ===
        let total = d1 + d2 + d3 + d5;
        println!("\n📊 汇总 (首次渲染):");
        println!("   is_damaged:    {:>10?} ({:>5.1}%)", d1, d1.as_nanos() as f64 / total.as_nanos() as f64 * 100.0);
        println!("   state():       {:>10?} ({:>5.1}%)", d2, d2.as_nanos() as f64 / total.as_nanos() as f64 * 100.0);
        println!("   render × 24:   {:>10?} ({:>5.1}%)", d3, d3.as_nanos() as f64 / total.as_nanos() as f64 * 100.0);
        println!("   reset_damage:  {:>10?} ({:>5.1}%)", d5, d5.as_nanos() as f64 / total.as_nanos() as f64 * 100.0);
        println!("   ─────────────────────────────");
        println!("   Total:         {:>10?}", total);

        println!("\n📊 缓存效果:");
        println!("   首次 (miss):   {:>10?}", d3);
        println!("   二次 (hit):    {:>10?}", d4);
        println!("   加速比:        {:>10.1}x", d3.as_nanos() as f64 / d4.as_nanos() as f64);
    }

    #[test]
    fn bench_single_line_render_breakdown() {
        println!("\n🔬 [Single Line Render] 单行渲染耗时分析\n");

        // 创建终端
        let mut terminal = Terminal::new_for_test(TerminalId(1), 80, 24);
        terminal.write(b"Hello World with \x1b[31mRed\x1b[0m and \x1b[32mGreen\x1b[0m text!\r\n");

        let state = terminal.state();
        let mut renderer = create_test_renderer();

        // 单行渲染 - 首次 (miss)
        let t1 = Instant::now();
        let img1 = renderer.render_line(0, &state);
        let d1 = t1.elapsed();

        // 单行渲染 - 二次 (hit)
        let t2 = Instant::now();
        let _img2 = renderer.render_line(0, &state);
        let d2 = t2.elapsed();

        println!("Line 0 渲染:");
        println!("   首次 (miss): {:?}", d1);
        println!("   二次 (hit):  {:?}", d2);
        println!("   Image size:  {}x{}", img1.width(), img1.height());
    }

    #[test]
    fn bench_large_terminal_100x200() {
        println!("\n🔬 [Large Terminal 100×200] 大终端渲染测试\n");

        // 创建 100 列 × 200 行的大终端
        let mut terminal = Terminal::new_for_test(TerminalId(1), 100, 200);

        // 填充所有行
        for i in 0..200 {
            terminal.write(format!("Row {:03}: The quick brown fox jumps over the lazy dog 1234567890\r\n", i).as_bytes());
        }

        let mut renderer = create_test_renderer();

        println!("终端尺寸: 100 列 × 200 行 = 20000 cells\n");

        // ============================================
        // 测试 1: 全屏更新 (全 miss)
        // ============================================
        println!("=== 全屏更新 (10 次平均) ===\n");

        let mut full_state_times = Vec::new();
        let mut full_render_times = Vec::new();
        let mut full_total_times = Vec::new();

        for round in 0..10 {
            // 清除缓存，强制 miss
            renderer.clear_cache();

            // 写入触发变化
            terminal.write(format!("Update round {}\r\n", round).as_bytes());

            let total_start = Instant::now();

            // state()
            let t1 = Instant::now();
            let state = terminal.state();
            let state_time = t1.elapsed();

            // render_line × 200
            let t2 = Instant::now();
            for line in 0..200 {
                let _img = renderer.render_line(line, &state);
            }
            let render_time = t2.elapsed();

            let total_time = total_start.elapsed();

            full_state_times.push(state_time);
            full_render_times.push(render_time);
            full_total_times.push(total_time);

            terminal.reset_damage();
        }

        let avg_state: u128 = full_state_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;
        let avg_render: u128 = full_render_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;
        let avg_total: u128 = full_total_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;

        println!("全屏更新 (200 行 miss):");
        println!("   state():        {:>8}µs ({:>5.1}%)", avg_state, avg_state as f64 / avg_total as f64 * 100.0);
        println!("   render × 200:   {:>8}µs ({:>5.1}%)", avg_render, avg_render as f64 / avg_total as f64 * 100.0);
        println!("   Total:          {:>8}µs ({:.2}ms)", avg_total, avg_total as f64 / 1000.0);
        println!("   FPS 上限:       {:>8.1}", 1_000_000.0 / avg_total as f64);

        // ============================================
        // 测试 2: 单行更新 (199 hit + 1 miss)
        // ============================================
        println!("\n=== 单行更新 (10 次平均) ===\n");

        // 先预热缓存
        let warmup_state = terminal.state();
        for line in 0..200 {
            let _img = renderer.render_line(line, &warmup_state);
        }

        let mut single_state_times = Vec::new();
        let mut single_render_times = Vec::new();
        let mut single_total_times = Vec::new();

        for round in 0..10 {
            // 只修改一行
            terminal.write(format!("Single update {}\r", round).as_bytes());

            let total_start = Instant::now();

            // state()
            let t1 = Instant::now();
            let state = terminal.state();
            let state_time = t1.elapsed();

            // render_line × 200 (大部分应该 hit)
            let t2 = Instant::now();
            for line in 0..200 {
                let _img = renderer.render_line(line, &state);
            }
            let render_time = t2.elapsed();

            let total_time = total_start.elapsed();

            single_state_times.push(state_time);
            single_render_times.push(render_time);
            single_total_times.push(total_time);

            terminal.reset_damage();
        }

        let avg_state2: u128 = single_state_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;
        let avg_render2: u128 = single_render_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;
        let avg_total2: u128 = single_total_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;

        println!("单行更新 (199 hit + 1 miss):");
        println!("   state():        {:>8}µs ({:>5.1}%)", avg_state2, avg_state2 as f64 / avg_total2 as f64 * 100.0);
        println!("   render × 200:   {:>8}µs ({:>5.1}%)", avg_render2, avg_render2 as f64 / avg_total2 as f64 * 100.0);
        println!("   Total:          {:>8}µs ({:.2}ms)", avg_total2, avg_total2 as f64 / 1000.0);
        println!("   FPS 上限:       {:>8.1}", 1_000_000.0 / avg_total2 as f64);

        // ============================================
        // 对比
        // ============================================
        println!("\n=== 对比 ===\n");
        println!("全屏 vs 单行: {:.1}x 加速", avg_total as f64 / avg_total2 as f64);
    }

    #[test]
    fn bench_large_terminal_with_history() {
        println!("\n🔬 [Large Terminal + History] 大终端 + 历史数据测试\n");

        // 创建 100 列 × 50 行的终端（屏幕）
        let mut terminal = Terminal::new_for_test(TerminalId(1), 100, 50);

        // 填充 2000 行数据，产生大量 scrollback history
        for i in 0..2000 {
            terminal.write(format!("History line {:04}: The quick brown fox jumps over the lazy dog\r\n", i).as_bytes());
        }

        let mut renderer = create_test_renderer();

        // 获取 state 查看历史大小
        let check_state = terminal.state();
        let history_size = check_state.grid.history_size();
        let screen_lines = check_state.grid.lines();
        let total_lines = history_size + screen_lines;

        println!("终端配置:");
        println!("   屏幕: 100 列 × {} 行", screen_lines);
        println!("   历史: {} 行", history_size);
        println!("   总计: {} 行 (state 要遍历的)\n", total_lines);

        // ============================================
        // 测试: 单行更新 (有大量历史)
        // ============================================
        println!("=== 单行更新 + 大量历史 (10 次平均) ===\n");

        // 预热缓存
        let warmup_state = terminal.state();
        for line in 0..screen_lines {
            let _img = renderer.render_line(line, &warmup_state);
        }

        let mut state_times = Vec::new();
        let mut render_times = Vec::new();
        let mut total_times = Vec::new();

        for round in 0..10 {
            // 只修改一行
            terminal.write(format!("Update {}\r", round).as_bytes());

            let total_start = Instant::now();

            // state()
            let t1 = Instant::now();
            let state = terminal.state();
            let state_time = t1.elapsed();

            // render_line × screen_lines
            let t2 = Instant::now();
            for line in 0..screen_lines {
                let _img = renderer.render_line(line, &state);
            }
            let render_time = t2.elapsed();

            let total_time = total_start.elapsed();

            state_times.push(state_time);
            render_times.push(render_time);
            total_times.push(total_time);

            terminal.reset_damage();
        }

        let avg_state: u128 = state_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;
        let avg_render: u128 = render_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;
        let avg_total: u128 = total_times.iter().map(|d| d.as_micros()).sum::<u128>() / 10;

        println!("单行更新 (有 {} 行历史):", history_size);
        println!("   state():        {:>8}µs ({:>5.1}%)", avg_state, avg_state as f64 / avg_total as f64 * 100.0);
        println!("   render × {}:    {:>8}µs ({:>5.1}%)", screen_lines, avg_render, avg_render as f64 / avg_total as f64 * 100.0);
        println!("   Total:          {:>8}µs ({:.2}ms)", avg_total, avg_total as f64 / 1000.0);
        println!("   FPS 上限:       {:>8.1}", 1_000_000.0 / avg_total as f64);

        // 计算 state 每行耗时
        let us_per_line = avg_state as f64 / total_lines as f64;
        println!("\n📊 state() 分析:");
        println!("   遍历行数:       {}", total_lines);
        println!("   每行耗时:       {:.2}µs", us_per_line);
    }

    // =========================================================================
    // 锁竞争测试 - 模拟渲染线程和 PTY 线程的锁竞争
    // =========================================================================

    #[test]
    fn bench_lock_contention() {
        use std::sync::Arc;
        use std::thread;
        use std::sync::atomic::{AtomicU64, AtomicBool, Ordering};
        use parking_lot::RwLock;

        println!("\n🔒 [Lock Contention Test] 锁竞争测试\n");

        // 模拟 Crosswords 的 RwLock
        let crosswords: Arc<RwLock<Vec<u8>>> = Arc::new(RwLock::new(vec![0u8; 1024]));

        // 统计
        let render_read_hold_time = Arc::new(AtomicU64::new(0));
        let pty_write_wait_time = Arc::new(AtomicU64::new(0));
        let pty_write_success = Arc::new(AtomicU64::new(0));
        let pty_write_failed = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));

        // 渲染线程：模拟 state() 持有 read lock
        let render_crosswords = Arc::clone(&crosswords);
        let render_hold = Arc::clone(&render_read_hold_time);
        let render_stop = Arc::clone(&stop);

        let render_thread = thread::spawn(move || {
            let mut total_hold = 0u64;
            let mut iterations = 0;

            while !render_stop.load(Ordering::Relaxed) {
                let start = Instant::now();
                {
                    let _guard = render_crosswords.read();
                    // 模拟 state() 的 60ms 工作（debug 模式下）
                    // 实际用 busy loop 模拟，避免 sleep 不精确
                    let work_until = start + std::time::Duration::from_millis(10);
                    while Instant::now() < work_until {
                        std::hint::spin_loop();
                    }
                }
                total_hold += start.elapsed().as_micros() as u64;
                iterations += 1;

                // 短暂让出 CPU，模拟帧间隔
                thread::yield_now();
            }

            render_hold.store(total_hold / iterations.max(1), Ordering::Relaxed);
        });

        // PTY 线程：模拟高速写入
        let pty_crosswords = Arc::clone(&crosswords);
        let pty_wait = Arc::clone(&pty_write_wait_time);
        let pty_success = Arc::clone(&pty_write_success);
        let pty_failed = Arc::clone(&pty_write_failed);
        let pty_stop = Arc::clone(&stop);

        let pty_thread = thread::spawn(move || {
            let mut total_wait = 0u64;
            let mut success_count = 0u64;
            let mut fail_count = 0u64;

            while !pty_stop.load(Ordering::Relaxed) {
                let start = Instant::now();

                // 先尝试 try_write（非阻塞）
                if let Some(mut guard) = pty_crosswords.try_write() {
                    guard[0] = guard[0].wrapping_add(1);
                    success_count += 1;
                } else {
                    fail_count += 1;
                    // try_write 失败后，强制 write（阻塞）
                    let wait_start = Instant::now();
                    {
                        let mut guard = pty_crosswords.write();
                        guard[0] = guard[0].wrapping_add(1);
                    }
                    total_wait += wait_start.elapsed().as_micros() as u64;
                }

                // 模拟 PTY 数据到达间隔（1ms 约等于 1KB @ 1MB/s）
                thread::sleep(std::time::Duration::from_micros(100));
            }

            pty_wait.store(total_wait / fail_count.max(1), Ordering::Relaxed);
            pty_success.store(success_count, Ordering::Relaxed);
            pty_failed.store(fail_count, Ordering::Relaxed);
        });

        // 运行 1 秒
        thread::sleep(std::time::Duration::from_secs(1));
        stop.store(true, Ordering::Relaxed);

        render_thread.join().unwrap();
        pty_thread.join().unwrap();

        // 输出结果
        let avg_hold = render_read_hold_time.load(Ordering::Relaxed);
        let avg_wait = pty_write_wait_time.load(Ordering::Relaxed);
        let success = pty_write_success.load(Ordering::Relaxed);
        let failed = pty_write_failed.load(Ordering::Relaxed);
        let total = success + failed;

        println!("渲染线程:");
        println!("   read lock 平均持有: {}µs ({:.1}ms)", avg_hold, avg_hold as f64 / 1000.0);

        println!("\nPTY 线程:");
        println!("   try_write 成功: {} ({:.1}%)", success, success as f64 / total as f64 * 100.0);
        println!("   try_write 失败: {} ({:.1}%)", failed, failed as f64 / total as f64 * 100.0);
        println!("   write 阻塞等待: {}µs ({:.1}ms) 平均", avg_wait, avg_wait as f64 / 1000.0);

        println!("\n📊 结论:");
        if failed > 0 {
            println!("   ⚠️ 存在锁竞争！PTY 有 {:.1}% 的写入被阻塞", failed as f64 / total as f64 * 100.0);
            println!("   平均阻塞时间: {:.1}ms", avg_wait as f64 / 1000.0);
        } else {
            println!("   ✅ 无锁竞争");
        }
    }

    #[test]
    fn bench_lock_contention_realistic() {
        use std::sync::Arc;
        use std::thread;
        use std::sync::atomic::{AtomicU64, AtomicBool, Ordering};

        println!("\n🔒 [Realistic Lock Contention] 真实场景锁竞争测试\n");
        println!("模拟: 渲染线程调用 state()，PTY 线程写入数据\n");

        // 创建有历史的终端
        let terminal = Arc::new(parking_lot::Mutex::new(
            Terminal::new_for_test(TerminalId(1), 100, 50)
        ));

        // 填充历史 (2000 行，模拟真实使用)
        {
            let mut t = terminal.lock();
            for i in 0..2000 {
                t.write(format!("History line {:04}\r\n", i).as_bytes());
            }
        }

        let state_times = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let write_wait_times = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));

        // 渲染线程
        let render_terminal = Arc::clone(&terminal);
        let render_state_times = Arc::clone(&state_times);
        let render_stop = Arc::clone(&stop);

        let render_thread = thread::spawn(move || {
            while !render_stop.load(Ordering::Relaxed) {
                let start = Instant::now();
                {
                    let t = render_terminal.lock();
                    let _state = t.state();  // 这里持有 Terminal lock + Crosswords read lock
                }
                let elapsed = start.elapsed().as_micros() as u64;
                render_state_times.lock().push(elapsed);

                // 模拟 60fps 帧间隔
                thread::sleep(std::time::Duration::from_millis(16));
            }
        });

        // PTY 线程
        let pty_terminal = Arc::clone(&terminal);
        let pty_wait_times = Arc::clone(&write_wait_times);
        let pty_stop = Arc::clone(&stop);

        let pty_thread = thread::spawn(move || {
            while !pty_stop.load(Ordering::Relaxed) {
                let start = Instant::now();
                {
                    // 尝试获取锁写入数据
                    match pty_terminal.try_lock() {
                        Some(mut t) => {
                            t.write(b"x");
                        }
                        None => {
                            // 获取失败，阻塞等待
                            let wait_start = Instant::now();
                            {
                                let mut t = pty_terminal.lock();
                                t.write(b"x");
                            }
                            pty_wait_times.lock().push(wait_start.elapsed().as_micros() as u64);
                        }
                    }
                }

                // 模拟 PTY 数据到达（高速: 1KB 数据约 0.1ms）
                thread::sleep(std::time::Duration::from_micros(100));
            }
        });

        // 运行 2 秒
        thread::sleep(std::time::Duration::from_secs(2));
        stop.store(true, Ordering::Relaxed);

        render_thread.join().unwrap();
        pty_thread.join().unwrap();

        // 分析结果
        let state_times_vec = state_times.lock();
        let wait_times_vec = write_wait_times.lock();

        let avg_state = if state_times_vec.is_empty() { 0 } else {
            state_times_vec.iter().sum::<u64>() / state_times_vec.len() as u64
        };
        let max_state = state_times_vec.iter().max().copied().unwrap_or(0);

        let blocked_count = wait_times_vec.len();
        let avg_wait = if wait_times_vec.is_empty() { 0 } else {
            wait_times_vec.iter().sum::<u64>() / wait_times_vec.len() as u64
        };
        let max_wait = wait_times_vec.iter().max().copied().unwrap_or(0);

        println!("渲染线程 (state() 调用):");
        println!("   调用次数: {}", state_times_vec.len());
        println!("   平均耗时: {}µs ({:.1}ms)", avg_state, avg_state as f64 / 1000.0);
        println!("   最大耗时: {}µs ({:.1}ms)", max_state, max_state as f64 / 1000.0);

        println!("\nPTY 线程 (write 调用):");
        println!("   阻塞次数: {}", blocked_count);
        if blocked_count > 0 {
            println!("   平均等待: {}µs ({:.1}ms)", avg_wait, avg_wait as f64 / 1000.0);
            println!("   最大等待: {}µs ({:.1}ms)", max_wait, max_wait as f64 / 1000.0);
        }

        println!("\n📊 结论:");
        if blocked_count > 0 {
            println!("   ⚠️ 检测到 {} 次锁竞争阻塞", blocked_count);
            println!("   最大延迟: {:.1}ms（输入会感知卡顿）", max_wait as f64 / 1000.0);
        } else {
            println!("   ✅ 无明显锁竞争");
        }
    }
}
