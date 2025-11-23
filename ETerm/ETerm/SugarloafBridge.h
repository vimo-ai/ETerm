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

/// 获取指定终端的光标位置
int terminal_pool_get_cursor(
    TerminalPoolHandle pool,
    size_t terminal_id,
    unsigned short* out_col,
    unsigned short* out_row
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

// =============================================================================
// 事件驱动终端池 API (Event-Driven Terminal Pool API)
// =============================================================================
//
// 与普通的 TerminalPool 不同，这个池为每个终端创建独立的 PTY 事件线程。
// PTY 有数据时自动读取并触发渲染回调，无需 Swift 层轮询。
//
// 核心架构（参考 Rio）：
// 1. 每个终端一个独立的 PTY 事件线程（使用 corcovado 事件循环）
// 2. PTY 有数据时才读取，不用定时器轮询
// 3. 数据处理完成后通过回调通知 Swift 渲染
// 4. Swift 删除 CVDisplayLink 轮询，改为事件驱动渲染

typedef void* EventDrivenPoolHandle;

/// 创建事件驱动终端池
EventDrivenPoolHandle event_driven_pool_new(SugarloafHandle sugarloaf);

/// 设置 wakeup 回调（PTY 有数据时调用）
void event_driven_pool_set_wakeup_callback(
    EventDrivenPoolHandle pool,
    RenderCallback callback,
    void* context
);

/// 创建终端（返回 terminal_id，失败返回 -1）
int event_driven_pool_create_terminal(
    EventDrivenPoolHandle pool,
    unsigned short cols,
    unsigned short rows,
    const char* shell
);

/// 关闭终端
int event_driven_pool_close_terminal(
    EventDrivenPoolHandle pool,
    size_t terminal_id
);

/// 写入输入到指定终端（通过 channel 发送到 PTY 线程）
int event_driven_pool_write_input(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    const char* data
);

/// 调整终端尺寸
int event_driven_pool_resize(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    unsigned short cols,
    unsigned short rows
);

/// 渲染指定终端到指定位置
int event_driven_pool_render(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    float x,
    float y,
    unsigned short cols,
    unsigned short rows
);

/// 提交渲染
void event_driven_pool_flush(EventDrivenPoolHandle pool);

/// 调整字体大小
/// operation: 0 = Reset, 1 = Decrease, 2 = Increase
void event_driven_pool_change_font_size(EventDrivenPoolHandle pool, uint8_t operation);

/// 滚动指定终端
int event_driven_pool_scroll(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    int delta_lines
);

/// 设置选区
int event_driven_pool_set_selection(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    unsigned short start_row,
    unsigned short start_col,
    unsigned short end_row,
    unsigned short end_col
);

/// 清除选区
int event_driven_pool_clear_selection(
    EventDrivenPoolHandle pool,
    size_t terminal_id
);

/// 获取光标位置
int event_driven_pool_get_cursor(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    unsigned short* out_col,
    unsigned short* out_row
);

/// 获取终端数量
size_t event_driven_pool_count(EventDrivenPoolHandle pool);

/// 释放终端池
void event_driven_pool_free(EventDrivenPoolHandle pool);

// =============================================================================
// Focus Reporting API (DECSET 1004)
// =============================================================================
//
// 终端双向通信协议支持：
// 1. CPR (Cursor Position Report) - 已通过 EventCollector 实现
// 2. Focus Reporting - 窗口获得/失去焦点时发送 \e[I / \e[O
//
// 参考 Rio: rio/frontends/rioterm/src/screen/mod.rs:2322-2331

/// 检查指定终端是否启用了 Focus In/Out Reporting 模式 (DECSET 1004)
/// 返回: 1=已启用, 0=未启用或终端不存在
int event_driven_pool_is_focus_mode_enabled(
    EventDrivenPoolHandle pool,
    size_t terminal_id
);

/// 发送 Focus 事件到指定终端
/// 参考 Rio：获得焦点发送 "\x1b[I"，失去焦点发送 "\x1b[O"
/// 返回: 1=成功, 0=终端不存在或未启用 Focus Reporting
int event_driven_pool_send_focus_event(
    EventDrivenPoolHandle pool,
    size_t terminal_id,
    bool is_focused
);

/// 向所有启用了 Focus Reporting 的终端发送 Focus 事件
/// 返回: 成功发送的终端数量
size_t event_driven_pool_send_focus_event_to_all(
    EventDrivenPoolHandle pool,
    bool is_focused
);

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
} FFICell;

// 事件回调类型
typedef void (*EventCallback)(void* context, FFIEvent event);
typedef void (*StringEventCallback)(void* context, uint32_t event_type, const char* str);

/// 创建 Rio 风格终端池
RioTerminalPoolHandle rio_pool_new(SugarloafHandle sugarloaf);

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

/// 获取指定行的单元格数量
size_t rio_pool_get_row_cell_count(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    size_t row_index
);

/// 获取指定行的单元格数据
size_t rio_pool_get_row_cells(
    RioTerminalPoolHandle pool,
    size_t terminal_id,
    size_t row_index,
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

/// 释放终端池
void rio_pool_free(RioTerminalPoolHandle pool);

#endif /* SugarloafBridge_h */
