# Phase 1 偶发性性能暴涨问题

## 问题描述

在 Cmd+D 分屏操作时，Phase 1（并发解析）偶尔会从正常的 ~1ms 暴涨到 **2005ms（2 秒）**。

## 性能数据

### 正常情况
```
⚡ [Parallel Render] 94 lines, 113 cols
   Phase 1 (parallel parse): 778μs   ✅
   Phase 2 (merged render): 91μs
   Total: 869μs (0ms)
```

### 异常情况
```
⚡ [Parallel Render] 94 lines, 113 cols
   Phase 1 (parallel parse): 2005137μs  ❌ 2005ms = 2 秒！
   Phase 2 (merged render): 340μs
   Total: 2005477μs (2005ms)
```

## 影响

- **用户体验**：Cmd+D 分屏操作卡顿 2 秒
- **整体渲染**：render_all 从 14ms → 2024ms
- **连锁反应**：导致 Swift Layout Setup 也变慢（2.3 秒）

## Phase 1 代码位置

**文件**：`rio/sugarloaf-ffi/src/rio_terminal.rs`
**行数**：第 895-1012 行

```rust
// 🔥 阶段 1：并发提取和解析所有行的数据
let rows_data: Vec<RowRenderData> = (0..lines_to_render)
    .into_par_iter()  // 使用 Rayon 并发
    .map(|row_index| {
        // 计算绝对行号
        let absolute_row = snapshot.scrollback_lines as i64
            - snapshot.display_offset as i64
            + row_index as i64;

        // 获取行单元格
        let cells = terminal.get_row_cells(absolute_row);

        // 检查是否为光标位置报告行
        if Self::is_cursor_position_report_line(&cells) {
            return RowRenderData {
                chars: Vec::new(),
                is_cursor_report: true,
            };
        }

        // 解析该行的所有字符
        let mut char_data_vec = Vec::with_capacity(cols_to_render);

        for (col_index, cell) in cells.iter().enumerate().take(cols_to_render) {
            // 跳过占位符
            // 解析字符、颜色、样式等
            char_data_vec.push(CharRenderData { ... });
        }

        RowRenderData {
            chars: char_data_vec,
            is_cursor_report: false,
        }
    })
    .collect();
```

## 可能原因

### 1. Rayon 线程池问题
- **首次初始化延迟**：Rayon 线程池首次使用可能有初始化开销
- **线程调度问题**：macOS 调度器可能抢占线程
- **线程池阻塞**：其他任务占用线程池

### 2. 内存分配问题
```rust
let mut char_data_vec = Vec::with_capacity(cols_to_render);  // 每行分配
char_data_vec.push(CharRenderData { ... });  // 推送复杂结构体
```

**潜在问题**：
- 大量小对象分配（94 行 × 113 列 = ~10,000 个 CharRenderData）
- 内存碎片导致分配变慢
- 内存压力触发系统回收

### 3. terminal.get_row_cells() 慢
```rust
let cells = terminal.get_row_cells(absolute_row);  // 👈 可能的瓶颈
```

**可能**：
- 某一行的数据特别复杂（大量宽字符、emoji）
- 读取 scrollback buffer 时触发锁竞争
- 缓存 miss 导致重新计算

### 4. 系统调度问题
- macOS 系统负载突然增加
- 其他进程抢占 CPU
- 热节流（CPU 降频）

## 触发条件

**操作**：Cmd+D 分屏
**上下文**：
```
📝 [SplitPanel] Creating terminal with inherited CWD
🚀 [Coordinator] Creating terminal with CWD
🔧 [GlobalTerminalManager] Creating terminal with CWD
✅ [Coordinator] Terminal created with ID 7
```

**关键时间点**：
```
Layout Setup: 2272ms  // Swift 层
Rust Render: 2024ms   // Phase 1 占 2005ms
```

## 诊断方向

### 方向 1：添加 Phase 1 内部日志

在并发循环内部添加分段计时：

```rust
.map(|row_index| {
    let row_start = std::time::Instant::now();

    // 获取行数据
    let t1 = std::time::Instant::now();
    let cells = terminal.get_row_cells(absolute_row);
    let get_cells_time = t1.elapsed().as_micros();

    // 解析字符
    let t2 = std::time::Instant::now();
    for (col_index, cell) in cells.iter().enumerate() {
        // ...
    }
    let parse_time = t2.elapsed().as_micros();

    let row_time = row_start.elapsed().as_micros();

    // 如果某行特别慢，打印日志
    if row_time > 10000 {  // > 10ms
        println!("⚠️ Slow row {}: total={}μs, get_cells={}μs, parse={}μs",
            row_index, row_time, get_cells_time, parse_time);
    }

    // ...
})
```

### 方向 2：检查 Rayon 线程池状态

```rust
use rayon::ThreadPoolBuilder;

// 在初始化时设置固定线程数
let pool = ThreadPoolBuilder::new()
    .num_threads(8)  // 固定线程数
    .build()
    .unwrap();

// 使用自定义线程池
pool.install(|| {
    let rows_data: Vec<RowRenderData> = (0..lines_to_render)
        .into_par_iter()
        .map(...)
        .collect();
});
```

### 方向 3：禁用并发测试

临时禁用 Rayon，看是否仍然慢：

```rust
// 串行版本
let rows_data: Vec<RowRenderData> = (0..lines_to_render)
    .map(|row_index| {  // 👈 移除 into_par_iter()
        // ...
    })
    .collect();
```

如果串行版本也慢 2 秒，说明不是 Rayon 的问题。

### 方向 4：检查内存分配

使用 Instruments 的 Allocations 工具：
- 监控内存分配模式
- 检查是否有大量碎片
- 确认 GC/compaction 时机

## 待办事项

- [ ] 添加 Phase 1 内部分段日志
- [ ] 测试 Rayon 线程池配置
- [ ] 测试串行版本性能
- [ ] 使用 Instruments 分析内存
- [ ] 多次复现测试（确认触发频率）

## 相关文件

- `rio/sugarloaf-ffi/src/rio_terminal.rs` (第 895-1012 行)
- `ETerm/ETerm/Infrastructure/Coordination/TerminalWindowCoordinator.swift`

## 时间记录

- **发现时间**：2025-12-01
- **触发操作**：Cmd+D 分屏
- **状态**：待调查
