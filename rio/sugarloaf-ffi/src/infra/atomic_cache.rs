//! Atomic Cache - 原子缓存
//!
//! 职责：提供线程安全的无锁缓存
//!
//! 用途：
//! - 光标位置缓存（主线程读取，渲染/PTY 线程更新）
//! - 选区状态缓存
//! - 终端元数据缓存

use std::sync::atomic::{AtomicU64, Ordering};

/// 打包的光标位置
///
/// 使用 64 位原子变量存储光标位置，实现无锁读写：
/// - bits 0-15: col (u16)
/// - bits 16-31: row (u16)
/// - bits 32-47: display_offset (u16)
/// - bit 48: valid (bool)
/// - bits 49-63: reserved
#[derive(Debug)]
pub struct AtomicCursorCache {
    packed: AtomicU64,
}

impl AtomicCursorCache {
    /// 创建新的原子光标缓存
    pub fn new() -> Self {
        Self {
            packed: AtomicU64::new(0), // 初始为无效
        }
    }

    /// 打包光标位置
    #[inline]
    fn pack(col: u16, row: u16, display_offset: u16, valid: bool) -> u64 {
        let mut packed = col as u64;
        packed |= (row as u64) << 16;
        packed |= (display_offset as u64) << 32;
        if valid {
            packed |= 1u64 << 48;
        }
        packed
    }

    /// 解包光标位置
    #[inline]
    fn unpack(packed: u64) -> (u16, u16, u16, bool) {
        let col = (packed & 0xFFFF) as u16;
        let row = ((packed >> 16) & 0xFFFF) as u16;
        let display_offset = ((packed >> 32) & 0xFFFF) as u16;
        let valid = (packed >> 48) & 1 != 0;
        (col, row, display_offset, valid)
    }

    /// 更新光标位置（生产者调用：PTY 线程或渲染线程）
    ///
    /// # 参数
    /// - col: 光标列（屏幕坐标）
    /// - row: 光标行（屏幕坐标，相对于当前 display_offset）
    /// - display_offset: 当前显示偏移
    #[inline]
    pub fn update(&self, col: u16, row: u16, display_offset: u16) {
        let packed = Self::pack(col, row, display_offset, true);
        self.packed.store(packed, Ordering::Release);
    }

    /// 读取光标位置（消费者调用：主线程）
    ///
    /// # 返回
    /// - `Some((col, row, display_offset))` - 有效的光标位置
    /// - `None` - 缓存无效
    #[inline]
    pub fn read(&self) -> Option<(u16, u16, u16)> {
        let packed = self.packed.load(Ordering::Acquire);
        let (col, row, display_offset, valid) = Self::unpack(packed);
        if valid {
            Some((col, row, display_offset))
        } else {
            None
        }
    }

    /// 标记缓存无效
    #[inline]
    pub fn invalidate(&self) {
        self.packed.store(0, Ordering::Release);
    }

    /// 检查缓存是否有效
    #[inline]
    pub fn is_valid(&self) -> bool {
        let packed = self.packed.load(Ordering::Acquire);
        (packed >> 48) & 1 != 0
    }
}

impl Default for AtomicCursorCache {
    fn default() -> Self {
        Self::new()
    }
}

/// 打包的终端脏标记
///
/// 使用原子 bool 标记终端是否需要渲染
#[derive(Debug)]
pub struct AtomicDirtyFlag {
    dirty: std::sync::atomic::AtomicBool,
}

impl AtomicDirtyFlag {
    /// 创建新的脏标记（初始为脏）
    pub fn new() -> Self {
        Self {
            dirty: std::sync::atomic::AtomicBool::new(true),
        }
    }

    /// 标记为脏
    #[inline]
    pub fn mark_dirty(&self) {
        self.dirty.store(true, Ordering::Release);
    }

    /// 检查并清除脏标记
    ///
    /// 返回之前的脏状态
    #[inline]
    pub fn check_and_clear(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    /// 检查是否脏（不清除）
    #[inline]
    pub fn is_dirty(&self) -> bool {
        self.dirty.load(Ordering::Acquire)
    }
}

impl Default for AtomicDirtyFlag {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn test_atomic_cursor_cache_basic() {
        let cache = AtomicCursorCache::new();

        // 初始状态无效
        assert!(!cache.is_valid());
        assert!(cache.read().is_none());

        // 更新
        cache.update(10, 5, 100);

        // 读取
        assert!(cache.is_valid());
        let (col, row, offset) = cache.read().unwrap();
        assert_eq!(col, 10);
        assert_eq!(row, 5);
        assert_eq!(offset, 100);

        // 失效
        cache.invalidate();
        assert!(!cache.is_valid());
        assert!(cache.read().is_none());
    }

    #[test]
    fn test_atomic_cursor_cache_max_values() {
        let cache = AtomicCursorCache::new();

        // 测试最大值
        cache.update(u16::MAX, u16::MAX, u16::MAX);

        let (col, row, offset) = cache.read().unwrap();
        assert_eq!(col, u16::MAX);
        assert_eq!(row, u16::MAX);
        assert_eq!(offset, u16::MAX);
    }

    #[test]
    fn test_atomic_cursor_cache_concurrent() {
        let cache = Arc::new(AtomicCursorCache::new());
        let cache_writer = Arc::clone(&cache);
        let cache_reader = Arc::clone(&cache);

        let iterations = 10000;

        // 写线程
        let writer = thread::spawn(move || {
            for i in 0..iterations {
                let col = (i % 256) as u16;
                let row = (i % 128) as u16;
                cache_writer.update(col, row, 0);
            }
        });

        // 读线程
        let reader = thread::spawn(move || {
            let mut valid_reads = 0;
            for _ in 0..iterations {
                if cache_reader.read().is_some() {
                    valid_reads += 1;
                }
            }
            valid_reads
        });

        writer.join().unwrap();
        let valid_reads = reader.join().unwrap();

        // 至少应该有一些有效读取
        assert!(valid_reads > 0);
    }

    #[test]
    fn test_atomic_dirty_flag_basic() {
        let flag = AtomicDirtyFlag::new();

        // 初始状态为脏
        assert!(flag.is_dirty());

        // 检查并清除
        assert!(flag.check_and_clear());
        assert!(!flag.is_dirty());

        // 再次检查
        assert!(!flag.check_and_clear());

        // 标记为脏
        flag.mark_dirty();
        assert!(flag.is_dirty());
    }

    #[test]
    fn test_atomic_dirty_flag_concurrent() {
        let flag = Arc::new(AtomicDirtyFlag::new());
        let flag_writer = Arc::clone(&flag);
        let flag_reader = Arc::clone(&flag);

        let iterations = 10000;

        // 写线程
        let writer = thread::spawn(move || {
            for _ in 0..iterations {
                flag_writer.mark_dirty();
            }
        });

        // 读线程
        let reader = thread::spawn(move || {
            let mut dirty_count = 0;
            for _ in 0..iterations {
                if flag_reader.check_and_clear() {
                    dirty_count += 1;
                }
            }
            dirty_count
        });

        writer.join().unwrap();
        let dirty_count = reader.join().unwrap();

        // 应该有一些脏检测
        assert!(dirty_count > 0);
    }
}
