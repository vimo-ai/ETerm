# Fragments Cache 使用指南

## Swift 端集成

### 1. 启用 Fragments Cache

Cache 在 macOS 平台自动启用，无需额外配置。

### 2. 清空 Cache（可选）

在以下场景需要手动清空 cache：

```swift
// 字体大小改变时
func updateFontSize(_ newSize: CGFloat) {
    // 清空 fragments cache
    rio_pool_clear_fragments_cache(terminalPool)
    
    // 更新字体
    // ...
}

// 窗口大小改变时（可选）
func windowDidResize() {
    // 可选：清空 cache
    // 注意：hash 机制已能自动处理大部分情况，
    // 只有在发现渲染异常时才需要清空
    rio_pool_clear_fragments_cache(terminalPool)
}

// 颜色主题切换时（可选）
func changeTheme(_ newTheme: Theme) {
    // 可选：清空 cache
    // 注意：hash 包含颜色信息，通常不需要手动清空
    // rio_pool_clear_fragments_cache(terminalPool)
}
```

### 3. 监控 Cache 性能

查看控制台日志（DEBUG_PERFORMANCE = true 时）：

```
⚡ [Fragments Cache] 45 hits, 5 misses (hit rate: 90.0%)
⚡ [Extract] 5 / 50 lines in 123μs (filter: 45μs)
   Cache size: 238 entries
```

**关键指标**:
- **Hit Rate**: cache 命中率
  - 滚动时应 > 90%
  - 编辑时应 50-70%
  - 如果 < 50%，可能需要优化
- **Cache Size**: cache 中存储的 entry 数量
  - 通常 100-1000 entries
  - 如果 > 5000，可能占用过多内存

## 性能对比

### 场景 1: 滚动大文件（50 行可见）

**优化前**:
```
⚡ [Optimized Render] 50 lines, 120 cols
   Phase 1 (hash): 234μs
   Phase 1 (filter): 12μs - 50 / 50 lines (0.0% cache hit)
   Phase 2 (extract): 4563μs (48.2%)
   Phase 2 (parallel parse): 4892μs (51.8%)
   Phase 2 Total: 9455μs (9ms)
   Phase 3 (merged render): 892μs
   Total: 10581μs (10ms) - 5832 chars parsed
```

**优化后（滚动稳定后）**:
```
⚡ [Fragments Cache] 45 hits, 5 misses (hit rate: 90.0%)
⚡ [Extract] 5 / 50 lines in 456μs (filter: 23μs)
⚡ [Optimized Render] 50 lines, 120 cols
   Phase 1 (hash): 245μs
   Phase 1 (filter): 23μs - 5 / 50 lines (90.0% cache hit)
   Phase 2 (extract): 456μs (31.7%)
   Phase 2 (parallel parse): 982μs (68.3%)
   Phase 2 Total: 1438μs (1ms)
   Phase 3 (merged render): 723μs
   Total: 2406μs (2ms) - 583 chars parsed
   Cache size: 238 entries
```

**性能提升**: 10ms → 2ms (5x 提升)

### 场景 2: 编辑文本（30 行可见）

**优化前**:
```
   Total: 6234μs (6ms) - 3456 chars parsed
```

**优化后（cache warm）**:
```
⚡ [Fragments Cache] 18 hits, 12 misses (hit rate: 60.0%)
   Total: 3891μs (3ms) - 1382 chars parsed
   Cache size: 156 entries
```

**性能提升**: 6ms → 3ms (2x 提升)

### 场景 3: 首次渲染（冷启动）

**优化前**:
```
   Total: 12456μs (12ms) - 6234 chars parsed
```

**优化后（cache cold）**:
```
⚡ [Fragments Cache] 0 hits, 50 misses (hit rate: 0.0%)
   Total: 12789μs (12ms) - 6234 chars parsed
   Cache size: 50 entries
```

**性能差异**: 基本相同（cache miss 时需要额外存储）

## 最佳实践

### 1. 何时清空 Cache

**必须清空**:
- 字体大小改变
- 字体类型改变

**可选清空**:
- 窗口大小改变（通常不需要，hash 会自动失效）
- 颜色主题改变（通常不需要，hash 包含颜色）
- 性能下降时（作为诊断手段）

### 2. 性能调优

如果 cache hit rate 过低（< 50%）：
1. 检查是否频繁调用 `clear_fragments_cache`
2. 检查终端内容是否频繁变化
3. 考虑增加 cache 大小限制

如果内存占用过高：
1. 定期清空 cache（如每 10 分钟）
2. 实现 LRU 淘汰策略（需要修改 Rust 代码）
3. 限制 cache 最大 entries（需要修改 Rust 代码）

### 3. 调试技巧

**启用性能日志**:
```rust
// 在 rio_terminal.rs 中设置
const DEBUG_PERFORMANCE: bool = true;
```

**查看 cache 统计**:
- 观察 hit rate 变化趋势
- 监控 cache size 增长
- 对比优化前后的 Total time

## 常见问题

### Q1: Cache 会导致渲染错误吗？

**A**: 不会。Cache 使用 content hash 作为 key，只有内容完全相同时才会 cache hit。Hash 冲突概率极低（< 1e-15）。

### Q2: Cache 会占用多少内存？

**A**: 取决于终端内容。通常：
- 每个 entry: 1-5KB
- 1000 entries: ~5MB
- 实际使用中通常 < 10MB

### Q3: 需要手动管理 Cache 吗？

**A**: 通常不需要。只有在字体改变时需要调用 `clear_fragments_cache`。其他场景 hash 机制会自动处理。

### Q4: 为什么只支持 macOS？

**A**: 目前 Skia layout cache 优化只在 macOS 实现。其他平台可以后续扩展。

### Q5: 如何禁用 Cache？

**A**: 编译时移除 `#[cfg(target_os = "macos")]` 条件编译，或在运行时始终调用 `clear_fragments_cache` 清空 cache。

## 后续规划

1. **自动 LRU 淘汰**（优先级：高）
   - 限制 cache 最大 entries（如 1000）
   - 自动淘汰最少使用的 entries

2. **Cache 统计 API**（优先级：中）
   - 提供查询 hit/miss/size 的 FFI 接口
   - Swift 端可实时监控 cache 性能

3. **增量更新**（优先级：低）
   - 支持部分 cache 失效（而非全量清空）
   - 根据变化类型选择性失效

4. **跨平台支持**（优先级：低）
   - 扩展到 Linux/Windows 平台
