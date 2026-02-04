//! FFI 类型定义
//!
//! C-compatible 类型，用于 Rust ↔ Swift 通信

use std::ffi::c_void;

// 重新导出根模块的常量，方便使用
pub use crate::DEFAULT_LINE_HEIGHT;

// ============================================================================
// 数据结构
// ============================================================================

/// 应用配置（C-compatible）
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AppConfig {
    // ===== 终端尺寸 =====
    pub cols: u16,
    pub rows: u16,

    // ===== 渲染配置 =====
    pub font_size: f32,
    pub line_height: f32,
    pub scale: f32,

    // ===== 窗口句柄 =====
    pub window_handle: *mut c_void,
    pub display_handle: *mut c_void,
    pub window_width: f32,
    pub window_height: f32,

    // ===== 历史行数 =====
    pub history_size: u32,

    // ===== 日志缓冲 (可选功能) =====
    /// 日志缓冲区大小（行数）
    /// - 0 = 禁用（默认，ETerm 使用）
    /// - >0 = 启用并设置最大行数（dev-runner 使用）
    pub log_buffer_size: u32,
}

/// 字体度量信息
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub baseline_offset: f32,
    pub line_height: f32,
}

/// 终端事件类型
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalEventType {
    Wakeup = 0,                   // 对应 Swift: case wakeup = 0
    Render = 1,                   // 对应 Swift: case render = 1
    CursorBlink = 2,              // 对应 Swift: case cursorBlink = 2
    Bell = 3,                     // 对应 Swift: case bell = 3
    TitleChanged = 4,             // 对应 Swift: case titleChanged = 4
    Damaged = 5,                  // 保留用于兼容
    CurrentDirectoryChanged = 6,  // OSC 7: 工作目录变化
    CommandExecuted = 7,          // OSC 133;C: 命令执行
}

/// 终端事件
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TerminalEvent {
    pub event_type: TerminalEventType,
    pub data: u64,
}

/// 网格坐标
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct GridPoint {
    pub col: u16,
    pub row: u16,
}

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

/// 事件回调类型
pub type TerminalPoolEventCallback = extern "C" fn(context: *mut c_void, event: TerminalEvent);

/// 字符串事件回调类型（用于携带字符串数据的事件）
///
/// 用于 CurrentDirectoryChanged、CommandExecuted 等需要传递字符串的事件
pub type TerminalPoolStringEventCallback = extern "C" fn(
    context: *mut c_void,
    event_type: TerminalEventType,
    terminal_id: usize,
    data: *const std::os::raw::c_char,
);
