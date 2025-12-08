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

typedef struct {
    float cell_width;
    float cell_height;
    float line_height;
} SugarloafFontMetrics;

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

/// Set DPI scale (call when window moves between screens with different DPI)
///
/// Updates Rust-side scale factor to ensure:
/// - Correct font metrics calculation
/// - Correct selection coordinate conversion
/// - Correct render position calculation
void terminal_pool_set_scale(
    TerminalPoolHandle handle,
    float scale
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

/// Finalize selection result
typedef struct {
    char* text;             // Selected text (UTF-8, must be freed with terminal_pool_free_string)
    size_t text_len;        // Text length (without null terminator)
    bool has_selection;     // Whether there is a valid selection (non-whitespace content)
} FinalizeSelectionResult;

/// Finalize selection (call on mouseUp)
///
/// Business logic:
/// - Check if selection content is all whitespace
/// - If all whitespace, auto-clear selection, return has_selection=false
/// - If has content, keep selection, return selected text
///
/// Caller must free text with terminal_pool_free_string
FinalizeSelectionResult terminal_pool_finalize_selection(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Free string returned by finalize_selection or get_selection_text
void terminal_pool_free_string(char* ptr);

/// Get selection text result
typedef struct {
    char* text;             // Selected text (UTF-8, must be freed with terminal_pool_free_string)
    size_t text_len;        // Text length (without null terminator)
    bool success;           // Whether successful
} GetSelectionTextResult;

/// Get selected text (without clearing selection)
///
/// Used for Cmd+C copy etc.
///
/// Caller must free text with terminal_pool_free_string
GetSelectionTextResult terminal_pool_get_selection_text(
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
// Search API
// =============================================================================

/// Search for text in terminal
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
/// @param query Search query (UTF-8 string)
/// @return Number of matches (>= 0), or -1 on failure
int32_t terminal_pool_search(
    TerminalPoolHandle handle,
    size_t terminal_id,
    const char* query
);

/// Jump to next search match
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
void terminal_pool_search_next(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Jump to previous search match
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
void terminal_pool_search_prev(
    TerminalPoolHandle handle,
    size_t terminal_id
);

/// Clear search
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
void terminal_pool_clear_search(
    TerminalPoolHandle handle,
    size_t terminal_id
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

/// Bind to TerminalPool (new architecture)
///
/// After binding:
/// - RenderScheduler and TerminalPool share needs_render flag
/// - RenderScheduler calls pool.render_all() on VSync
/// - No Swift involvement in render loop
void render_scheduler_bind_to_pool(
    RenderSchedulerHandle scheduler_handle,
    TerminalPoolHandle pool_handle
);

// ============================================================================
// New Architecture: Rust-side rendering
// ============================================================================

/// Terminal render layout info (new architecture)
typedef struct {
    size_t terminal_id;
    float x;
    float y;
    float width;
    float height;
} TerminalRenderLayout;

/// Set render layout (new architecture)
///
/// Swift calls this when layout changes (tab switch, window resize, etc.)
/// Rust uses this layout for rendering on VSync
///
/// Note: Coordinates should be in Rust coordinate system (Y from top)
void terminal_pool_set_render_layout(
    TerminalPoolHandle handle,
    const TerminalRenderLayout* layout,
    size_t count,
    float container_height
);

/// Trigger a full render (new architecture)
///
/// Usually not needed, RenderScheduler calls this automatically on VSync
/// This is for special cases (initialization, force refresh)
void terminal_pool_render_all(TerminalPoolHandle handle);

// ============================================================================
// Terminal Mode API
// ============================================================================

/// Set terminal mode
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
/// @param mode Terminal mode (0=Active, 1=Background)
///
/// - Active: Full processing + render callbacks
/// - Background: Full VTE parsing but no render callbacks (save CPU/GPU)
/// - Switching to Active triggers a render refresh
void terminal_pool_set_mode(
    TerminalPoolHandle handle,
    size_t terminal_id,
    uint8_t mode
);

/// Get terminal mode
///
/// @param handle TerminalPool handle
/// @param terminal_id Terminal ID
/// @return Terminal mode (0=Active, 1=Background, 255=invalid)
uint8_t terminal_pool_get_mode(
    TerminalPoolHandle handle,
    size_t terminal_id
);

#endif /* SugarloafBridge_h */
