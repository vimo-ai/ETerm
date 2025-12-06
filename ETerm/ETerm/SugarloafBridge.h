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
// TerminalPool API (New Architecture - Multi-terminal + Unified Render)
// =============================================================================

/// TerminalPool handle (opaque pointer)
typedef void* TerminalPoolHandle;

/// Free string returned from Rust
void rio_free_string(char* s);

/// App configuration for TerminalPool
typedef struct {
    uint16_t cols;
    uint16_t rows;
    float font_size;
    float line_height;
    float scale;
    void* window_handle;
    void* display_handle;
    float window_width;
    float window_height;
    uint32_t history_size;
} TerminalPoolConfig;

/// Terminal event types
typedef enum {
    TerminalEventType_Wakeup = 0,
    TerminalEventType_Render = 1,
    TerminalEventType_CursorBlink = 2,
    TerminalEventType_Bell = 3,
    TerminalEventType_TitleChanged = 4,
    TerminalEventType_Damaged = 5,
} TerminalPoolEventType;

/// Terminal event
typedef struct {
    TerminalPoolEventType event_type;
    uint64_t data;  // terminal_id for multi-terminal events
} TerminalPoolEvent;

/// Event callback type
typedef void (*TerminalPoolEventCallback)(void* context, TerminalPoolEvent event);

/// Create TerminalPool
///
/// Returns: Handle on success, NULL on failure
TerminalPoolHandle terminal_pool_create(TerminalPoolConfig config);

/// Destroy TerminalPool
void terminal_pool_destroy(TerminalPoolHandle handle);

/// Create new terminal
///
/// Returns: Terminal ID (>= 1) on success, -1 on failure
int32_t terminal_pool_create_terminal(
    TerminalPoolHandle handle,
    uint16_t cols,
    uint16_t rows
);

/// Create new terminal with working directory
///
/// Returns: Terminal ID (>= 1) on success, -1 on failure
int32_t terminal_pool_create_terminal_with_cwd(
    TerminalPoolHandle handle,
    uint16_t cols,
    uint16_t rows,
    const char* working_dir
);

/// Close terminal
bool terminal_pool_close_terminal(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Get terminal's current working directory
///
/// Returns a string that must be freed with rio_free_string
char* terminal_pool_get_cwd(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Resize terminal
bool terminal_pool_resize_terminal(
    TerminalPoolHandle handle,
    size_t terminal_id,
    uint16_t cols,
    uint16_t rows,
    float width,
    float height
);

/// Send input to terminal
bool terminal_pool_input(
    TerminalPoolHandle handle,
    size_t terminal_id,
    const uint8_t* data,
    size_t len
);

/// Scroll terminal
bool terminal_pool_scroll(
    TerminalPoolHandle handle,
    size_t terminal_id,
    int32_t delta
);

// ===== Render Flow (Unified Submit) =====

/// Begin new frame (clear pending objects)
void terminal_pool_begin_frame(TerminalPoolHandle handle);

/// Render terminal at position (accumulate to pending list)
///
/// Parameters:
/// - terminal_id: Terminal to render
/// - x, y: Position (logical coordinates, Y from top)
/// - width, height: Terminal area size (logical coordinates)
///   - If > 0, auto-calculate cols/rows and resize
///   - If = 0, don't resize (keep current size)
bool terminal_pool_render_terminal(
    TerminalPoolHandle handle,
    size_t terminal_id,
    float x,
    float y,
    float width,
    float height
);

/// End frame (unified submit to GPU)
void terminal_pool_end_frame(TerminalPoolHandle handle);

/// Resize Sugarloaf render surface
void terminal_pool_resize_sugarloaf(
    TerminalPoolHandle handle,
    float width,
    float height
);

/// Set event callback
void terminal_pool_set_event_callback(
    TerminalPoolHandle handle,
    TerminalPoolEventCallback callback,
    void* context
);

/// Get terminal count
size_t terminal_pool_terminal_count(TerminalPoolHandle handle);

/// Check if needs render
bool terminal_pool_needs_render(TerminalPoolHandle handle);

/// Clear render flag
void terminal_pool_clear_render_flag(TerminalPoolHandle handle);

// =============================================================================
// Selection API (new architecture)
// =============================================================================

/// Screen to absolute coordinate result
typedef struct {
    int64_t absolute_row;
    size_t col;
    bool success;
} ScreenToAbsoluteResult;

/// Convert screen coordinates to absolute coordinates
ScreenToAbsoluteResult terminal_pool_screen_to_absolute(
    TerminalPoolHandle handle,
    size_t terminal_id,
    size_t screen_row,
    size_t screen_col
);

/// Set selection
bool terminal_pool_set_selection(
    TerminalPoolHandle handle,
    size_t terminal_id,
    int64_t start_absolute_row,
    size_t start_col,
    int64_t end_absolute_row,
    size_t end_col
);

/// Clear selection
bool terminal_pool_clear_selection(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Get font metrics from TerminalPool (DDD architecture)
///
/// Returns font metrics consistent with rendering:
/// - cell_width: Cell width (physical pixels)
/// - cell_height: Base cell height (physical pixels, without line_height_factor)
/// - line_height: Actual line height (physical pixels, = cell_height * line_height_factor)
///
/// Note: Mouse coordinate conversion should use line_height (not cell_height)
bool terminal_pool_get_font_metrics(
    TerminalPoolHandle handle,
    SugarloafFontMetrics* out_metrics
);

/// Change font size
///
/// @param handle TerminalPool handle
/// @param operation 0=reset(14pt), 1=decrease(-1pt), 2=increase(+1pt)
/// @return true if successful, false if handle is invalid
bool terminal_pool_change_font_size(
    TerminalPoolHandle handle,
    uint8_t operation
);

/// Get current font size
///
/// @param handle TerminalPool handle
/// @return Current font size in pt, or 0.0 if handle is invalid
float terminal_pool_get_font_size(
    TerminalPoolHandle handle
);

// =============================================================================
// Cursor & Word Boundary API (new architecture)
// =============================================================================

/// Cursor position (screen coordinates)
typedef struct {
    uint16_t col;       // Column (0-based)
    uint16_t row;       // Row (0-based, relative to visible area)
    bool valid;         // Whether the result is valid
} FFICursorPosition;

/// Word boundary information
typedef struct {
    uint16_t start_col;     // Start column (screen coordinates)
    uint16_t end_col;       // End column (screen coordinates, inclusive)
    int64_t absolute_row;   // Absolute row number
    char* text_ptr;         // Word text (must be freed with terminal_pool_free_word_boundary)
    size_t text_len;        // Text length in bytes
    bool valid;             // Whether the result is valid
} FFIWordBoundary;

/// Get cursor position
///
/// Returns the cursor position in screen coordinates (relative to visible area).
/// If the terminal is scrolling through history, the cursor may not be visible.
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
/// @return Cursor position, valid=false if terminal not found
FFICursorPosition terminal_pool_get_cursor(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Get word boundary at specified position
///
/// Word segmentation rules (similar to Swift WordBoundaryDetector):
/// 1. CJK characters: consecutive CJK characters form one word
/// 2. Alphanumeric/underscore: consecutive characters form one word
/// 3. Whitespace: acts as separator
/// 4. Other symbols: form individual words
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
/// @param screen_row Screen row (0-based, relative to visible area)
/// @param screen_col Screen column (0-based)
/// @return Word boundary, valid=false if terminal not found or position invalid
///         If valid=true, text_ptr must be freed with terminal_pool_free_word_boundary
FFIWordBoundary terminal_pool_get_word_at(
    TerminalPoolHandle handle,
    int32_t terminal_id,
    int32_t screen_row,
    int32_t screen_col
);

/// Free word boundary resources
///
/// @param boundary Word boundary returned by terminal_pool_get_word_at
///
/// Note: Only call this for valid=true boundaries, do not free the same boundary twice
void terminal_pool_free_word_boundary(FFIWordBoundary boundary);

// =============================================================================
// RenderScheduler API (CVDisplayLink in Rust)
// =============================================================================

/// RenderScheduler handle (opaque pointer)
typedef void* RenderSchedulerHandle;

/// Render layout info
typedef struct {
    size_t terminal_id;
    float x;
    float y;
    float width;
    float height;
} RenderLayout;

/// Render callback type
///
/// Called on VSync, Swift should execute render in callback:
/// - terminal_pool_begin_frame
/// - terminal_pool_render_terminal (for each layout item)
/// - terminal_pool_end_frame
typedef void (*RenderSchedulerCallback)(
    void* context,
    const RenderLayout* layout,
    size_t layout_count
);

/// Create RenderScheduler
RenderSchedulerHandle render_scheduler_create(void);

/// Destroy RenderScheduler
void render_scheduler_destroy(RenderSchedulerHandle handle);

/// Set render callback
///
/// Callback is called on CVDisplayLink VSync
void render_scheduler_set_callback(
    RenderSchedulerHandle handle,
    RenderSchedulerCallback callback,
    void* context
);

/// Start RenderScheduler (start CVDisplayLink)
bool render_scheduler_start(RenderSchedulerHandle handle);

/// Stop RenderScheduler
void render_scheduler_stop(RenderSchedulerHandle handle);

/// Request render (mark dirty)
void render_scheduler_request_render(RenderSchedulerHandle handle);

/// Set render layout
///
/// Layout info will be passed to callback on next VSync
void render_scheduler_set_layout(
    RenderSchedulerHandle handle,
    const RenderLayout* layout,
    size_t count
);

/// Bind to TerminalPool's needs_render flag
///
/// Let RenderScheduler and TerminalPool share the same dirty flag
void render_scheduler_bind_to_pool(
    RenderSchedulerHandle scheduler_handle,
    TerminalPoolHandle pool_handle
);

#endif /* SugarloafBridge_h */
