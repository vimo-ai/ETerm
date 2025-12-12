//! FairRwLock - 带 lease 机制的公平读写锁
//!
//! 基于 Rio 的 FairMutex 思想，但支持读写锁语义：
//! - PTY 线程通过 lease() 预约写入优先权
//! - 渲染线程通过 read() 获取读锁，但需要等待 lease 释放
//! - 确保 PTY 批量处理期间不会被渲染线程"插队"
//!
//! 设计原则：
//! - PTY 线程持有 lease 期间，渲染线程无法获取读锁
//! - PTY 线程使用 try_write_unfair() 直接获取写锁（不需要等待 lease）
//! - 这样 PTY 可以在一个 lease 期间多次获取/释放写锁

use parking_lot::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// 带 lease 机制的公平读写锁
///
/// # 使用模式
///
/// ```ignore
/// // PTY 线程（写入者）
/// let _lease = lock.lease();  // 获取 lease，阻止新的读者
/// loop {
///     let guard = lock.try_write_unfair();  // 尝试获取写锁
///     // 处理数据...
/// }
/// drop(_lease);  // 释放 lease，允许读者获取锁
///
/// // 渲染线程（读取者）
/// let guard = lock.read();  // 需要先等待 lease 释放
/// // 渲染...
/// ```
pub struct FairRwLock<T> {
    /// 实际数据的读写锁
    data: RwLock<T>,
    /// 预约锁（lease）- 写者优先机制
    next: Mutex<()>,
}

impl<T> FairRwLock<T> {
    /// 创建新的 FairRwLock
    pub fn new(data: T) -> Self {
        Self {
            data: RwLock::new(data),
            next: Mutex::new(()),
        }
    }

    /// 获取 lease（写入预约）
    ///
    /// 持有 lease 期间，新的 read() 调用会被阻塞。
    /// 但已经持有读锁的线程不受影响。
    ///
    /// # 使用场景
    /// PTY 线程在开始批量处理前获取 lease，
    /// 确保整个批量处理期间不会被渲染线程插队。
    #[inline]
    pub fn lease(&self) -> MutexGuard<'_, ()> {
        self.next.lock()
    }

    /// 尝试获取 lease（非阻塞）
    #[inline]
    pub fn try_lease(&self) -> Option<MutexGuard<'_, ()>> {
        self.next.try_lock()
    }

    /// 公平地获取读锁
    ///
    /// 需要先获取 next 锁，确保等待任何持有 lease 的写者完成。
    /// 这是渲染线程应该使用的方法。
    #[inline]
    pub fn read(&self) -> RwLockReadGuard<'_, T> {
        // 先获取 next 锁，等待任何 lease 持有者
        let _next = self.next.lock();
        // 然后获取读锁
        self.data.read()
    }

    /// 尝试公平地获取读锁（非阻塞）
    ///
    /// 如果有 lease 持有者，立即返回 None。
    #[inline]
    pub fn try_read(&self) -> Option<RwLockReadGuard<'_, T>> {
        // 尝试获取 next 锁
        let _next = self.next.try_lock()?;
        // 尝试获取读锁
        self.data.try_read()
    }

    /// 公平地获取写锁
    ///
    /// 需要先获取 next 锁。一般不直接使用，
    /// PTY 线程应该使用 lease() + write_unfair() 组合。
    #[inline]
    pub fn write(&self) -> RwLockWriteGuard<'_, T> {
        let _next = self.next.lock();
        self.data.write()
    }

    /// 不公平地获取写锁（直接获取，不等待 next）
    ///
    /// PTY 线程在持有 lease 期间使用此方法获取写锁。
    /// 因为已经持有 lease，不需要再等待 next。
    #[inline]
    pub fn write_unfair(&self) -> RwLockWriteGuard<'_, T> {
        self.data.write()
    }

    /// 尝试不公平地获取写锁（非阻塞）
    ///
    /// PTY 线程在持有 lease 期间使用此方法尝试获取写锁。
    #[inline]
    pub fn try_write_unfair(&self) -> Option<RwLockWriteGuard<'_, T>> {
        self.data.try_write()
    }

    /// 获取内部数据的可变引用（需要 &mut self）
    #[inline]
    pub fn get_mut(&mut self) -> &mut T {
        self.data.get_mut()
    }

    /// 消费 FairRwLock，返回内部数据
    #[inline]
    pub fn into_inner(self) -> T {
        self.data.into_inner()
    }
}

// Safety: FairRwLock 的线程安全性继承自 parking_lot 的 Mutex 和 RwLock
unsafe impl<T: Send> Send for FairRwLock<T> {}
unsafe impl<T: Send + Sync> Sync for FairRwLock<T> {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    /// 测试基本的 lease 机制
    #[test]
    fn test_lease_blocks_readers() {
        let lock = Arc::new(FairRwLock::new(0u32));
        let reader_acquired = Arc::new(AtomicBool::new(false));
        let reader_acquired_clone = reader_acquired.clone();
        let reader_acquired_final = reader_acquired.clone();

        // 写者线程获取 lease
        let lock_writer = lock.clone();

        let writer = thread::spawn(move || {
            let _lease = lock_writer.lease();

            // 等待读者尝试获取锁
            thread::sleep(Duration::from_millis(50));

            // 此时读者应该被阻塞
            assert!(!reader_acquired_clone.load(Ordering::SeqCst),
                    "读者不应该在 lease 持有期间获取到锁");

            // 释放 lease
        });

        // 读者线程尝试获取读锁
        let lock_reader = lock.clone();
        let reader = thread::spawn(move || {
            thread::sleep(Duration::from_millis(10)); // 确保写者先获取 lease

            let _guard = lock_reader.read(); // 这里应该被阻塞
            reader_acquired.store(true, Ordering::SeqCst);
        });

        writer.join().unwrap();
        reader.join().unwrap();

        assert!(reader_acquired_final.load(Ordering::SeqCst), "读者最终应该获取到锁");
    }

    /// 测试 lease 期间多次写入
    #[test]
    fn test_multiple_writes_during_lease() {
        let lock = Arc::new(FairRwLock::new(0u32));

        let _lease = lock.lease();

        // 在 lease 期间多次获取/释放写锁
        for i in 0..10 {
            let mut guard = lock.write_unfair();
            *guard = i;
            drop(guard);
        }

        // 最终值应该是 9
        let guard = lock.try_write_unfair().unwrap();
        assert_eq!(*guard, 9);
    }

    /// 性能对比测试：有无 lease 的吞吐量差异
    #[test]
    fn test_performance_comparison() {
        const ITERATIONS: usize = 1000;
        const BATCH_SIZE: usize = 10;

        // 测试 FairRwLock
        let fair_lock = Arc::new(FairRwLock::new(0usize));
        let fair_read_count = Arc::new(AtomicUsize::new(0));
        let fair_partial_count = Arc::new(AtomicUsize::new(0));

        let running = Arc::new(AtomicBool::new(true));

        // 读者线程
        let fair_lock_reader = fair_lock.clone();
        let running_reader = running.clone();
        let fair_read_count_clone = fair_read_count.clone();
        let fair_partial_clone = fair_partial_count.clone();

        let reader = thread::spawn(move || {
            while running_reader.load(Ordering::Relaxed) {
                let guard = fair_lock_reader.read();
                fair_read_count_clone.fetch_add(1, Ordering::Relaxed);

                // 检查是否是中间状态（不是 BATCH_SIZE 的倍数）
                let value = *guard;
                if value % BATCH_SIZE != 0 && value > 0 {
                    fair_partial_clone.fetch_add(1, Ordering::Relaxed);
                }
                drop(guard);
                thread::yield_now();
            }
        });

        // 写者线程
        let fair_lock_writer = fair_lock.clone();
        let writer = thread::spawn(move || {
            for batch in 0..ITERATIONS {
                // 获取 lease 开始批量处理
                let _lease = fair_lock_writer.lease();

                for i in 0..BATCH_SIZE {
                    let mut guard = fair_lock_writer.write_unfair();
                    *guard = batch * BATCH_SIZE + i + 1;
                    drop(guard);
                    thread::yield_now();
                }

                // 释放 lease
            }
        });

        writer.join().unwrap();
        running.store(false, Ordering::Relaxed);
        reader.join().unwrap();

        let read_count = fair_read_count.load(Ordering::Relaxed);
        let partial_count = fair_partial_count.load(Ordering::Relaxed);

        println!("\n========================================");
        println!("FairRwLock 性能测试");
        println!("========================================");
        println!("写入批次: {}", ITERATIONS);
        println!("每批写入次数: {}", BATCH_SIZE);
        println!("读取次数: {}", read_count);
        println!("中间状态读取: {}", partial_count);
        println!("中间状态比例: {:.2}%",
                 partial_count as f64 / read_count.max(1) as f64 * 100.0);

        // 关键断言：有 lease 时不应该有中间状态
        assert_eq!(partial_count, 0,
                   "FairRwLock 不应该读取到中间状态");
    }

    /// 测试 try_read 在有 lease 时返回 None
    #[test]
    fn test_try_read_with_lease() {
        let lock = Arc::new(FairRwLock::new(0u32));

        let _lease = lock.lease();

        // try_read 应该立即返回 None
        assert!(lock.try_read().is_none(),
                "有 lease 时 try_read 应该返回 None");
    }
}
