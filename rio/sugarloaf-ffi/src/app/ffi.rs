//! FFI 类型定义
//!
//! C-compatible 类型，用于 Rust ↔ Swift 通信

use std::ffi::c_void;

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
    CursorBlink = 0,
    Bell = 1,
    TitleChanged = 2,
    Damaged = 3,
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
pub type TerminalAppEventCallback = extern "C" fn(context: *mut c_void, event: TerminalEvent);
