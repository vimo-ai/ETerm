# FFI 接口设计文档

**版本**: 1.0
**日期**: 2025-12-04
**目标**: 定义 Rust (TerminalApp) 和 Swift 之间的 FFI 契约

---

## 设计原则

1. **Rust 管完整渲染**：Rust 端负责从 Terminal → Render → Metal，Swift 只管窗口和事件
2. **批量操作**：减少 FFI 调用次数，提高性能
3. **安全第一**：明确内存管理责任，避免悬垂指针
4. **错误处理**：使用返回值和错误码，不使用异常

---

## 核心数据结构

### 1. TerminalAppHandle（不透明指针）

```rust
/// 终端应用句柄（不透明指针，Swift 不可见内部结构）
#[repr(C)]
pub struct TerminalAppHandle {
    _private: [u8; 0],  // 零大小类型，防止实例化
}
```

**内存管理**：
- 由 `terminal_app_create()` 分配
- 由 `terminal_app_destroy()` 释放
- Swift 只持有指针，不负责内存管理

---

### 2. AppConfig（配置结构）

```rust
/// 应用配置（C-compatible）
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AppConfig {
    // ===== 终端尺寸 =====
    pub cols: u16,           // 列数
    pub rows: u16,           // 行数

    // ===== 渲染配置 =====
    pub font_size: f32,      // 字体大小（pt）
    pub line_height: f32,    // 行高倍数（如 1.2）
    pub scale: f32,          // DPI 缩放（如 2.0 for Retina）

    // ===== 窗口句柄 =====
    pub window_handle: *mut c_void,   // NSWindow
    pub display_handle: *mut c_void,  // NSView（Metal layer 的父视图）
    pub window_width: f32,            // 窗口宽度（物理像素）
    pub window_height: f32,           // 窗口高度（物理像素）

    // ===== 历史行数 =====
    pub history_size: u32,   // 回滚历史行数（默认 10000）
}
```

---

### 3. FontMetrics（字体度量）

```rust
/// 字体度量信息
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FontMetrics {
    pub cell_width: f32,       // 单元格宽度（px）
    pub cell_height: f32,      // 单元格高度（px）
    pub baseline_offset: f32,  // 基线偏移（px）
    pub line_height: f32,      // 行高（px）
}
```

---

### 4. TerminalEvent（事件类型）

```rust
/// 终端事件（传递给 Swift）
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub enum TerminalEventType {
    CursorBlink = 0,      // 光标闪烁
    Bell = 1,             // 响铃
    TitleChanged = 2,     // 标题改变
    Damaged = 3,          // 内容变化（需要重绘）
}

#[repr(C)]
pub struct TerminalEvent {
    pub event_type: TerminalEventType,
    pub data: u64,  // 事件相关数据（如行号）
}
```

---

### 5. GridPoint（坐标）

```rust
/// 网格坐标（用于选区、搜索）
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct GridPoint {
    pub col: u16,  // 列（0-based）
    pub row: u16,  // 行（0-based，0 = 屏幕顶部）
}
```

---

### 6. ErrorCode（错误码）

```rust
/// FFI 错误码
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    Success = 0,
    NullPointer = 1,
    InvalidConfig = 2,
    InvalidUtf8 = 3,
    RenderError = 4,
    OutOfBounds = 5,
}
```

---

## FFI 函数签名

### 1. 生命周期管理

#### 创建终端应用

```rust
/// 创建终端应用实例
///
/// 参数：
/// - config: 应用配置（包含窗口句柄、终端尺寸、字体配置等）
///
/// 返回：
/// - 成功：TerminalAppHandle 指针（非空）
/// - 失败：null
///
/// 内存：由 Rust 分配，必须调用 terminal_app_destroy() 释放
#[no_mangle]
pub extern "C" fn terminal_app_create(
    config: AppConfig,
) -> *mut TerminalAppHandle;
```

#### 销毁终端应用

```rust
/// 销毁终端应用实例
///
/// 参数：
/// - handle: 终端应用句柄（由 terminal_app_create 返回）
///
/// 注意：
/// - handle 必须非空且有效
/// - 调用后 handle 失效，不可再使用
/// - 幂等性：对同一 handle 多次调用是未定义行为
#[no_mangle]
pub extern "C" fn terminal_app_destroy(
    handle: *mut TerminalAppHandle,
);
```

---

### 2. 核心功能

#### 写入数据（PTY → Terminal）

```rust
/// 写入数据到终端（PTY 输出）
///
/// 参数：
/// - handle: 终端应用句柄
/// - data: 数据指针（UTF-8 字节）
/// - len: 数据长度
///
/// 返回：
/// - Success: 写入成功
/// - NullPointer: handle 或 data 为空
/// - InvalidUtf8: 数据不是有效的 UTF-8（警告，会尝试恢复）
///
/// 线程安全：可以从任意线程调用（内部加锁）
#[no_mangle]
pub extern "C" fn terminal_app_write(
    handle: *mut TerminalAppHandle,
    data: *const u8,
    len: usize,
) -> ErrorCode;
```

#### 渲染（批量渲染所有行）

```rust
/// 渲染终端到 Metal
///
/// 参数：
/// - handle: 终端应用句柄
///
/// 返回：
/// - Success: 渲染成功
/// - NullPointer: handle 为空
/// - RenderError: 渲染失败
///
/// 行为：
/// 1. 从 Terminal 获取 TerminalState
/// 2. 使用 Renderer 批量渲染所有可见行
/// 3. 写入 Sugarloaf buffer
/// 4. 调用 sugarloaf.render() → wgpu → Metal
///
/// 性能：约 1-2ms（60 FPS 足够）
#[no_mangle]
pub extern "C" fn terminal_app_render(
    handle: *mut TerminalAppHandle,
) -> ErrorCode;
```

#### 调整大小

```rust
/// 调整终端尺寸
///
/// 参数：
/// - handle: 终端应用句柄
/// - cols: 新的列数
/// - rows: 新的行数
///
/// 返回：
/// - Success: 调整成功
/// - NullPointer: handle 为空
/// - InvalidConfig: cols 或 rows 无效（如 0 或超过限制）
///
/// 副作用：
/// - 清空渲染缓存
/// - 触发 PTY resize
/// - 触发 Damaged 事件
#[no_mangle]
pub extern "C" fn terminal_app_resize(
    handle: *mut TerminalAppHandle,
    cols: u16,
    rows: u16,
) -> ErrorCode;
```

---

### 3. 交互功能

#### 选区

```rust
/// 开始选区
#[no_mangle]
pub extern "C" fn terminal_app_start_selection(
    handle: *mut TerminalAppHandle,
    point: GridPoint,
) -> ErrorCode;

/// 更新选区
#[no_mangle]
pub extern "C" fn terminal_app_update_selection(
    handle: *mut TerminalAppHandle,
    point: GridPoint,
) -> ErrorCode;

/// 清除选区
#[no_mangle]
pub extern "C" fn terminal_app_clear_selection(
    handle: *mut TerminalAppHandle,
) -> ErrorCode;

/// 获取选区文本
///
/// 参数：
/// - handle: 终端应用句柄
/// - out_buffer: 输出缓冲区（由 Swift 分配）
/// - buffer_len: 缓冲区长度
/// - out_written: 实际写入的字节数（可选，可为 null）
///
/// 返回：
/// - Success: 成功
/// - NullPointer: handle 或 out_buffer 为空
/// - OutOfBounds: 缓冲区太小
///
/// 示例（Swift）：
/// ```swift
/// var buffer = [UInt8](repeating: 0, count: 4096)
/// var written: size_t = 0
/// let result = terminal_app_get_selection_text(handle, &buffer, 4096, &written)
/// let text = String(bytes: buffer[0..<written], encoding: .utf8)
/// ```
#[no_mangle]
pub extern "C" fn terminal_app_get_selection_text(
    handle: *mut TerminalAppHandle,
    out_buffer: *mut u8,
    buffer_len: usize,
    out_written: *mut usize,
) -> ErrorCode;
```

#### 搜索

```rust
/// 搜索文本
///
/// 参数：
/// - pattern: 搜索模式（C 字符串，UTF-8）
///
/// 返回匹配数量（0 表示无匹配）
#[no_mangle]
pub extern "C" fn terminal_app_search(
    handle: *mut TerminalAppHandle,
    pattern: *const c_char,
) -> usize;

/// 下一个匹配
#[no_mangle]
pub extern "C" fn terminal_app_next_match(
    handle: *mut TerminalAppHandle,
) -> bool;

/// 上一个匹配
#[no_mangle]
pub extern "C" fn terminal_app_prev_match(
    handle: *mut TerminalAppHandle,
) -> bool;

/// 清除搜索
#[no_mangle]
pub extern "C" fn terminal_app_clear_search(
    handle: *mut TerminalAppHandle,
) -> ErrorCode;
```

#### 滚动

```rust
/// 滚动终端
///
/// 参数：
/// - delta: 滚动行数（正数向上，负数向下）
#[no_mangle]
pub extern "C" fn terminal_app_scroll(
    handle: *mut TerminalAppHandle,
    delta: i32,
) -> ErrorCode;

/// 滚动到顶部
#[no_mangle]
pub extern "C" fn terminal_app_scroll_to_top(
    handle: *mut TerminalAppHandle,
) -> ErrorCode;

/// 滚动到底部
#[no_mangle]
pub extern "C" fn terminal_app_scroll_to_bottom(
    handle: *mut TerminalAppHandle,
) -> ErrorCode;
```

---

### 4. 配置和状态

#### 重新配置

```rust
/// 重新配置（动态调整字体、DPI 等）
///
/// 副作用：清空渲染缓存
#[no_mangle]
pub extern "C" fn terminal_app_reconfigure(
    handle: *mut TerminalAppHandle,
    config: AppConfig,
) -> ErrorCode;
```

#### 获取字体度量

```rust
/// 获取字体度量
///
/// 参数：
/// - out_metrics: 输出指针（由 Swift 分配）
///
/// 返回：
/// - Success: 成功
/// - NullPointer: handle 或 out_metrics 为空
#[no_mangle]
pub extern "C" fn terminal_app_get_font_metrics(
    handle: *mut TerminalAppHandle,
    out_metrics: *mut FontMetrics,
) -> ErrorCode;
```

#### 事件轮询

```rust
/// 轮询事件（非阻塞）
///
/// 参数：
/// - out_events: 事件数组（由 Swift 分配）
/// - max_events: 数组容量
/// - out_count: 实际事件数量（可选）
///
/// 返回：
/// - Success: 成功
/// - NullPointer: handle 或 out_events 为空
///
/// 示例（Swift）：
/// ```swift
/// var events = [TerminalEvent](repeating: TerminalEvent(), count: 16)
/// var count: size_t = 0
/// terminal_app_poll_events(handle, &events, 16, &count)
/// for i in 0..<count {
///     handleEvent(events[i])
/// }
/// ```
#[no_mangle]
pub extern "C" fn terminal_app_poll_events(
    handle: *mut TerminalAppHandle,
    out_events: *mut TerminalEvent,
    max_events: usize,
    out_count: *mut usize,
) -> ErrorCode;
```

---

## 内存管理规则

### Rust 负责的内存

1. **TerminalAppHandle**：由 `terminal_app_create()` 分配，`terminal_app_destroy()` 释放
2. **内部状态**：Terminal、Renderer、Sugarloaf 等，随 handle 一起释放

### Swift 负责的内存

1. **输出缓冲区**：如 `get_selection_text()` 的 `out_buffer`
2. **事件数组**：如 `poll_events()` 的 `out_events`
3. **配置结构**：`AppConfig` 是值类型，栈上分配

### 共享规则

- **字符串**：
  - Swift → Rust：传递 `*const c_char`（C 字符串），Rust 只读
  - Rust → Swift：写入 Swift 提供的缓冲区
- **指针生命周期**：
  - 传入的指针在函数调用期间有效
  - 不保存传入的指针（除非明确说明，如 window_handle）

---

## 错误处理策略

### 返回值约定

1. **指针返回**：`null` 表示失败（如 `terminal_app_create()`）
2. **ErrorCode 返回**：`Success = 0` 表示成功，非零表示错误
3. **数值返回**：`0` 表示失败（如 `terminal_app_search()` 返回匹配数量）
4. **bool 返回**：`true` 成功，`false` 失败（如 `next_match()`）

### 错误日志

- Rust 内部使用 `eprintln!` 输出错误日志
- Swift 侧检查返回值，必要时弹出警告

---

## 性能考量

### 批量操作

- `terminal_app_render()` 一次渲染所有行，减少 FFI 调用
- `terminal_app_poll_events()` 批量返回事件，减少轮询次数

### 零拷贝

- `terminal_app_write()` 直接解析 UTF-8 字节，不拷贝
- `terminal_app_render()` 使用缓存，避免重复渲染

### 缓存策略

- 字体度量缓存：首次计算后缓存
- 渲染缓存：两层 Hash 缓存（text_hash + state_hash）

---

## 线程安全

### 单线程模型

- TerminalApp 本身**不是线程安全的**
- Swift 必须从**同一线程**调用所有 FFI 函数（通常是主线程）

### 例外：`terminal_app_write()`

- 可以从任意线程调用（如 PTY 读取线程）
- 内部使用锁保护

---

## Swift 集成示例

```swift
class TerminalAppWrapper {
    private var handle: OpaquePointer?

    init?(config: AppConfig) {
        handle = terminal_app_create(config)
        guard handle != nil else {
            return nil
        }
    }

    deinit {
        if let handle = handle {
            terminal_app_destroy(handle)
        }
    }

    func write(data: Data) -> Bool {
        guard let handle = handle else { return false }
        return data.withUnsafeBytes { ptr in
            let result = terminal_app_write(handle, ptr.baseAddress, data.count)
            return result == ErrorCode.Success
        }
    }

    func render() -> Bool {
        guard let handle = handle else { return false }
        let result = terminal_app_render(handle)
        return result == ErrorCode.Success
    }

    func resize(cols: UInt16, rows: UInt16) -> Bool {
        guard let handle = handle else { return false }
        let result = terminal_app_resize(handle, cols, rows)
        return result == ErrorCode.Success
    }

    func getSelectionText() -> String? {
        guard let handle = handle else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var written: size_t = 0
        let result = terminal_app_get_selection_text(handle, &buffer, 4096, &written)
        guard result == ErrorCode.Success else { return nil }
        return String(bytes: buffer[0..<written], encoding: .utf8)
    }
}
```

---

## 下一步

1. ✅ FFI 接口设计完成（本文档）
2. ⏳ 实现 Application Layer (TerminalApp) - Step 4.2
3. ⏳ 实现 FFI 导出函数 - Step 4.3
4. ⏳ 编写 Rust 端到端测试 - Step 4.4
5. ⏳ Swift 侧集成 - Step 5.x

---

## 附录：完整类型定义

```rust
// app/ffi.rs
use std::ffi::{c_char, c_void};

#[repr(C)]
pub struct TerminalAppHandle {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AppConfig {
    pub cols: u16,
    pub rows: u16,
    pub font_size: f32,
    pub line_height: f32,
    pub scale: f32,
    pub window_handle: *mut c_void,
    pub display_handle: *mut c_void,
    pub window_width: f32,
    pub window_height: f32,
    pub history_size: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub baseline_offset: f32,
    pub line_height: f32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub enum TerminalEventType {
    CursorBlink = 0,
    Bell = 1,
    TitleChanged = 2,
    Damaged = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TerminalEvent {
    pub event_type: TerminalEventType,
    pub data: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct GridPoint {
    pub col: u16,
    pub row: u16,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    Success = 0,
    NullPointer = 1,
    InvalidConfig = 2,
    InvalidUtf8 = 3,
    RenderError = 4,
    OutOfBounds = 5,
}
```

---

**结束**
