# ETerm - Rust Backend

ETerm 的 Rust 后端，基于 [Rio Terminal](https://github.com/raphamorim/rio) 魔改而来，为 macOS 原生终端提供高性能渲染和终端逻辑处理。

## 架构概览

ETerm 采用混合架构：
- **Swift 层**：窗口管理、UI、用户交互（ETerm/）
- **Rust 层**：终端逻辑、ANSI 解析、渲染引擎（rio/）

### 核心组件

```
rio/
├── sugarloaf/          # 渲染引擎 (Skia + Metal)
├── sugarloaf-ffi/      # Swift ↔ Rust FFI 桥接层
├── rio-backend/        # 终端核心逻辑 (ANSI 解析、Crosswords)
├── copa/               # ANSI 解析器 (基于 vte)
├── teletypewriter/     # PTY 管理
└── corcovado/          # 事件循环 (基于 mio)
```

## 技术栈

- **渲染引擎**：从 WGPU 迁移到 Skia + Metal
- **并发渲染**：使用 Rayon 并行处理行数据
- **终端状态**：使用 parking_lot::RwLock 实现读写分离
- **FFI 层**：C ABI + Swift 互操作

## 核心优化

### 1. 消除 FFI 调用开销
**问题**：Phase 2 渲染每个字符调用一次 FFI（22,472 次）
**解决**：在 Rust 侧直接调用 Sugarloaf API
**收益**：Phase 2 从 2-3ms → 0.1-0.3ms

### 2. 样式 Fragment 合并
**问题**：每个字符创建一个 fragment（20,791 个，平均每行 110 个）
**解决**：合并同一行内连续相同样式的字符
**收益**：Style segments 减少 98%（20,791 → 270）

### 3. 锁前置策略
**问题**：Rayon 并发时每次读取行数据都需要加锁，I/O 线程持有写锁导致渲染线程等待 10 秒
**解决**：一次性提取所有行数据后释放锁，再并发处理
**收益**：Phase 1 从 10,196ms → 95ms（提升 100x）

### 4. 消除进程检测开销
**问题**：每次 PTY 读取都调用 `proc_pidpath` 系统调用 + `ps` 命令
**解决**：注释掉未使用的进程检测逻辑
**收益**：粘贴大量文本从 2-3.5 秒卡顿 → 光速响应

## 性能指标

### 正常场景（cat、一次性输出）
- Phase 1 (parallel parse): 1ms ✅
- Phase 2 (merged render): 0.2ms ✅
- Style segments: 270 (avg 2.0 per line) ✅
- flush_and_render: 20-30ms ✅

### 性能目标
- **优秀**：总渲染 < 20ms（60fps 流畅）
- **可接受**：总渲染 20-50ms（30fps 基本流畅）
- **需优化**：总渲染 > 100ms（明显卡顿）

## 编译

```bash
# 编译 Rust 库
cd rio
cargo build --release -p sugarloaf-ffi

# 或使用脚本（自动复制到 Swift 项目）
./scripts/update_sugarloaf.sh
```

生成的库文件：
- `libsugarloaf_ffi.a` - 静态库（链接到 Xcode）
- `libsugarloaf_ffi.dylib` - 动态库（可选）

## 开发注意事项

### 代码规范
- 注释使用中文
- 只在关键指标异常时打印日志（如行数 > 30）
- 不要过度优化，优先解决核心问题

### 关键文件
- `sugarloaf-ffi/src/rio_terminal.rs` - Phase 1/2 渲染逻辑
- `sugarloaf-ffi/src/rio_machine.rs` - PTY I/O 和事件处理
- `sugarloaf/src/sugarloaf.rs` - Skia + Metal 渲染层
- `rio-backend/src/crosswords/mod.rs` - 终端状态管理

### FFI 边界
Swift → Rust 调用链：
```
Swift: writeInput()
  → FFI: rio_pool_write_input()
    → Rust: send_input()
      → Channel: Msg::Input
        → PTY: write()
```

## 致谢

ETerm 的 Rust 后端基于以下优秀开源项目：

- **[Rio Terminal](https://github.com/raphamorim/rio)** - 终端核心架构
- **[Alacritty](https://github.com/alacritty/alacritty)** - ANSI 解析和事件处理
- **[Skia](https://skia.org/)** - 2D 图形渲染引擎

## License

基于 Rio Terminal 的 MIT License，保留原始版权声明。

---

## Minimum Rust Version

Rust 1.90.0 或更高版本
