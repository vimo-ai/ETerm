//
//  SugarloafBridge.h
//  ETerm
//
//  Created by 💻higuaifan on 2025/11/16.
//

#ifndef SugarloafBridge_h
#define SugarloafBridge_h

#include <stddef.h>

// Opaque handle
typedef void* SugarloafHandle;

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

#endif /* SugarloafBridge_h */
