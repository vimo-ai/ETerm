use sugarloaf::font::fonts::{SugarloafFonts, SugarloafFont, SugarloafFontStyle};
use sugarloaf::font::FontLibrary;
use std::sync::OnceLock;

// MCP Router Core 已改为独立 dylib，通过 Swift dlopen 动态加载
// 不再静态链接，避免多个 Rust staticlib 的符号冲突问题

// 同步原语（FairMutex, FairRwLock）
mod sync;
pub use sync::*;

mod fair_rwlock;
pub use fair_rwlock::FairRwLock;

// ============================================================================
// 全局共享 FontLibrary（所有 TerminalPool 共享同一个实例）
// ============================================================================

/// 全局 FontLibrary 单例
///
/// 字体库占用约 180MB 内存，通过全局共享避免重复加载
static GLOBAL_FONT_LIBRARY: OnceLock<FontLibrary> = OnceLock::new();

/// 获取全局共享的 FontLibrary
///
/// 首次调用会初始化字体库，后续调用返回同一实例的 clone（Arc 引用计数增加）
pub fn get_shared_font_library(font_size: f32) -> FontLibrary {
    GLOBAL_FONT_LIBRARY
        .get_or_init(|| {
            let font_spec = create_default_font_spec(font_size);
            let (font_library, _) = FontLibrary::new(font_spec);
            font_library
        })
        .clone()
}

// ============================================================================
// 全局常量
// ============================================================================

/// 默认行高倍数（1.0 = 无额外行间距）
///
/// 注意：line_height > 1.0 会在每行底部增加空白，导致行间缝隙
/// 建议使用 1.0 以获得最佳渲染效果
pub const DEFAULT_LINE_HEIGHT: f32 = 1.0;

/// 创建默认字体配置（Maple Mono NF CN + Apple Color Emoji）
///
/// 统一的字体配置入口，确保所有终端实例使用相同的字体设置
pub fn create_default_font_spec(font_size: f32) -> SugarloafFonts {
    SugarloafFonts {
        family: Some("Maple Mono NF CN".to_string()),
        size: font_size,
        hinting: true,
        regular: SugarloafFont {
            family: "MapleMono-NF-CN-Regular".to_string(),
            weight: Some(400),
            style: SugarloafFontStyle::Normal,
            width: None,
        },
        bold: SugarloafFont {
            family: "MapleMono-NF-CN-Bold".to_string(),
            weight: Some(700),
            style: SugarloafFontStyle::Normal,
            width: None,
        },
        italic: SugarloafFont {
            family: "MapleMono-NF-CN-Italic".to_string(),
            weight: Some(600),
            style: SugarloafFontStyle::Italic,
            width: None,
        },
        bold_italic: SugarloafFont {
            family: "MapleMono-NF-CN-BoldItalic".to_string(),
            weight: Some(700),
            style: SugarloafFontStyle::Italic,
            width: None,
        },
        // 🍎 启用 Apple Color Emoji（macOS 原生 emoji 支持）
        emoji: Some(SugarloafFont {
            family: "Apple Color Emoji".to_string(),
            weight: None,
            style: SugarloafFontStyle::Normal,
            width: None,
        }),
        ..Default::default()
    }
}

// ============================================================================
// 新架构模块（DDD 分层架构，使用 feature flag 隔离）
// ============================================================================

pub mod domain;

pub mod render;

pub mod app;

// 基础设施层（SPSC 队列等）
pub mod infra;

// CVDisplayLink Rust 绑定（macOS only）
#[cfg(target_os = "macos")]
pub mod display_link;

// FFI 模块（统一导出所有 FFI 接口）

pub mod ffi;

// Re-export FFI 符号，保持对外可见性

pub use ffi::*;

// ============================================================================
// 新的 Rio 风格实现
// ============================================================================

// Rio 事件系统
mod rio_event;
pub use rio_event::{EventCallback, EventQueue, FFIEvent, FFIEventListener, RioEvent, StringEventCallback};

// Rio Machine（照抄 Rio 的 PTY 事件循环）
mod rio_machine;
pub use rio_machine::Machine;

// 锁竞争测试（FairRwLock, resize 阻塞等）
#[cfg(test)]
mod lock_contention_test;


#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SugarloafFontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub line_height: f32,
}

/// 释放 Rust 分配的字符串
///
/// 用于释放 `terminal_pool_get_cwd` 等函数返回的字符串
#[no_mangle]
pub extern "C" fn rio_free_string(s: *mut std::ffi::c_char) {
    if !s.is_null() {
        unsafe {
            drop(std::ffi::CString::from_raw(s));
        }
    }
}
