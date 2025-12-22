# Rust → Swift 日志桥接

## 概述

实现了 Rust 端关键日志到 Swift LogManager 的桥接，让 Rust 端的诊断日志能够被持久化到文件中。

## 架构

```
Rust 端                        Swift 端
┌─────────────────┐           ┌──────────────────┐
│ RenderLoop 等   │           │ RustLogBridge    │
│                 │           │                  │
│ rust_log_warn!  ├──────────►│ Callback         │
│ rust_log_error! │  FFI      │                  │
│                 │           │      ↓           │
└─────────────────┘           │ LogManager       │
                              │                  │
                              │      ↓           │
                              │ debug-YYYY...log │
                              └──────────────────┘
```

## 实现细节

### Rust 端

1. **日志 FFI 模块** (`ffi/logging.rs`)
   - 日志级别枚举：`RustLogLevel` (Debug, Info, Warn, Error)
   - 回调类型定义：`LogCallback`
   - 全局回调存储：`LOG_CALLBACK` (原子指针，线程安全)
   - FFI 函数：`set_rust_log_callback()`, `clear_rust_log_callback()`
   - 便捷宏：`rust_log_debug!()`, `rust_log_info!()`, `rust_log_warn!()`, `rust_log_error!()`

2. **Fallback 机制**
   - 如果回调未设置，自动 fallback 到 `eprintln!`
   - 保证日志在任何情况下都能输出

3. **已替换的日志点**
   - `display_link.rs` (2处): CVDisplayLink 创建/设置失败
   - `terminal_pool.rs` (4处): terminal 查找失败、layout 为空、Background 模式跳过渲染
   - `render_scheduler.rs` (3处): 渲染统计、DisplayLink 启动失败

### Swift 端

1. **FFI 声明** (`SugarloafBridge.h`)
   - 日志级别枚举：`RustLogLevel`
   - 回调类型：`RustLogCallback`
   - FFI 函数声明

2. **日志桥接** (`RustLogBridge.swift`)
   - 实现日志回调，根据级别转发到 `LogManager`
   - 提供 `setupRustLogBridge()` 便捷函数

3. **App 初始化** (`ETermApp.swift`)
   - 在 `applicationDidFinishLaunching` 中调用 `setupRustLogBridge()`
   - 确保日志桥接在 App 启动时设置完成

## 使用方式

### Rust 端记录日志

```rust
// 使用便捷宏
rust_log_warn!("[RenderLoop] ⚠️ terminal {} not found", terminal_id);
rust_log_error!("[RenderLoop] ❌ Failed to create DisplayLink: {}", result);

// 或直接调用函数
log_message(RustLogLevel::Error, &format!("error: {}", msg));
```

### Swift 端查看日志

日志会自动写入 LogManager 的日志文件：
```
~/Library/Application Support/ETerm/logs/debug-YYYY-MM-DD.log
```

可以通过 "Help → Export Bug Report" 导出日志文件。

## 线程安全

- Rust 端使用原子指针存储回调，线程安全
- Swift LogManager 使用串行队列，线程安全
- 回调可能从多个线程调用（主线程、VSync 线程等），但都是安全的

## 性能考虑

- 日志回调使用 `CString` 转换，有轻微性能开销
- 只在关键错误/警告点使用，不影响性能
- LogManager 使用异步队列写入，不阻塞调用线程

## 日志级别映射

| Rust           | Swift          | 用途                       |
|----------------|----------------|----------------------------|
| Debug          | debug          | 调试信息（通常不记录）     |
| Info           | info           | 一般信息（如渲染统计）     |
| Warn           | warn           | 警告（如 terminal 未找到） |
| Error          | error          | 错误（如 DisplayLink 失败）|

## 测试

```bash
# 编译 Rust 库
cd rio
cargo build -p sugarloaf-ffi --lib

# 运行 Swift App，检查日志文件
open ~/Library/Application\ Support/ETerm/logs/
```

## 未来改进

1. 添加日志过滤（只记录特定级别）
2. 支持结构化日志（JSON 格式）
3. 添加日志压缩/归档
4. 支持远程日志上传（用于诊断）
