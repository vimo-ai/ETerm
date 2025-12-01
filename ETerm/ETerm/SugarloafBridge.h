//
//  SugarloafBridge.h
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/16.
//

#ifndef SugarloafBridge_h
#define SugarloafBridge_h

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

// Opaque handle
typedef void* SugarloafHandle;

typedef struct {
    float cell_width;
    float cell_height;
    float line_height;
} SugarloafFontMetrics;

// Initialize Sugarloaf
SugarloafHandle sugarloaf_new(
    void* window_handle,
    void* display_handle,
    float width,
    float height,
    float scale,
    float font_size
);

// Content management
size_t sugarloaf_create_rich_text(SugarloafHandle handle);
void sugarloaf_content_sel(SugarloafHandle handle, size_t rt_id);
void sugarloaf_content_clear(SugarloafHandle handle);
void sugarloaf_content_new_line(SugarloafHandle handle);
void sugarloaf_content_add_text(
    SugarloafHandle handle,
    const char* text,
    float fg_r,
    float fg_g,
    float fg_b,
    float fg_a
);

// Add text with explicit width (for wide characters like CJK)
void sugarloaf_content_add_text_with_width(
    SugarloafHandle handle,
    const char* text,
    float fg_r,
    float fg_g,
    float fg_b,
    float fg_a,
    float width
);

// Add text with full styling (width, cursor)
void sugarloaf_content_add_text_styled(
    SugarloafHandle handle,
    const char* text,
    float fg_r,
    float fg_g,
    float fg_b,
    float fg_a,
    float width,
    bool has_cursor,
    float cursor_r,
    float cursor_g,
    float cursor_b,
    float cursor_a
);

// Add text with full styling (width, cursor, background color)
void sugarloaf_content_add_text_full(
    SugarloafHandle handle,
    const char* text,
    float fg_r,
    float fg_g,
    float fg_b,
    float fg_a,
    bool has_bg,
    float bg_r,
    float bg_g,
    float bg_b,
    float bg_a,
    float width,
    bool has_cursor,
    float cursor_r,
    float cursor_g,
    float cursor_b,
    float cursor_a
);

// Add text with full styling including text decorations (bold, italic, underline, etc.)
// flags bit mask:
//   0x0002 = BOLD
//   0x0004 = ITALIC
//   0x0008 = UNDERLINE
//   0x0080 = DIM
//   0x0200 = STRIKEOUT
//   0x0800 = DOUBLE_UNDERLINE
//   0x1000 = UNDERCURL
//   0x2000 = DOTTED_UNDERLINE
//   0x4000 = DASHED_UNDERLINE
void sugarloaf_content_add_text_decorated(
    SugarloafHandle handle,
    const char* text,
    float fg_r,
    float fg_g,
    float fg_b,
    float fg_a,
    bool has_bg,
    float bg_r,
    float bg_g,
    float bg_b,
    float bg_a,
    float width,
    bool has_cursor,
    float cursor_r,
    float cursor_g,
    float cursor_b,
    float cursor_a,
    uint32_t flags
);

void sugarloaf_content_build(SugarloafHandle handle);
void sugarloaf_commit_rich_text(SugarloafHandle handle, size_t rt_id);

/// Commit rich text at specified position (logical coordinates)
/// x, y: position in points (not physical pixels)
void sugarloaf_commit_rich_text_at(SugarloafHandle handle, size_t rt_id, float x, float y);

// ===== Multi-Terminal Rendering API (Accumulate + Flush) =====

/// Clear pending objects list (call at the start of each frame)
void sugarloaf_clear_objects(SugarloafHandle handle);

/// Add RichText to pending list (call for each terminal)
/// rt_id: RichText ID (created via sugarloaf_create_rich_text)
/// x, y: render position (logical coordinates, Y from top)
void sugarloaf_add_rich_text(SugarloafHandle handle, size_t rt_id, float x, float y);

/// Flush all accumulated objects and render (call at the end of each frame)
void sugarloaf_flush_and_render(SugarloafHandle handle);

// Rendering
void sugarloaf_clear(SugarloafHandle handle);
void sugarloaf_set_test_objects(SugarloafHandle handle);
void sugarloaf_render(SugarloafHandle handle);
void sugarloaf_render_demo(SugarloafHandle handle);
void sugarloaf_render_demo_with_rich_text(SugarloafHandle handle, size_t rich_text_id);

bool sugarloaf_get_font_metrics(SugarloafHandle handle, SugarloafFontMetrics* out_metrics);

// Resize Sugarloaf rendering surface
void sugarloaf_resize(SugarloafHandle handle, float width, float height);

// Rescale Sugarloaf (for DPI changes)
void sugarloaf_rescale(SugarloafHandle handle, float scale);

// Font size operations
// operation: 0 = Reset, 1 = Decrease, 2 = Increase
void sugarloaf_change_font_size(
    SugarloafHandle handle,
    size_t rich_text_id,
    unsigned char operation
);

// Cleanup
void sugarloaf_free(SugarloafHandle handle);

// =============================================================================
// Rio Terminal Pool API - 照抄 Rio 的事件系统
// =============================================================================
//
// 这是一个全新的实现，照抄 Rio 的事件系统：
// - FFIEvent 结构传递事件类型和参数
// - EventCallback 在 PTY 线程中被调用
// - Swift 侧有事件队列消费事件

typedef void* RioTerminalPoolHandle;

// FFI 事件类型
typedef struct {
    uint32_t event_type;    // 0=Wakeup, 1=Render, 2=CursorBlinkingChange, 3=Bell, 8=Exit, etc.
    size_t route_id;        // 终端 ID
    int32_t scroll_delta;   // 滚动量（用于 Scroll 事件）
} FFIEvent;

// 终端快照 - 一次性获取所有渲染需要的状态
typedef struct {
    size_t display_offset;      // 滚动偏移
    size_t scrollback_lines;    // 历史缓冲区行数
    int blinking_cursor;        // 光标是否闪烁
    size_t cursor_col;          // 光标列
    size_t cursor_row;          // 光标行（相对于可见区域）
    uint8_t cursor_shape;       // 光标形状 (0=Block, 1=Underline, 2=Beam, 3=Hidden)
    int cursor_visible;         // 光标是否可见
    size_t columns;             // 列数
    size_t screen_lines;        // 行数
    int has_selection;          // 是否有选区
    size_t selection_start_col; // 选区开始列
    int32_t selection_start_row;// 选区开始行
    size_t selection_end_col;   // 选区结束列
    int32_t selection_end_row;  // 选区结束行
} TerminalSnapshot;

// 单个单元格 - FFI 友好的结构
typedef struct {
    uint32_t character;     // UTF-32 字符
    uint8_t fg_r;           // 前景色 R
    uint8_t fg_g;           // 前景色 G
    uint8_t fg_b;           // 前景色 B
    uint8_t fg_a;           // 前景色 A
    uint8_t bg_r;           // 背景色 R
    uint8_t bg_g;           // 背景色 G
    uint8_t bg_b;           // 背景色 B
    uint8_t bg_a;           // 背景色 A
    uint32_t flags;         // 标志位
    bool has_vs16;          // 是否有 VS16 (U+FE0F) emoji 变体选择符
} FFICell;

// 事件回调类型
typedef void (*EventCallback)(void* context, FFIEvent event);
typedef void (*StringEventCallback)(void* context, uint32_t event_type, const char* str);

/// 创建 Rio 风格终端池
RioTerminalPoolHandle rio_pool_new(SugarloafHandle sugarloaf);

/// 创建独立终端池（不需要 Sugarloaf，用于 Skia 渲染器）
RioTerminalPoolHandle rio_pool_new_headless(void);

/// 设置事件回调
void rio_pool_set_event_callback(
    RioTerminalPoolHandle pool,
    EventCallback callback,
    StringEventCallback string_callback,  // 可以为 NULL
    void* context
);

/// 创建终端（返回 terminal_id，失败返回 -1）
int rio_pool_create_terminal(
    RioTerminalPoolHandle pool,
    unsigned short cols,
    unsigned short rows,
    const char* shell
);

/// 创建终端（指定工作目录，返回 terminal_id，失败返回 -1）
int rio_pool_create_terminal_with_cwd(
    RioTerminalPoolHandle pool,
    unsigned short cols,
    unsigned short rows,
    const char* shell,
    const char* working_dir
);

/// 关闭终端
int rio_pool_close_terminal(
    RioTerminalPoolHandle pool,
    size_t terminal_id
);

/// 终端数量
size_t rio_pool_count(RioTerminalPoolHandle pool);

/// 写入输入
int rio_pool_write_input(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    const char* data
);

/// 调整尺寸
int rio_pool_resize(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short cols,
    unsigned short rows
);

/// 滚动
int rio_pool_scroll(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    int delta
);

/// 获取终端快照
int rio_pool_get_snapshot(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    TerminalSnapshot* out_snapshot
);

/// 获取指定行的单元格数据（支持历史缓冲区）
///
/// 绝对行号坐标系统：
/// - 0 到 (scrollback_lines - 1): 历史缓冲区
/// - scrollback_lines 到 (scrollback_lines + screen_lines - 1): 屏幕可见行
///
/// 参数：
/// - absolute_row: 绝对行号（0-based，包含历史缓冲区）
/// - out_cells: 输出缓冲区
/// - max_cells: 缓冲区最大容量
///
/// 返回：实际写入的单元格数量
size_t rio_pool_get_row_cells(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    int64_t absolute_row,
    FFICell* out_cells,
    size_t max_cells
);

/// 获取光标位置
int rio_pool_get_cursor(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short* out_col,
    unsigned short* out_row
);

/// 清除选区
int rio_pool_clear_selection(
    RioTerminalPoolHandle pool,
    size_t terminal_id
);

/// 获取选中的文本
/// 直接使用当前 terminal.selection，不需要传入坐标参数
/// 返回需要用 rio_free_string 释放的字符串
char* rio_pool_get_selected_text(
    RioTerminalPoolHandle pool,
    size_t terminal_id
);

/// 获取终端当前工作目录（返回需要用 rio_free_string 释放的字符串）
char* rio_pool_get_cwd(
    RioTerminalPoolHandle pool,
    size_t terminal_id
);

// =============================================================================
// 坐标转换 API - 支持真实行号（绝对坐标系统）
// =============================================================================

/// 绝对坐标（真实行号）
typedef struct {
    int64_t absolute_row;  // 真实行号（可能为负数）
    size_t col;            // 列号
} AbsolutePosition;

/// 屏幕坐标 → 真实行号
///
/// 参数：
///   screen_row: 相对于当前可见区域的行号（0-based）
///   screen_col: 列号
/// 返回：
///   真实行号坐标
AbsolutePosition rio_pool_screen_to_absolute(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    size_t screen_row,
    size_t screen_col
);

/// 设置选区
///
/// 参数：
///   start_absolute_row: 起始真实行号
///   start_col: 起始列号
///   end_absolute_row: 结束真实行号
///   end_col: 结束列号
///
/// 注意：Rust 内部会转换为 Grid 坐标
/// 返回：成功返回 0，失败返回 -1
int rio_pool_set_selection(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    int64_t start_absolute_row,
    size_t start_col,
    int64_t end_absolute_row,
    size_t end_col
);

/// 释放从 Rust 返回的字符串
void rio_free_string(char* s);

/// 释放终端池
void rio_pool_free(RioTerminalPoolHandle pool);

#endif /* SugarloafBridge_h */
