//! SPSC Queue - 无锁单生产者单消费者队列
//!
//! 职责：在 PTY 线程和渲染线程之间传递 TerminalEvent
//!
//! 设计特点：
//! - 无锁：使用原子操作实现
//! - 固定容量：环形缓冲区
//! - 单生产者：PTY 线程 push
//! - 单消费者：渲染线程 pop
//!
//! 实现参考：Lamport's lock-free SPSC queue

use std::cell::UnsafeCell;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicUsize, Ordering};

/// SPSC 队列的默认容量
pub const DEFAULT_CAPACITY: usize = 8192;

/// 无锁单生产者单消费者队列
///
/// # 线程安全
/// - 只有一个线程可以调用 push（生产者）
/// - 只有一个线程可以调用 pop（消费者）
/// - 生产者和消费者可以是不同线程
pub struct SpscQueue<T> {
    /// 环形缓冲区
    buffer: Box<[UnsafeCell<MaybeUninit<T>>]>,
    /// 容量（2 的幂次方）
    capacity: usize,
    /// 容量掩码（用于取模运算）
    mask: usize,
    /// 写入位置（生产者使用）
    head: AtomicUsize,
    /// 读取位置（消费者使用）
    tail: AtomicUsize,
}

// SAFETY: SpscQueue 可以在线程间安全共享
// - head 只被生产者修改，消费者只读
// - tail 只被消费者修改，生产者只读
// - buffer 的每个槽位要么被生产者写入，要么被消费者读取，不会同时发生
unsafe impl<T: Send> Send for SpscQueue<T> {}
unsafe impl<T: Send> Sync for SpscQueue<T> {}

impl<T> SpscQueue<T> {
    /// 创建新的 SPSC 队列
    ///
    /// # 参数
    /// - `capacity`: 队列容量（会被向上取整到 2 的幂次方）
    ///
    /// # Panics
    /// - 如果 capacity 为 0
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "capacity must be greater than 0");

        // 向上取整到 2 的幂次方
        let capacity = capacity.next_power_of_two();
        let mask = capacity - 1;

        // 分配缓冲区
        let buffer: Vec<UnsafeCell<MaybeUninit<T>>> =
            (0..capacity).map(|_| UnsafeCell::new(MaybeUninit::uninit())).collect();

        Self {
            buffer: buffer.into_boxed_slice(),
            capacity,
            mask,
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
        }
    }

    /// 创建默认容量的队列
    pub fn with_default_capacity() -> Self {
        Self::new(DEFAULT_CAPACITY)
    }

    /// 获取队列容量
    #[inline]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// 检查队列是否为空
    #[inline]
    pub fn is_empty(&self) -> bool {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Acquire);
        head == tail
    }

    /// 获取队列中的元素数量
    #[inline]
    pub fn len(&self) -> usize {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Acquire);
        head.wrapping_sub(tail)
    }

    /// 检查队列是否已满
    #[inline]
    pub fn is_full(&self) -> bool {
        self.len() >= self.capacity
    }

    /// 尝试推入元素（生产者调用）
    ///
    /// # 返回
    /// - `Ok(())` - 成功推入
    /// - `Err(value)` - 队列已满，返回原值
    ///
    /// # 线程安全
    /// 只能由生产者线程调用
    pub fn push(&self, value: T) -> Result<(), T> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);

        // 检查是否已满
        if head.wrapping_sub(tail) >= self.capacity {
            return Err(value);
        }

        // 写入数据
        let index = head & self.mask;
        // SAFETY: 我们已经确认槽位可用（不会被消费者读取）
        unsafe {
            (*self.buffer[index].get()).write(value);
        }

        // 更新 head（Release 确保写入对消费者可见）
        self.head.store(head.wrapping_add(1), Ordering::Release);

        Ok(())
    }

    /// 尝试弹出元素（消费者调用）
    ///
    /// # 返回
    /// - `Some(value)` - 成功弹出
    /// - `None` - 队列为空
    ///
    /// # 线程安全
    /// 只能由消费者线程调用
    pub fn pop(&self) -> Option<T> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);

        // 检查是否为空
        if tail == head {
            return None;
        }

        // 读取数据
        let index = tail & self.mask;
        // SAFETY: 我们已经确认槽位有数据（生产者已写入）
        let value = unsafe { (*self.buffer[index].get()).assume_init_read() };

        // 更新 tail（Release 确保读取完成后更新）
        self.tail.store(tail.wrapping_add(1), Ordering::Release);

        Some(value)
    }

    /// 批量弹出元素（消费者调用）
    ///
    /// # 参数
    /// - `max_count`: 最大弹出数量
    ///
    /// # 返回
    /// 弹出的元素向量
    ///
    /// # 线程安全
    /// 只能由消费者线程调用
    pub fn pop_batch(&self, max_count: usize) -> Vec<T> {
        let mut result = Vec::with_capacity(max_count.min(64));

        for _ in 0..max_count {
            match self.pop() {
                Some(value) => result.push(value),
                None => break,
            }
        }

        result
    }

    /// 清空队列（消费者调用）
    ///
    /// # 返回
    /// 所有被清空的元素
    ///
    /// # 线程安全
    /// 只能由消费者线程调用
    pub fn drain(&self) -> Vec<T> {
        let mut result = Vec::new();
        while let Some(value) = self.pop() {
            result.push(value);
        }
        result
    }
}

impl<T> Drop for SpscQueue<T> {
    fn drop(&mut self) {
        // 清理所有未消费的元素
        while self.pop().is_some() {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn test_new_queue() {
        let queue: SpscQueue<i32> = SpscQueue::new(16);
        assert_eq!(queue.capacity(), 16);
        assert!(queue.is_empty());
        assert_eq!(queue.len(), 0);
    }

    #[test]
    fn test_capacity_round_up() {
        // 17 应该被向上取整到 32
        let queue: SpscQueue<i32> = SpscQueue::new(17);
        assert_eq!(queue.capacity(), 32);
    }

    #[test]
    fn test_push_pop_single() {
        let queue = SpscQueue::new(16);

        assert!(queue.push(42).is_ok());
        assert_eq!(queue.len(), 1);
        assert!(!queue.is_empty());

        assert_eq!(queue.pop(), Some(42));
        assert!(queue.is_empty());
        assert_eq!(queue.len(), 0);
    }

    #[test]
    fn test_push_pop_multiple() {
        let queue = SpscQueue::new(16);

        for i in 0..10 {
            assert!(queue.push(i).is_ok());
        }
        assert_eq!(queue.len(), 10);

        for i in 0..10 {
            assert_eq!(queue.pop(), Some(i));
        }
        assert!(queue.is_empty());
    }

    #[test]
    fn test_queue_full() {
        let queue = SpscQueue::new(4);

        // 填满队列
        for i in 0..4 {
            assert!(queue.push(i).is_ok());
        }

        // 再次 push 应该失败
        assert_eq!(queue.push(100), Err(100));
        assert!(queue.is_full());
    }

    #[test]
    fn test_pop_empty() {
        let queue: SpscQueue<i32> = SpscQueue::new(16);
        assert_eq!(queue.pop(), None);
    }

    #[test]
    fn test_wraparound() {
        let queue = SpscQueue::new(4);

        // 第一轮
        for i in 0..4 {
            assert!(queue.push(i).is_ok());
        }
        for i in 0..4 {
            assert_eq!(queue.pop(), Some(i));
        }

        // 第二轮（测试环形缓冲区回绕）
        for i in 10..14 {
            assert!(queue.push(i).is_ok());
        }
        for i in 10..14 {
            assert_eq!(queue.pop(), Some(i));
        }
    }

    #[test]
    fn test_pop_batch() {
        let queue = SpscQueue::new(16);

        for i in 0..10 {
            queue.push(i).unwrap();
        }

        let batch = queue.pop_batch(5);
        assert_eq!(batch, vec![0, 1, 2, 3, 4]);
        assert_eq!(queue.len(), 5);

        let batch = queue.pop_batch(10);
        assert_eq!(batch, vec![5, 6, 7, 8, 9]);
        assert!(queue.is_empty());
    }

    #[test]
    fn test_drain() {
        let queue = SpscQueue::new(16);

        for i in 0..5 {
            queue.push(i).unwrap();
        }

        let drained = queue.drain();
        assert_eq!(drained, vec![0, 1, 2, 3, 4]);
        assert!(queue.is_empty());
    }

    #[test]
    fn test_concurrent_push_pop() {
        let queue = Arc::new(SpscQueue::new(1024));
        let queue_producer = Arc::clone(&queue);
        let queue_consumer = Arc::clone(&queue);

        let count = 10000;

        // 生产者线程
        let producer = thread::spawn(move || {
            for i in 0..count {
                // 如果队列满了，等一下再试
                while queue_producer.push(i).is_err() {
                    thread::yield_now();
                }
            }
        });

        // 消费者线程
        let consumer = thread::spawn(move || {
            let mut received = Vec::with_capacity(count);
            while received.len() < count {
                if let Some(value) = queue_consumer.pop() {
                    received.push(value);
                } else {
                    thread::yield_now();
                }
            }
            received
        });

        producer.join().unwrap();
        let received = consumer.join().unwrap();

        // 验证所有数据都正确接收
        assert_eq!(received.len(), count);
        for (i, &v) in received.iter().enumerate() {
            assert_eq!(v, i, "Mismatch at index {}", i);
        }
    }

    #[test]
    fn test_with_string() {
        let queue = SpscQueue::new(16);

        queue.push(String::from("hello")).unwrap();
        queue.push(String::from("world")).unwrap();

        assert_eq!(queue.pop(), Some(String::from("hello")));
        assert_eq!(queue.pop(), Some(String::from("world")));
    }

    #[test]
    fn test_drop_cleans_up() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        static DROP_COUNT: AtomicUsize = AtomicUsize::new(0);

        #[derive(Debug)]
        struct DropCounter;
        impl Drop for DropCounter {
            fn drop(&mut self) {
                DROP_COUNT.fetch_add(1, Ordering::SeqCst);
            }
        }

        DROP_COUNT.store(0, Ordering::SeqCst);

        {
            let queue = SpscQueue::new(16);
            for _ in 0..5 {
                queue.push(DropCounter).unwrap();
            }
            // queue 被 drop，所有未消费的元素应该被 drop
        }

        assert_eq!(DROP_COUNT.load(Ordering::SeqCst), 5);
    }
}
