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

// ============================================================================
// P1.1: AtomicSelectionCache - 选区缓存
// ============================================================================

/// 选区缓存
///
/// 使用两个 AtomicU64 存储选区范围，实现无锁读写：
/// - start: (start_row << 32) | start_col
/// - end: (end_row << 32) | end_col | (valid << 63)
///
/// 内存布局：
/// - bits 0-31: col (u32)
/// - bits 32-62: row (i31，支持负数行号)
/// - bit 63 (仅 end): valid 标记
#[derive(Debug)]
pub struct AtomicSelectionCache {
    /// 选区起点：(row << 32) | col
    start: AtomicU64,
    /// 选区终点：(row << 32) | col | (valid << 63)
    end: AtomicU64,
}

impl AtomicSelectionCache {
    /// 创建新的选区缓存（初始无效）
    pub fn new() -> Self {
        Self {
            start: AtomicU64::new(0),
            end: AtomicU64::new(0), // valid bit = 0
        }
    }

    /// 打包坐标
    #[inline]
    fn pack_coord(row: i32, col: u32) -> u64 {
        // row 使用低 31 位（带符号），col 使用高 32 位
        let row_bits = (row as u32) as u64; // 保留符号位
        let col_bits = (col as u64) << 32;
        row_bits | col_bits
    }

    /// 解包坐标
    #[inline]
    fn unpack_coord(packed: u64) -> (i32, u32) {
        let row = (packed & 0xFFFFFFFF) as i32;
        let col = ((packed >> 32) & 0x7FFFFFFF) as u32; // 去掉 valid bit
        (row, col)
    }

    /// 更新选区（生产者调用：渲染线程）
    ///
    /// # 参数
    /// - start_row, start_col: 选区起点
    /// - end_row, end_col: 选区终点
    #[inline]
    pub fn update(&self, start_row: i32, start_col: u32, end_row: i32, end_col: u32) {
        let start_packed = Self::pack_coord(start_row, start_col);
        let end_packed = Self::pack_coord(end_row, end_col) | (1u64 << 63); // 设置 valid bit

        self.start.store(start_packed, Ordering::Release);
        self.end.store(end_packed, Ordering::Release);
    }

    /// 读取选区（消费者调用：主线程）
    ///
    /// # 返回
    /// - `Some((start_row, start_col, end_row, end_col))` - 有效选区
    /// - `None` - 无选区
    #[inline]
    pub fn read(&self) -> Option<(i32, u32, i32, u32)> {
        let end_packed = self.end.load(Ordering::Acquire);
        let valid = (end_packed >> 63) & 1 != 0;

        if !valid {
            return None;
        }

        let start_packed = self.start.load(Ordering::Acquire);
        let (start_row, start_col) = Self::unpack_coord(start_packed);
        let (end_row, end_col) = Self::unpack_coord(end_packed);

        Some((start_row, start_col, end_row, end_col))
    }

    /// 清除选区
    #[inline]
    pub fn clear(&self) {
        self.end.store(0, Ordering::Release); // valid bit = 0
    }

    /// 检查是否有有效选区
    #[inline]
    pub fn has_selection(&self) -> bool {
        let end_packed = self.end.load(Ordering::Acquire);
        (end_packed >> 63) & 1 != 0
    }
}

impl Default for AtomicSelectionCache {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// P1.2: AtomicTitleCache - 标题缓存
// ============================================================================

use std::sync::atomic::AtomicPtr;
use std::ptr;

/// 标题缓存
///
/// 使用 AtomicPtr<String> 实现无锁标题更新
/// 采用 RCU (Read-Copy-Update) 模式：
/// - 更新时分配新 String，原子交换指针
/// - 读取时克隆当前值
/// - 旧值通过 Box 自动释放
#[derive(Debug)]
pub struct AtomicTitleCache {
    /// 指向堆分配的 String
    ptr: AtomicPtr<String>,
}

impl AtomicTitleCache {
    /// 创建新的标题缓存（初始为空）
    pub fn new() -> Self {
        Self {
            ptr: AtomicPtr::new(ptr::null_mut()),
        }
    }

    /// 更新标题（生产者调用：PTY 线程）
    ///
    /// # 参数
    /// - title: 新标题
    pub fn update(&self, title: &str) {
        // 分配新 String
        let new_ptr = Box::into_raw(Box::new(title.to_string()));

        // 原子交换指针
        let old_ptr = self.ptr.swap(new_ptr, Ordering::AcqRel);

        // 释放旧值
        if !old_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(old_ptr));
            }
        }
    }

    /// 读取标题（消费者调用：主线程）
    ///
    /// # 返回
    /// - `Some(String)` - 当前标题
    /// - `None` - 无标题
    pub fn read(&self) -> Option<String> {
        let ptr = self.ptr.load(Ordering::Acquire);
        if ptr.is_null() {
            None
        } else {
            // 安全：ptr 指向有效的 String，且我们只读取
            unsafe { Some((*ptr).clone()) }
        }
    }

    /// 清除标题
    pub fn clear(&self) {
        let old_ptr = self.ptr.swap(ptr::null_mut(), Ordering::AcqRel);
        if !old_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(old_ptr));
            }
        }
    }
}

impl Default for AtomicTitleCache {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for AtomicTitleCache {
    fn drop(&mut self) {
        let ptr = self.ptr.load(Ordering::Acquire);
        if !ptr.is_null() {
            unsafe {
                drop(Box::from_raw(ptr));
            }
        }
    }
}

// ============================================================================
// P1.3: AtomicScrollCache - 滚动位置缓存
// ============================================================================

/// 滚动位置缓存
///
/// 使用 64 位原子变量存储滚动信息：
/// - bits 0-31: display_offset (u32)
/// - bits 32-47: history_size (u16，截断大值)
/// - bits 48-62: total_lines (u15，截断大值)
/// - bit 63: valid
#[derive(Debug)]
pub struct AtomicScrollCache {
    packed: AtomicU64,
}

impl AtomicScrollCache {
    /// 创建新的滚动缓存（初始无效）
    pub fn new() -> Self {
        Self {
            packed: AtomicU64::new(0),
        }
    }

    /// 打包滚动信息
    #[inline]
    fn pack(display_offset: u32, history_size: u16, total_lines: u16, valid: bool) -> u64 {
        let mut packed = display_offset as u64;
        packed |= (history_size as u64) << 32;
        packed |= ((total_lines & 0x7FFF) as u64) << 48; // 只用 15 位
        if valid {
            packed |= 1u64 << 63;
        }
        packed
    }

    /// 解包滚动信息
    #[inline]
    fn unpack(packed: u64) -> (u32, u16, u16, bool) {
        let display_offset = (packed & 0xFFFFFFFF) as u32;
        let history_size = ((packed >> 32) & 0xFFFF) as u16;
        let total_lines = ((packed >> 48) & 0x7FFF) as u16;
        let valid = (packed >> 63) & 1 != 0;
        (display_offset, history_size, total_lines, valid)
    }

    /// 更新滚动信息（生产者调用：渲染线程）
    ///
    /// # 参数
    /// - display_offset: 当前显示偏移
    /// - history_size: 历史行数
    /// - total_lines: 总行数
    #[inline]
    pub fn update(&self, display_offset: u32, history_size: usize, total_lines: usize) {
        // 截断大值到 u16 范围
        let history_size = (history_size.min(u16::MAX as usize)) as u16;
        let total_lines = (total_lines.min(0x7FFF)) as u16; // 15 位

        let packed = Self::pack(display_offset, history_size, total_lines, true);
        self.packed.store(packed, Ordering::Release);
    }

    /// 读取滚动信息（消费者调用：主线程）
    ///
    /// # 返回
    /// - `Some((display_offset, history_size, total_lines))` - 有效信息
    /// - `None` - 缓存无效
    #[inline]
    pub fn read(&self) -> Option<(u32, u16, u16)> {
        let packed = self.packed.load(Ordering::Acquire);
        let (display_offset, history_size, total_lines, valid) = Self::unpack(packed);
        if valid {
            Some((display_offset, history_size, total_lines))
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
        (packed >> 63) & 1 != 0
    }
}

impl Default for AtomicScrollCache {
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

    // ========================================================================
    // P1.1: AtomicSelectionCache 测试
    // ========================================================================

    #[test]
    fn test_atomic_selection_cache_basic() {
        let cache = AtomicSelectionCache::new();

        // 初始状态无选区
        assert!(!cache.has_selection());
        assert!(cache.read().is_none());

        // 更新选区
        cache.update(10, 5, 20, 15);

        // 读取
        assert!(cache.has_selection());
        let (start_row, start_col, end_row, end_col) = cache.read().unwrap();
        assert_eq!(start_row, 10);
        assert_eq!(start_col, 5);
        assert_eq!(end_row, 20);
        assert_eq!(end_col, 15);

        // 清除
        cache.clear();
        assert!(!cache.has_selection());
        assert!(cache.read().is_none());
    }

    #[test]
    fn test_atomic_selection_cache_negative_rows() {
        let cache = AtomicSelectionCache::new();

        // 测试负数行号（历史滚动）
        cache.update(-100, 0, 10, 80);

        let (start_row, start_col, end_row, end_col) = cache.read().unwrap();
        assert_eq!(start_row, -100);
        assert_eq!(start_col, 0);
        assert_eq!(end_row, 10);
        assert_eq!(end_col, 80);
    }

    #[test]
    fn test_atomic_selection_cache_concurrent() {
        let cache = Arc::new(AtomicSelectionCache::new());
        let cache_writer = Arc::clone(&cache);
        let cache_reader = Arc::clone(&cache);

        let iterations = 10000;

        let writer = thread::spawn(move || {
            for i in 0..iterations {
                let row = (i % 100) as i32;
                let col = (i % 80) as u32;
                cache_writer.update(row, col, row + 10, col + 20);
            }
        });

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
        assert!(valid_reads > 0);
    }

    // ========================================================================
    // P1.2: AtomicTitleCache 测试
    // ========================================================================

    #[test]
    fn test_atomic_title_cache_basic() {
        let cache = AtomicTitleCache::new();

        // 初始状态无标题
        assert!(cache.read().is_none());

        // 更新标题
        cache.update("Hello World");
        assert_eq!(cache.read(), Some("Hello World".to_string()));

        // 更新新标题
        cache.update("New Title");
        assert_eq!(cache.read(), Some("New Title".to_string()));

        // 清除
        cache.clear();
        assert!(cache.read().is_none());
    }

    #[test]
    fn test_atomic_title_cache_unicode() {
        let cache = AtomicTitleCache::new();

        // 测试 Unicode 标题
        cache.update("终端标题 🚀");
        assert_eq!(cache.read(), Some("终端标题 🚀".to_string()));
    }

    #[test]
    fn test_atomic_title_cache_concurrent() {
        let cache = Arc::new(AtomicTitleCache::new());
        let cache_writer = Arc::clone(&cache);
        let cache_reader = Arc::clone(&cache);

        let iterations = 1000;

        let writer = thread::spawn(move || {
            for i in 0..iterations {
                cache_writer.update(&format!("Title {}", i));
            }
        });

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
        assert!(valid_reads > 0);
    }

    // ========================================================================
    // P1.3: AtomicScrollCache 测试
    // ========================================================================

    #[test]
    fn test_atomic_scroll_cache_basic() {
        let cache = AtomicScrollCache::new();

        // 初始状态无效
        assert!(!cache.is_valid());
        assert!(cache.read().is_none());

        // 更新
        cache.update(100, 500, 1000);

        // 读取
        assert!(cache.is_valid());
        let (offset, history, total) = cache.read().unwrap();
        assert_eq!(offset, 100);
        assert_eq!(history, 500);
        assert_eq!(total, 1000);

        // 失效
        cache.invalidate();
        assert!(!cache.is_valid());
        assert!(cache.read().is_none());
    }

    #[test]
    fn test_atomic_scroll_cache_max_values() {
        let cache = AtomicScrollCache::new();

        // 测试大值截断
        cache.update(u32::MAX, usize::MAX, usize::MAX);

        let (offset, history, total) = cache.read().unwrap();
        assert_eq!(offset, u32::MAX);
        assert_eq!(history, u16::MAX);
        assert_eq!(total, 0x7FFF); // 15 位最大值
    }

    #[test]
    fn test_atomic_scroll_cache_concurrent() {
        let cache = Arc::new(AtomicScrollCache::new());
        let cache_writer = Arc::clone(&cache);
        let cache_reader = Arc::clone(&cache);

        let iterations = 10000;

        let writer = thread::spawn(move || {
            for i in 0..iterations {
                cache_writer.update(i as u32, i, i * 2);
            }
        });

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
        assert!(valid_reads > 0);
    }
}
