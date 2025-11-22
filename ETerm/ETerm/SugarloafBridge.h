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
void sugarloaf_content_build(SugarloafHandle handle);
void sugarloaf_commit_rich_text(SugarloafHandle handle, size_t rt_id);

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

// ===== Terminal API =====
typedef void* TerminalHandle;

// Terminal cell data structure
typedef struct {
    unsigned int c;      // UTF-32 character
    unsigned char fg_r;  // Foreground red
    unsigned char fg_g;  // Foreground green
    unsigned char fg_b;  // Foreground blue
    unsigned char bg_r;  // Background red
    unsigned char bg_g;  // Background green
    unsigned char bg_b;  // Background blue
} TerminalCell;

// Create a terminal with PTY
TerminalHandle terminal_create(
    unsigned short cols,
    unsigned short rows,
    const char* shell_program
);

// Read output from PTY (non-blocking, returns true if data was read)
int terminal_read_output(TerminalHandle handle);

// Write input to PTY (keyboard input)
int terminal_write_input(TerminalHandle handle, const char* data);

// Get terminal content as text string
size_t terminal_get_content(
    TerminalHandle handle,
    char* buffer,
    size_t buffer_size
);

// Get history size (scrollback buffer lines)
size_t terminal_get_history_size(TerminalHandle handle);

// Get cell data at specific position (with colors)
int terminal_get_cell(
    TerminalHandle handle,
    unsigned short row,
    unsigned short col,
    TerminalCell* out_cell
);

// Get cell data with scroll support (row can be negative for history)
int terminal_get_cell_with_scroll(
    TerminalHandle handle,
    int row,
    unsigned short col,
    TerminalCell* out_cell
);

// Get cursor position
int terminal_get_cursor(
    TerminalHandle handle,
    unsigned short* out_row,
    unsigned short* out_col
);

// Resize terminal
int terminal_resize(
    TerminalHandle handle,
    unsigned short cols,
    unsigned short rows
);

// Free terminal
void terminal_free(TerminalHandle handle);

// Scroll terminal view (positive = scroll up/history, negative = scroll down/bottom)
int terminal_scroll(TerminalHandle handle, int delta_lines);

// Render terminal to Sugarloaf (uses visible_rows API)
int terminal_render_to_sugarloaf(
    TerminalHandle handle,
    SugarloafHandle sugarloaf,
    size_t rich_text_id
);

// ===== Tab Manager API =====
typedef void* TabManagerHandle;

// 渲染回调函数类型
typedef void (*RenderCallback)(void* context);

// Create tab manager
TabManagerHandle tab_manager_new(
    SugarloafHandle sugarloaf,
    unsigned short cols,
    unsigned short rows,
    const char* shell_program
);

// Set render callback (called from PTY read thread when data arrives)
void tab_manager_set_render_callback(
    TabManagerHandle manager,
    RenderCallback callback,
    void* context
);

// Create a new tab (returns tab_id or -1 on failure)
int tab_manager_create_tab(TabManagerHandle manager);

// Switch to a specific tab
int tab_manager_switch_tab(TabManagerHandle manager, size_t tab_id);

// Close a specific tab
int tab_manager_close_tab(TabManagerHandle manager, size_t tab_id);

// Get active tab ID (returns -1 if no active tab)
int tab_manager_get_active_tab(TabManagerHandle manager);

// Read output from all tabs (updates all terminal states)
int tab_manager_read_all_tabs(TabManagerHandle manager);

// Render the currently active tab
int tab_manager_render_active_tab(TabManagerHandle manager);

// Write input to the active tab
int tab_manager_write_input(TabManagerHandle manager, const char* data);

// Scroll the active tab
int tab_manager_scroll_active_tab(TabManagerHandle manager, int delta_lines);

// Scroll a specific pane (without changing focus) - for mouse position scrolling
// Returns 0 on failure, non-zero on success
int tab_manager_scroll_pane(
    TabManagerHandle manager,
    size_t pane_id,
    int delta_lines
);

// Resize all tabs
int tab_manager_resize_all_tabs(
    TabManagerHandle manager,
    unsigned short cols,
    unsigned short rows
);

// Get tab count
size_t tab_manager_get_tab_count(TabManagerHandle manager);

// Get all tab IDs
size_t tab_manager_get_tab_ids(
    TabManagerHandle manager,
    size_t* out_ids,
    size_t max_count
);

// Set tab title
int tab_manager_set_tab_title(
    TabManagerHandle manager,
    size_t tab_id,
    const char* title
);

// Get tab title
int tab_manager_get_tab_title(
    TabManagerHandle manager,
    size_t tab_id,
    char* buffer,
    size_t buffer_size
);

// Free tab manager
void tab_manager_free(TabManagerHandle manager);

// ===== Split Pane API（已废弃，Swift 负责 Split 逻辑）=====

// ❌ 已删除：这些函数已从 Rust FFI 中移除
// int tab_manager_split_right(TabManagerHandle manager);
// int tab_manager_split_down(TabManagerHandle manager);
// int tab_manager_close_pane(TabManagerHandle manager, size_t pane_id);

// ✅ 保留：设置激活 pane
int tab_manager_set_active_pane(TabManagerHandle manager, size_t pane_id);

// ✅ 保留：获取 pane 数量
size_t tab_manager_get_pane_count(TabManagerHandle manager);

// ❌ 已删除：这些函数已从 Rust FFI 中移除
// int tab_manager_get_pane_at_position(TabManagerHandle manager, float x, float y);
// typedef struct PaneInfo { ... };
// int tab_manager_get_pane_info(TabManagerHandle manager, size_t pane_id, PaneInfo* out_info);

// ===== Divider Resizing API（已废弃）=====

// ❌ 已删除：分隔线相关函数已从 Rust FFI 中移除
// typedef struct DividerInfo { ... };
// size_t tab_manager_get_dividers(...);
// int tab_manager_resize_divider(...);

// ===== Text Selection API =====

// Selection type
typedef enum {
    SelectionTypeSimple = 0,    // Normal drag selection
    SelectionTypeSemantic = 1,  // Word selection (double-click)
    SelectionTypeLines = 2,     // Line selection (triple-click)
} SelectionType;

// Start text selection in the active pane
// col, row are in terminal grid coordinates (not pixels)
// Returns 0 on failure, non-zero on success
int tab_manager_start_selection(
    TabManagerHandle manager,
    unsigned short col,
    unsigned short row,
    SelectionType type
);

// Update selection end point in the active pane
// col, row are in terminal grid coordinates
// Returns 0 on failure, non-zero on success
int tab_manager_update_selection(
    TabManagerHandle manager,
    unsigned short col,
    unsigned short row
);

// Clear selection in the active pane
void tab_manager_clear_selection(TabManagerHandle manager);

// Get selected text from the active pane
// Returns the number of bytes written to buffer (excluding null terminator)
size_t tab_manager_get_selected_text(
    TabManagerHandle manager,
    char* buffer,
    size_t buffer_size
);

// ===== 新的 Panel 配置 API =====

// ❌ 已删除：Swift 负责创建 Panel
// size_t tab_manager_create_panel(TabManagerHandle manager, unsigned short cols, unsigned short rows);

// 🧪 测试函数：在四个角创建测试 pane
void tab_manager_test_corner_panes(
    TabManagerHandle manager,
    float container_width,
    float container_height
);

// ✅ 更新 Panel 的渲染配置（位置、尺寸、网格大小）
// 返回 1 成功，0 失败
int tab_manager_update_panel_config(
    TabManagerHandle manager,
    size_t panel_id,
    float x,           // 左上角 x（物理像素，Rust 坐标系）
    float y,           // 左上角 y（物理像素，Rust 坐标系）
    float width,       // 宽度（物理像素）
    float height,      // 高度（物理像素）
    unsigned short cols,
    unsigned short rows
);

// =============================================================================
// 新架构：Terminal Pool API - 简化的终端池
// =============================================================================

typedef void* TerminalPoolHandle;

/// 创建终端池
TerminalPoolHandle terminal_pool_new(SugarloafHandle sugarloaf);

/// 设置渲染回调
void terminal_pool_set_render_callback(
    TerminalPoolHandle pool,
    RenderCallback callback,
    void* context
);

/// 创建终端（返回 terminal_id，失败返回 -1）
int terminal_pool_create_terminal(
    TerminalPoolHandle pool,
    unsigned short cols,
    unsigned short rows,
    const char* shell
);

/// 关闭终端
int terminal_pool_close_terminal(
    TerminalPoolHandle pool,
    size_t terminal_id
);

/// 读取所有终端的 PTY 输出
int terminal_pool_read_all(TerminalPoolHandle pool);

/// 渲染指定终端到指定位置
/// x, y: 左上角位置（Rust 坐标系，左上角为原点）
/// width, height: 渲染区域尺寸
/// cols, rows: 终端网格大小
int terminal_pool_render(
    TerminalPoolHandle pool,
    size_t terminal_id,
    float x,
    float y,
    float width,
    float height,
    unsigned short cols,
    unsigned short rows
);

/// 写入输入到指定终端
int terminal_pool_write_input(
    TerminalPoolHandle pool,
    size_t terminal_id,
    const char* data
);

/// 滚动指定终端
int terminal_pool_scroll(
    TerminalPoolHandle pool,
    size_t terminal_id,
    int delta_lines
);

/// 调整指定终端尺寸
int terminal_pool_resize(
    TerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short cols,
    unsigned short rows
);

/// 获取终端数量
size_t terminal_pool_count(TerminalPoolHandle pool);

/// 统一提交所有累积的 objects
/// 在所有 render() 调用完成后，调用此函数统一提交所有终端的渲染内容
void terminal_pool_flush(TerminalPoolHandle pool);

/// 释放终端池
void terminal_pool_free(TerminalPoolHandle pool);

// =============================================================================
// TerminalPool 光标上下文 API (Cursor Context API for Pool)
// =============================================================================

/// 设置指定终端的选中范围（用于高亮渲染）
int terminal_pool_set_selection(
    TerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short start_row,
    unsigned short start_col,
    unsigned short end_row,
    unsigned short end_col
);

/// 清除指定终端的选中高亮
int terminal_pool_clear_selection(
    TerminalPoolHandle pool,
    size_t terminal_id
);

/// 获取指定终端的选中文本
int terminal_pool_get_text_range(
    TerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short start_row,
    unsigned short start_col,
    unsigned short end_row,
    unsigned short end_col,
    char* out_buffer,
    size_t buffer_size
);

/// 获取指定终端的当前输入行号
int terminal_pool_get_input_row(
    TerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short* out_row
);

/// 调整所有终端的字体大小
/// operation: 0 = Reset, 1 = Decrease, 2 = Increase
void terminal_pool_change_font_size(
    TerminalPoolHandle pool,
    unsigned char operation
);

// =============================================================================
// 单终端光标上下文 API (Cursor Context API for Single Terminal)
// =============================================================================

/// 获取指定范围的文本（支持多行、UTF-8、emoji）
/// 用于获取选中范围的文本内容
int terminal_get_text_range(
    TerminalHandle handle,
    unsigned short start_row,
    unsigned short start_col,
    unsigned short end_row,
    unsigned short end_col,
    char* out_buffer,
    size_t buffer_size
);

/// 直接删除指定范围的文本（仅对当前输入行有效）
/// 用于"选中在输入行时，输入替换选中"的功能
int terminal_delete_range(
    TerminalHandle handle,
    unsigned short start_row,
    unsigned short start_col,
    unsigned short end_row,
    unsigned short end_col
);

/// 获取当前输入行号
/// 返回 1 并填充 out_row，如果当前在输入模式
/// 返回 0 如果不在输入模式（如 vim/less）
int terminal_get_input_row(
    TerminalHandle handle,
    unsigned short* out_row
);

/// 设置选中范围（用于高亮渲染）
/// Swift 调用此函数告诉 Rust 当前的选中范围，Rust 负责渲染高亮背景
int terminal_set_selection(
    TerminalHandle handle,
    unsigned short start_row,
    unsigned short start_col,
    unsigned short end_row,
    unsigned short end_col
);

/// 清除选中高亮
int terminal_clear_selection_highlight(TerminalHandle handle);

#endif /* SugarloafBridge_h */
