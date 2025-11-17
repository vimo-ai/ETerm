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

// ===== Split Pane API =====

// Split the active pane vertically (left-right)
// Returns new pane_id or -1 on failure
int tab_manager_split_right(TabManagerHandle manager);

// Split the active pane horizontally (top-bottom)
// Returns new pane_id or -1 on failure
int tab_manager_split_down(TabManagerHandle manager);

// Close a specific pane
// Returns 0 on failure, non-zero on success
int tab_manager_close_pane(TabManagerHandle manager, size_t pane_id);

// Set the active pane
// Returns 0 on failure, non-zero on success
int tab_manager_set_active_pane(TabManagerHandle manager, size_t pane_id);

// Get the number of panes in the current tab
size_t tab_manager_get_pane_count(TabManagerHandle manager);

// Get pane at specific position (for click focus switching)
// Returns pane_id or -1 if no pane found at that position
// x, y are in logical coordinates
int tab_manager_get_pane_at_position(
    TabManagerHandle manager,
    float x,
    float y
);

// Pane position and size information
typedef struct {
    float x;
    float y;
    float width;
    float height;
} PaneInfo;

// Get pane position and size information (in logical coordinates)
// Returns 0 on failure, non-zero on success
int tab_manager_get_pane_info(
    TabManagerHandle manager,
    size_t pane_id,
    PaneInfo* out_info
);

// ===== Divider Resizing API =====

// Divider information
typedef struct {
    size_t pane_id_1;      // Left/top pane
    size_t pane_id_2;      // Right/bottom pane
    unsigned char divider_type;  // 0=vertical (left-right), 1=horizontal (top-bottom)
    float position;        // Divider position in logical coordinates
} DividerInfo;

// Get all dividers in the current tab
// Returns the number of dividers found
size_t tab_manager_get_dividers(
    TabManagerHandle manager,
    DividerInfo* out_dividers,
    size_t max_count
);

// Resize divider by moving it
// delta: movement in logical coordinates (positive = right/down, negative = left/up)
// Returns 0 on failure, non-zero on success
int tab_manager_resize_divider(
    TabManagerHandle manager,
    size_t pane_id_1,
    size_t pane_id_2,
    float delta
);

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

#endif /* SugarloafBridge_h */
