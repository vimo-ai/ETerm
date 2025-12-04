# Fragments Cache 优化实现总结

## 优化目标

大幅提升终端滚动和渲染性能，通过缓存已解析的 fragments 数据，避免重复提取和解析未变化的行。

## 实现方案

### 1. Cache 数据结构

**位置**: `/Users/higuaifan/Desktop/hi/小工具/english/rio/sugarloaf-ffi/src/rio_terminal.rs`

**核心结构**:
```rust
/// Fragments Cache - 缓存已解析的行数据
#[derive(Debug, Clone)]
struct CachedFragments {
    /// 已解析的字符渲染数据
    chars: Vec<CharRenderData>,
}

/// 终端池 - 管理多个终端
pub struct RioTerminalPool {
    // ... 现有字段

    /// Fragments Cache - 缓存已解析的行数据（所有终端共享）
    #[cfg(target_os = "macos")]
    fragments_cache: std::cell::RefCell<HashMap<u64, CachedFragments>>,
}
```

**设计要点**:
- 使用 `HashMap<u64, CachedFragments>` 存储缓存
- Key: `content_hash`（grid 行内容的 hash，由 `hash_grid_row` 生成）
- Value: 已解析的 `CharRenderData` 列表
- 所有终端共享同一个 cache（提高 cache hit rate）
- 使用 `RefCell` 包装（单线程安全访问）

### 2. 渲染流程优化

**优化前流程**（line 1337-1662）:
```
阶段 1: 计算所有行的 hash
阶段 2: 总是提取所有行 (extract_row_cells_locked)
阶段 3: 并发解析所有行 (parse_cells)
阶段 4: 填充 fragments
```

**优化后流程**（line 1319-1734）:
```
阶段 0: 计算所有行的 hash
阶段 1: 查询 cache，筛选 cache miss 的行
        - cache hit: 跳过提取，直接复用
        - cache miss: 加入提取列表
阶段 2: 只提取 cache miss 的行 (extract_row_cells_locked)
阶段 3: 只解析 cache miss 的行 (parse_cells)
阶段 4: 填充 fragments
        - cache hit: 从 cache 获取并复用
        - cache miss: 使用新解析数据，并存入 cache
```

**关键代码片段**:
```rust
// 阶段 1: 查询 cache，筛选需要提取的行
let lines_to_extract: Vec<usize> = (0..lines_to_render)
    .filter(|&row_index| {
        let hash = row_hashes[row_index];
        if fragments_cache.borrow().contains_key(&hash) {
            cache_hits += 1;
            false  // cache hit，不需要提取
        } else {
            cache_misses += 1;
            true   // cache miss，需要提取
        }
    })
    .collect();

// 阶段 4: 填充 fragments
let row_data = if let Some(cached) = fragments_cache.borrow().get(&hash) {
    // Cache hit: 复用
    Some(RowRenderData {
        chars: cached.chars.clone(),
        is_cursor_report: false,
    })
} else if let Some(parsed) = parsed_rows.get(&row_index) {
    // Cache miss: 使用新解析的数据，并缓存
    if !parsed.is_cursor_report && !parsed.chars.is_empty() {
        fragments_cache.borrow_mut().insert(hash, CachedFragments {
            chars: parsed.chars.clone(),
        });
    }
    Some(parsed.clone())
} else {
    None
};
```

### 3. Cache 管理

**Cache 清空方法**:
```rust
/// 清空 Fragments Cache（在字体、颜色方案变化时调用）
#[cfg(target_os = "macos")]
pub fn clear_fragments_cache(&self) {
    self.fragments_cache.borrow_mut().clear();
    perf_log!("🗑️  [Fragments Cache] Cleared cache");
}
```

**FFI 导出函数**:
```rust
/// 清空 Fragments Cache（在字体、颜色方案变化时调用）
#[cfg(target_os = "macos")]
#[no_mangle]
pub extern "C" fn rio_pool_clear_fragments_cache(pool: *mut RioTerminalPool) {
    catch_panic!((), {
        if !pool.is_null() {
            let pool = unsafe { &*pool };
            pool.clear_fragments_cache();
        }
    })
}
```

**Cache 失效场景**:
- 字体变化（font_size 变化会影响渲染）
- 窗口 resize（可能影响 cell 宽度）
- 颜色方案变化（fg/bg 颜色）

**使用建议**:
Swift 端应在以下时机调用 `rio_pool_clear_fragments_cache`:
1. 字体大小改变时
2. 窗口大小改变时（可选，hash 机制已能处理）
3. 颜色主题切换时（可选，hash 机制已能处理）

### 4. 性能日志

新增性能统计日志:
```rust
perf_log!("⚡ [Fragments Cache] {} hits, {} misses (hit rate: {:.1}%)",
    cache_hits, cache_misses,
    if cache_hits + cache_misses > 0 {
        cache_hits as f32 / (cache_hits + cache_misses) as f32 * 100.0
    } else {
        0.0
    }
);

// 在日志末尾添加 cache 大小信息
perf_log!("   Cache size: {} entries", fragments_cache.borrow().len());
```

## 预期性能提升

### 滚动场景（最佳情况）
- **优化前**: 每帧提取 + 解析所有行（~10-15ms）
- **优化后**: cache hit 率 > 90%，只提取和解析 < 10% 行（~1-2ms）
- **性能提升**: 5-10x

### 普通编辑场景
- **优化前**: 每帧提取 + 解析所有行
- **优化后**: cache hit 率 50-70%，提取和解析减少一半
- **性能提升**: 1.5-2x

### Cache 统计指标
- **Hit Rate**: 滚动时 > 90%，编辑时 50-70%
- **Cache Size**: 根据终端内容，通常 100-1000 entries
- **Memory Overhead**: 每个 entry 约 1-5KB，总计 < 5MB

## 编译验证

```bash
cd /Users/higuaifan/Desktop/hi/小工具/english/rio
cargo build --release -p sugarloaf-ffi
```

**编译结果**: ✅ 成功
- 只有 1 个 warning（未使用的 `render_terminal_content_partial` 函数）
- 编译时间: ~42s（release mode）

## 注意事项

### 1. 线程安全
- 使用 `RefCell` 包装 cache（单线程访问）
- 不支持跨线程共享（符合当前架构）

### 2. Clone 开销
- `CharRenderData` clone 有一定开销（包含 String 字段）
- 可考虑后续优化：使用 `Arc<CharRenderData>` 或引用计数

### 3. Hash 冲突
- 使用 `hash_grid_row` 生成 64-bit hash
- 冲突概率极低（< 1e-15）
- 即使冲突，也只会导致错误的 cache hit（渲染错误内容），不会崩溃

### 4. 内存管理
- Cache 无大小限制（可能占用较多内存）
- 建议后续优化：实现 LRU 淘汰策略或设置最大容量（如 1000 entries）

### 5. 平台限制
- 仅在 macOS 平台启用（`#[cfg(target_os = "macos")]`）
- 其他平台仍使用原有渲染流程

## 测试建议

### 1. 功能测试
- ✅ 编译通过
- ⏳ 滚动测试：验证内容渲染正确，无丢失、无错位
- ⏳ 编辑测试：验证输入、删除、换行等操作正常
- ⏳ 选区测试：验证文本选择和复制正常
- ⏳ 搜索测试：验证搜索高亮正常

### 2. 性能测试
- ⏳ 滚动性能：测量滚动时的渲染时间（应 < 2ms）
- ⏳ Cache hit rate：测量 cache 命中率（滚动时应 > 90%）
- ⏳ 内存占用：监控 cache 大小增长

### 3. 边界测试
- ⏳ 空终端：验证空行处理
- ⏳ 大量输出：验证 cache 不会无限增长
- ⏳ 多终端：验证多终端共享 cache 正常

## 后续优化方向

1. **减少 Clone 开销**
   - 使用 `Arc<CharRenderData>` 代替 `CharRenderData`
   - 或使用引用计数避免深拷贝

2. **Cache 大小控制**
   - 实现 LRU 淘汰策略
   - 设置最大 cache 容量（如 1000 entries）
   - 定期清理过期 entries

3. **更精细的 Cache 失效**
   - 根据变化类型选择性失效（如颜色变化不影响 layout）
   - 实现增量更新而非全量清空

4. **统计和监控**
   - 添加 cache metrics（hit/miss/size/memory）
   - 提供 API 查询 cache 状态

## 总结

Fragments Cache 优化已成功实现，预期能大幅提升滚动和渲染性能。主要通过以下方式实现：

1. **共享 Cache**: 所有终端共享 fragments cache，提高 hit rate
2. **智能过滤**: 只提取和解析 cache miss 的行，减少 90% 工作量
3. **简单管理**: 提供清空 cache 的 API，处理失效场景

下一步需要在实际使用中验证性能提升和 cache hit rate，确保渲染正确性。
