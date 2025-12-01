# Snapshot 缓存实现方案（方案 A）

## 问题背景

在粘贴大量数据时，渲染性能出现严重问题：

```
Layout Setup: 2600ms（其中 getSnapshot() 加锁等待 2.6 秒）
Rust Render: 50ms
Total: 2650ms
```

**根本原因**：
- Swift 的 Layout Setup 调用 `getSnapshot()` 需要获取读锁
- I/O 线程处理粘贴数据时持有写锁（2.6 秒）
- Layout Setup 的读锁被阻塞，等待写锁释放

## 解决方案

**方案 A：在 Swift 层缓存 snapshot，避免渲染时加锁等待**

### 核心思路

1. 在 `RioMetalView` 中添加 `cachedSnapshots` 字典
2. 渲染时直接使用缓存，不调用 FFI
3. 渲染完成后异步更新缓存（不阻塞主线程）

### 实现细节

#### 1. 添加缓存变量

```swift
/// Snapshot 缓存（避免渲染时加锁等待）
/// 键为 terminalId，值为 TerminalSnapshot
private var cachedSnapshots: [Int: TerminalSnapshot] = [:]
private let snapshotCacheLock = NSLock()
```

#### 2. 提供缓存读取方法

```swift
/// 获取缓存的 Snapshot（优先使用缓存，降级到实时查询）
private func getCachedSnapshot(terminalId: Int) -> TerminalSnapshot? {
    // 1. 先尝试从缓存读取（无锁，快速路径）
    snapshotCacheLock.lock()
    let cached = cachedSnapshots[terminalId]
    snapshotCacheLock.unlock()

    if let cached = cached {
        return cached
    }

    // 2. 缓存未命中，降级到实时查询（可能加锁等待）
    return terminalManager.getSnapshot(terminalId: terminalId)
}
```

**关键点**：
- 优先读缓存（快速路径，无 FFI 调用）
- 缓存未命中时降级到实时查询（确保初始化时正常工作）
- 使用独立的锁保护缓存，避免与 Rust 锁冲突

#### 3. 异步更新缓存

```swift
/// 更新 Snapshot 缓存（异步，不阻塞渲染）
private func updateSnapshotCache(for terminalIds: [Int]) {
    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
        guard let self = self else { return }

        var newSnapshots: [Int: TerminalSnapshot] = [:]
        for terminalId in terminalIds {
            if let snapshot = self.terminalManager.getSnapshot(terminalId: terminalId) {
                newSnapshots[terminalId] = snapshot
            }
        }

        // 批量更新缓存（减少锁持有时间）
        self.snapshotCacheLock.lock()
        for (terminalId, snapshot) in newSnapshots {
            self.cachedSnapshots[terminalId] = snapshot
        }
        self.snapshotCacheLock.unlock()
    }
}
```

**关键点**：
- 异步执行，不阻塞主线程
- 批量更新，减少锁持有时间
- 使用 `.userInteractive` QoS 确保及时更新

#### 4. 在渲染循环中使用缓存

**修改位置 1：Layout Setup（第 999 行，核心优化点）**

```swift
// 处理 resize（只在尺寸变化时才调用，避免每帧都 resize）
// ✅ 使用缓存的 Snapshot，避免加锁等待
if let snapshot = getCachedSnapshot(terminalId: Int(terminalId)) {
    // ... resize 逻辑
}
```

**修改位置 2：双击选中单词（第 1602 行）**

```swift
// 获取快照以转换坐标（使用缓存）
guard let snapshot = getCachedSnapshot(terminalId: Int(terminalId)) else { return }
```

**修改位置 3：滚动事件（第 1825 行）**

```swift
// 同步 displayOffset（仅用于记录滚动位置）
// ✅ 使用缓存的 Snapshot，避免加锁等待
if let snapshot = getCachedSnapshot(terminalId: Int(terminalId)),
   let panel = coordinator.terminalWindow.allPanels.first(where: {
       $0.activeTab?.rustTerminalId == terminalId
   }),
   let tab = panel.activeTab {
    // ...
}
```

#### 5. 在渲染循环末尾更新缓存

```swift
// 3. 异步更新下一帧的 Snapshot 缓存（不阻塞渲染）
let terminalIds = tabsToRender.map { Int($0.0) }
updateSnapshotCache(for: terminalIds)
```

**关键点**：
- 在 Rust Render 完成后更新
- 为下一帧准备缓存数据
- 异步执行，不影响当前帧

#### 6. 清理资源

```swift
func cleanup() {
    // ...

    // 清除 Snapshot 缓存
    snapshotCacheLock.lock()
    cachedSnapshots.removeAll()
    snapshotCacheLock.unlock()

    // ...
}
```

## 预期效果

### 性能提升

**粘贴大量数据时（2.6 秒写锁）**：
- Layout Setup: 从 2600ms → **0.1ms**（读缓存）
- Rust Render: 50ms（不变）
- Total: 从 2650ms → **50.1ms**

**正常渲染**：
- Layout Setup: 从 5ms → **0.01ms**（读缓存）
- Rust Render: 50ms（不变）
- Total: 从 55ms → **50.01ms**

### 缓存更新延迟

- 缓存延迟：约 1 帧（16ms @ 60fps）
- 用户感知：无（视觉延迟小于人眼可分辨的阈值）
- 降级策略：首次渲染时缓存未命中，自动降级到实时查询

## 风险评估

### 1. 缓存一致性

**风险**：缓存可能过期（最多 1 帧）

**缓解措施**：
- 每帧渲染后立即异步更新缓存
- 使用 `.userInteractive` QoS 确保及时更新
- 降级策略确保首次渲染正确

### 2. 内存占用

**风险**：多终端时缓存占用内存

**评估**：
- 单个 Snapshot: 约 1KB
- 10 个终端: 10KB（可忽略）
- 风险极低

### 3. 线程安全

**风险**：缓存读写并发

**缓解措施**：
- 使用独立的 `snapshotCacheLock` 保护缓存
- 读写操作都加锁（锁粒度小，影响可忽略）
- 与 Rust 锁完全分离，不会死锁

## 测试验证

### 测试场景

1. **粘贴大量文本**
   - 预期：Layout Setup < 1ms
   - 验证：观察慢帧日志

2. **快速切换 Tab**
   - 预期：首次渲染降级到实时查询，后续使用缓存
   - 验证：观察渲染耗时

3. **滚动历史**
   - 预期：使用缓存，滚动流畅
   - 验证：观察滚动性能

4. **多窗口/多 Panel**
   - 预期：每个终端独立缓存，互不影响
   - 验证：观察多终端渲染

### 验证指标

- Layout Setup 耗时 < 1ms（99% 情况）
- 总渲染时间 < 60ms（60fps 阈值）
- 无缓存一致性问题（显示正确）

## 实现状态

- [x] 添加缓存变量和锁
- [x] 实现 `getCachedSnapshot()` 方法
- [x] 实现 `updateSnapshotCache()` 方法
- [x] 修改 Layout Setup 中的调用（第 999 行）
- [x] 修改双击选中中的调用（第 1602 行）
- [x] 修改滚动事件中的调用（第 1825 行）
- [x] 在渲染循环末尾添加缓存更新
- [x] 在 cleanup 中清理缓存
- [x] 编译验证通过

## 后续优化

如果方案 A 效果不理想，可以考虑：

1. **方案 B：Rust 侧缓存 Snapshot（Arc<RwLock<Snapshot>>）**
   - 优点：读锁不会被写锁阻塞（Arc 引用计数）
   - 缺点：需要修改 Rust 代码

2. **方案 C：使用消息队列解耦**
   - 优点：完全解耦读写
   - 缺点：复杂度高

3. **方案 D：优化粘贴逻辑**
   - 优点：从根源解决问题
   - 缺点：需要重构粘贴处理

## 参考文档

- [PHASE1_PERFORMANCE_ISSUE.md](./PHASE1_PERFORMANCE_ISSUE.md) - 性能问题分析
- [RioTerminalView.swift](../ETerm/ETerm/Presentation/Views/RioTerminalView.swift) - 实现代码
