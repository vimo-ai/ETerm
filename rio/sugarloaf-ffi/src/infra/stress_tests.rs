//! Stress Tests - 压力测试
//!
//! 职责：验证无锁架构在高负载下的稳定性
//!
//! 测试场景：
//! - 并发写读：多线程同时操作，验证不死锁、不崩溃
//! - 高吞吐量：大量事件快速推入，验证队列不溢出
//! - 长时间运行：持续运行，验证内存稳定

#[cfg(test)]
mod tests {
    use crate::infra::spsc_queue::SpscQueue;
    use crate::infra::atomic_cache::{AtomicCursorCache, AtomicDirtyFlag};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::thread;
    use std::time::{Duration, Instant};

    // ===== SPSC Queue 压力测试 =====

    /// 并发写读测试：单生产者单消费者同时操作
    #[test]
    fn stress_spsc_concurrent_read_write() {
        let queue: Arc<SpscQueue<u64>> = Arc::new(SpscQueue::new(4096));
        let queue_producer = Arc::clone(&queue);
        let queue_consumer = Arc::clone(&queue);

        let items_to_produce = 100_000;
        let produced = Arc::new(AtomicUsize::new(0));
        let consumed = Arc::new(AtomicUsize::new(0));
        let produced_clone = Arc::clone(&produced);
        let consumed_clone = Arc::clone(&consumed);

        let stop = Arc::new(AtomicBool::new(false));
        let stop_producer = Arc::clone(&stop);
        let stop_consumer = Arc::clone(&stop);

        // 生产者线程
        let producer = thread::spawn(move || {
            for i in 0..items_to_produce {
                // 自旋等待队列有空间
                while queue_producer.push(i as u64).is_err() {
                    if stop_producer.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::yield_now();
                }
                produced_clone.fetch_add(1, Ordering::Relaxed);
            }
        });

        // 消费者线程
        let consumer = thread::spawn(move || {
            let mut last_value: Option<u64> = None;
            loop {
                if let Some(value) = queue_consumer.pop() {
                    // 验证顺序（SPSC 保证顺序）
                    if let Some(last) = last_value {
                        assert_eq!(value, last + 1, "顺序错误: expected {}, got {}", last + 1, value);
                    }
                    last_value = Some(value);
                    consumed_clone.fetch_add(1, Ordering::Relaxed);

                    if value == (items_to_produce - 1) as u64 {
                        break;
                    }
                } else if stop_consumer.load(Ordering::Relaxed) {
                    break;
                } else {
                    thread::yield_now();
                }
            }
        });

        // 等待完成（最多 30 秒）
        let timeout = Duration::from_secs(30);
        let start = Instant::now();

        producer.join().expect("生产者线程 panic");

        // 给消费者额外时间
        while consumed.load(Ordering::Relaxed) < items_to_produce {
            if start.elapsed() > timeout {
                stop.store(true, Ordering::Relaxed);
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }

        consumer.join().expect("消费者线程 panic");

        // 验证结果
        assert_eq!(produced.load(Ordering::Relaxed), items_to_produce);
        assert_eq!(consumed.load(Ordering::Relaxed), items_to_produce);
    }

    /// 高吞吐量测试：快速推入大量事件
    #[test]
    fn stress_spsc_high_throughput() {
        let queue: Arc<SpscQueue<u64>> = Arc::new(SpscQueue::new(16384));
        let queue_producer = Arc::clone(&queue);
        let queue_consumer = Arc::clone(&queue);

        let items = 1_000_000;
        let consumed = Arc::new(AtomicUsize::new(0));
        let consumed_clone = Arc::clone(&consumed);

        // 消费者线程（批量消费）
        let consumer = thread::spawn(move || {
            let mut total = 0usize;

            loop {
                let batch = queue_consumer.pop_batch(1024);
                let count = batch.len();
                total += count;
                consumed_clone.store(total, Ordering::Relaxed);

                if total >= items {
                    break;
                }

                if count == 0 {
                    thread::yield_now();
                }
            }
            total
        });

        // 生产者：尽可能快地推入
        let start = Instant::now();
        let mut pushed = 0usize;

        while pushed < items {
            if queue_producer.push(pushed as u64).is_ok() {
                pushed += 1;
            } else {
                // 队列满，等待一下
                thread::yield_now();
            }
        }

        let produce_time = start.elapsed();

        // 等待消费完成
        let total_consumed = consumer.join().expect("消费者线程 panic");

        let total_time = start.elapsed();

        // 验证
        assert_eq!(total_consumed, items);

        // 输出性能数据
        let throughput = items as f64 / total_time.as_secs_f64();
        println!(
            "高吞吐量测试: {} 项, 生产耗时 {:?}, 总耗时 {:?}, 吞吐量 {:.0} items/sec",
            items, produce_time, total_time, throughput
        );

        // 基本性能断言（至少 100k/s）
        assert!(throughput > 100_000.0, "吞吐量过低: {:.0} items/sec", throughput);
    }

    /// 队列满时的行为测试
    #[test]
    fn stress_spsc_queue_full_behavior() {
        let queue: SpscQueue<u32> = SpscQueue::new(64);

        // 填满队列
        let mut pushed = 0;
        for i in 0..1000 {
            if queue.push(i).is_ok() {
                pushed += 1;
            }
        }

        // 队列容量是 64（向上取整到 2 的幂）
        assert!(pushed >= 64, "至少应该推入 64 项");
        assert!(pushed <= 128, "不应该推入超过 128 项");

        // 继续尝试 push 应该失败
        assert!(queue.push(9999).is_err(), "队列满时 push 应该返回 Err");

        // 消费一项
        let _ = queue.pop();

        // 现在应该能 push 一项
        assert!(queue.push(9999).is_ok(), "消费后应该能 push");
    }

    // ===== Atomic Cache 压力测试 =====

    /// 并发读写 AtomicCursorCache
    #[test]
    fn stress_atomic_cursor_cache_concurrent() {
        let cache = Arc::new(AtomicCursorCache::new());
        let cache_writer = Arc::clone(&cache);
        let cache_reader = Arc::clone(&cache);

        let iterations = 1_000_000;
        let stop = Arc::new(AtomicBool::new(false));
        let stop_writer = Arc::clone(&stop);
        let stop_reader = Arc::clone(&stop);

        let valid_reads = Arc::new(AtomicUsize::new(0));
        let valid_reads_clone = Arc::clone(&valid_reads);

        // 写线程
        let writer = thread::spawn(move || {
            for i in 0..iterations {
                if stop_writer.load(Ordering::Relaxed) {
                    break;
                }
                let col = (i % 256) as u16;
                let row = (i % 128) as u16;
                let offset = (i % 1000) as u16;
                cache_writer.update(col, row, offset);
            }
        });

        // 读线程
        let reader = thread::spawn(move || {
            let mut reads = 0usize;
            for _ in 0..iterations {
                if stop_reader.load(Ordering::Relaxed) {
                    break;
                }
                if let Some((col, row, offset)) = cache_reader.read() {
                    // 验证数据一致性
                    assert!(col < 256, "col 超出范围");
                    assert!(row < 128, "row 超出范围");
                    assert!(offset < 1000, "offset 超出范围");
                    reads += 1;
                }
            }
            valid_reads_clone.store(reads, Ordering::Relaxed);
        });

        writer.join().expect("写线程 panic");
        stop.store(true, Ordering::Relaxed);
        reader.join().expect("读线程 panic");

        let reads = valid_reads.load(Ordering::Relaxed);
        println!("AtomicCursorCache 并发测试: {} 有效读取", reads);
        assert!(reads > 0, "应该有一些有效读取");
    }

    /// 并发读写 AtomicDirtyFlag
    #[test]
    fn stress_atomic_dirty_flag_concurrent() {
        let flag = Arc::new(AtomicDirtyFlag::new());
        let flag_writer = Arc::clone(&flag);
        let flag_reader = Arc::clone(&flag);

        let iterations = 1_000_000;

        let dirty_count = Arc::new(AtomicUsize::new(0));
        let dirty_count_clone = Arc::clone(&dirty_count);

        // 写线程：持续标记为脏
        let writer = thread::spawn(move || {
            for _ in 0..iterations {
                flag_writer.mark_dirty();
            }
        });

        // 读线程：持续检查并清除
        let reader = thread::spawn(move || {
            let mut count = 0usize;
            for _ in 0..iterations {
                if flag_reader.check_and_clear() {
                    count += 1;
                }
            }
            dirty_count_clone.store(count, Ordering::Relaxed);
        });

        writer.join().expect("写线程 panic");
        reader.join().expect("读线程 panic");

        let count = dirty_count.load(Ordering::Relaxed);
        println!("AtomicDirtyFlag 并发测试: {} 次脏检测", count);
        // 由于并发，脏检测次数不确定，但应该大于 0
        assert!(count > 0, "应该有一些脏检测");
    }

    // ===== 长时间运行测试 =====

    /// 长时间运行测试：验证内存不泄漏
    #[test]
    fn stress_long_running_memory_stability() {
        let queue: Arc<SpscQueue<Vec<u8>>> = Arc::new(SpscQueue::new(1024));
        let queue_producer = Arc::clone(&queue);
        let queue_consumer = Arc::clone(&queue);

        let duration = Duration::from_secs(5); // 5 秒测试
        let stop = Arc::new(AtomicBool::new(false));
        let stop_producer = Arc::clone(&stop);
        let stop_consumer = Arc::clone(&stop);

        let produced = Arc::new(AtomicUsize::new(0));
        let consumed = Arc::new(AtomicUsize::new(0));
        let produced_clone = Arc::clone(&produced);
        let consumed_clone = Arc::clone(&consumed);

        // 生产者：持续产生带数据的事件
        let producer = thread::spawn(move || {
            let mut i = 0usize;
            while !stop_producer.load(Ordering::Relaxed) {
                // 创建一些数据来测试内存分配/释放
                let data = vec![0u8; 1024]; // 1KB 数据
                if queue_producer.push(data).is_ok() {
                    produced_clone.fetch_add(1, Ordering::Relaxed);
                    i += 1;
                } else {
                    thread::yield_now();
                }
            }
            i
        });

        // 消费者：持续消费
        let consumer = thread::spawn(move || {
            let mut i = 0usize;
            while !stop_consumer.load(Ordering::Relaxed) {
                if let Some(_data) = queue_consumer.pop() {
                    consumed_clone.fetch_add(1, Ordering::Relaxed);
                    i += 1;
                } else {
                    thread::yield_now();
                }
            }
            // 清空剩余
            while let Some(_) = queue_consumer.pop() {
                consumed_clone.fetch_add(1, Ordering::Relaxed);
                i += 1;
            }
            i
        });

        // 运行指定时间
        thread::sleep(duration);
        stop.store(true, Ordering::Relaxed);

        let _produced_total = producer.join().expect("生产者线程 panic");
        let _consumed_total = consumer.join().expect("消费者线程 panic");

        let produced_count = produced.load(Ordering::Relaxed);
        let consumed_count = consumed.load(Ordering::Relaxed);

        println!(
            "长时间运行测试 ({:?}): 生产 {} 项, 消费 {} 项",
            duration, produced_count, consumed_count
        );

        // 验证生产和消费基本匹配（允许队列中有少量剩余）
        assert!(
            consumed_count >= produced_count - 1024,
            "消费数量与生产数量差距过大"
        );

        // 基本吞吐量检查
        let throughput = produced_count as f64 / duration.as_secs_f64();
        println!("吞吐量: {:.0} items/sec", throughput);
    }

    /// 多轮 push/pop 测试：验证队列状态正确复位
    #[test]
    fn stress_spsc_multiple_rounds() {
        let queue: SpscQueue<u32> = SpscQueue::new(256);

        for round in 0..100 {
            // 填充队列
            for i in 0..200 {
                while queue.push(i).is_err() {
                    thread::yield_now();
                }
            }

            // 清空队列
            let mut count = 0;
            while let Some(_) = queue.pop() {
                count += 1;
            }

            assert_eq!(count, 200, "第 {} 轮: 期望 200 项, 实际 {} 项", round, count);
        }
    }

    // ===== 边界条件测试 =====

    /// 空队列并发 pop（注意：这违反 SPSC 约定，仅测试不崩溃）
    #[test]
    fn stress_empty_queue_rapid_pop() {
        let queue: Arc<SpscQueue<u32>> = Arc::new(SpscQueue::new(64));
        let q = Arc::clone(&queue);

        // 单消费者快速 pop 空队列
        let handle = thread::spawn(move || {
            let mut pops = 0;
            for _ in 0..100000 {
                if q.pop().is_some() {
                    pops += 1;
                }
            }
            pops
        });

        let total_pops = handle.join().expect("线程 panic");

        // 队列是空的，不应该有任何成功的 pop
        assert_eq!(total_pops, 0, "空队列不应该有成功的 pop");
    }

    /// drain 方法压力测试
    #[test]
    fn stress_spsc_drain() {
        let queue: SpscQueue<u32> = SpscQueue::new(1024);

        for round in 0..50 {
            // 随机数量推入
            let count = (round * 17 + 7) % 500 + 100;
            for i in 0..count {
                while queue.push(i).is_err() {
                    thread::yield_now();
                }
            }

            // 使用 drain 清空
            let drained = queue.drain();
            assert_eq!(
                drained.len(),
                count as usize,
                "第 {} 轮 drain 数量不匹配",
                round
            );

            // 验证顺序
            for (i, &val) in drained.iter().enumerate() {
                assert_eq!(val, i as u32, "第 {} 轮顺序错误", round);
            }

            // 确认队列为空
            assert!(queue.pop().is_none(), "drain 后队列应为空");
        }
    }

    /// 极端情况：快速 invalidate/update
    #[test]
    fn stress_atomic_cursor_rapid_invalidate() {
        let cache = Arc::new(AtomicCursorCache::new());
        let cache1 = Arc::clone(&cache);
        let cache2 = Arc::clone(&cache);

        let iterations = 500_000;

        // 线程 1：update
        let t1 = thread::spawn(move || {
            for i in 0..iterations {
                cache1.update((i % 100) as u16, (i % 50) as u16, 0);
            }
        });

        // 线程 2：invalidate
        let t2 = thread::spawn(move || {
            for _ in 0..iterations {
                cache2.invalidate();
            }
        });

        t1.join().expect("线程 1 panic");
        t2.join().expect("线程 2 panic");

        // 测试完成即成功（没有崩溃或死锁）
        println!("快速 invalidate/update 测试完成");
    }

    // ===== 综合压力测试 =====

    /// 模拟实际场景：PTY 写入 + 渲染线程读取 + 主线程读取光标
    #[test]
    fn stress_simulated_terminal_workflow() {
        let queue: Arc<SpscQueue<u64>> = Arc::new(SpscQueue::new(8192));
        let cursor_cache = Arc::new(AtomicCursorCache::new());
        let dirty_flag = Arc::new(AtomicDirtyFlag::new());

        let queue_producer = Arc::clone(&queue);
        let queue_consumer = Arc::clone(&queue);
        let cursor_writer = Arc::clone(&cursor_cache);
        let cursor_reader = Arc::clone(&cursor_cache);
        let dirty_writer = Arc::clone(&dirty_flag);
        let dirty_reader = Arc::clone(&dirty_flag);

        let duration = Duration::from_secs(3);
        let stop = Arc::new(AtomicBool::new(false));
        let stop1 = Arc::clone(&stop);
        let stop2 = Arc::clone(&stop);
        let stop3 = Arc::clone(&stop);

        let events_produced = Arc::new(AtomicUsize::new(0));
        let events_consumed = Arc::new(AtomicUsize::new(0));
        let cursor_reads = Arc::new(AtomicUsize::new(0));
        let events_produced_clone = Arc::clone(&events_produced);
        let events_consumed_clone = Arc::clone(&events_consumed);
        let cursor_reads_clone = Arc::clone(&cursor_reads);

        // 模拟 PTY 线程：产生事件
        let pty_thread = thread::spawn(move || {
            let mut col = 0u16;
            let mut row = 0u16;
            while !stop1.load(Ordering::Relaxed) {
                // 模拟产生事件
                let event = ((row as u64) << 16) | (col as u64);
                if queue_producer.push(event).is_ok() {
                    events_produced_clone.fetch_add(1, Ordering::Relaxed);
                    dirty_writer.mark_dirty();

                    // 更新模拟光标位置
                    col = (col + 1) % 80;
                    if col == 0 {
                        row = (row + 1) % 24;
                    }
                }
            }
        });

        // 模拟渲染线程：消费事件，更新光标缓存
        let render_thread = thread::spawn(move || {
            while !stop2.load(Ordering::Relaxed) {
                if dirty_reader.check_and_clear() {
                    // 消费所有事件
                    let events = queue_consumer.drain();
                    let count = events.len();
                    events_consumed_clone.fetch_add(count, Ordering::Relaxed);

                    // 更新光标缓存（使用最后一个事件的位置）
                    if let Some(&last_event) = events.last() {
                        let col = (last_event & 0xFFFF) as u16;
                        let row = ((last_event >> 16) & 0xFFFF) as u16;
                        cursor_writer.update(col, row, 0);
                    }
                }
                thread::yield_now();
            }
        });

        // 模拟主线程：读取光标位置
        let main_thread = thread::spawn(move || {
            while !stop3.load(Ordering::Relaxed) {
                if let Some((col, row, _offset)) = cursor_reader.read() {
                    // 验证光标位置在有效范围内
                    assert!(col < 80, "col 超出范围: {}", col);
                    assert!(row < 24, "row 超出范围: {}", row);
                    cursor_reads_clone.fetch_add(1, Ordering::Relaxed);
                }
                // 模拟主线程不是一直读取
                thread::sleep(Duration::from_micros(100));
            }
        });

        // 运行测试
        thread::sleep(duration);
        stop.store(true, Ordering::Relaxed);

        pty_thread.join().expect("PTY 线程 panic");
        render_thread.join().expect("渲染线程 panic");
        main_thread.join().expect("主线程 panic");

        let produced = events_produced.load(Ordering::Relaxed);
        let consumed = events_consumed.load(Ordering::Relaxed);
        let reads = cursor_reads.load(Ordering::Relaxed);

        println!(
            "模拟终端工作流测试 ({:?}): 事件产生 {}, 事件消费 {}, 光标读取 {}",
            duration, produced, consumed, reads
        );

        // 验证
        assert!(produced > 0, "应该产生一些事件");
        assert!(consumed > 0, "应该消费一些事件");
        assert!(reads > 0, "应该读取一些光标位置");
        // 由于停止有延迟，消费可能略少于产生
        assert!(
            consumed >= produced - 8192,
            "消费与产生差距过大: {} vs {}",
            consumed,
            produced
        );
    }
}
