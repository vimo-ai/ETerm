// P/Invoke declarations for sugarloaf-ffi-win
//
// These bindings mirror the C ABI exported by sugarloaf-ffi-win/src/ffi.rs.
// Uses .NET 8 source-generated marshalling (LibraryImport) for performance.
//
// Error convention (from Rust side):
//   0  = success
//  -1  = null handle
//  -2  = null argument
//  -99 = not yet implemented

using System;
using System.Runtime.InteropServices;

namespace ETerm;

internal static partial class NativeMethods
{
    const string DllName = "sugarloaf_ffi_win";

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// <summary>
    /// Initialize the Windows rendering engine.
    /// Returns an opaque handle on success, or IntPtr.Zero on failure.
    /// The caller owns the handle and must eventually call sugarloaf_win_destroy.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_init")]
    internal static partial IntPtr sugarloaf_win_init();

    /// <summary>
    /// Destroy the engine and release all resources.
    /// After this call the handle is invalid and must not be reused.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_destroy")]
    internal static partial void sugarloaf_win_destroy(IntPtr handle);

    // =========================================================================
    // Renderer initialization
    // =========================================================================

    /// <summary>
    /// Initialize the D3D12 rendering surface for a Win32 HWND.
    /// Must be called before sugarloaf_win_render.
    /// Returns 0 on success, negative error code on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_init_renderer")]
    internal static partial int sugarloaf_win_init_renderer(
        IntPtr handle,
        IntPtr hwnd,
        float width,
        float height,
        float scale);

    /// <summary>
    /// Initialize composition-mode renderer (no HWND, for SwapChainPanel).
    /// Returns swap chain pointer on success, IntPtr.Zero on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_init_renderer_composition")]
    internal static partial IntPtr sugarloaf_win_init_renderer_composition(
        IntPtr handle,
        float width,
        float height,
        float scale);

    /// <summary>
    /// Get the swap chain pointer (for ISwapChainPanelNative.SetSwapChain).
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_get_swap_chain")]
    internal static partial IntPtr sugarloaf_win_get_swap_chain(IntPtr handle);

    /// <summary>
    /// Resize the rendering surface (call when the window is resized).
    /// Returns 0 on success, negative error code on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_resize_renderer")]
    internal static partial int sugarloaf_win_resize_renderer(
        IntPtr handle,
        float width,
        float height);

    // =========================================================================
    // Terminal management
    // =========================================================================

    /// <summary>
    /// Create a new terminal instance inside the engine.
    /// Returns terminal ID (>= 1) on success, or a negative error code.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_create_terminal")]
    internal static partial int sugarloaf_win_create_terminal(
        IntPtr handle,
        ushort cols,
        ushort rows);

    /// <summary>
    /// Close and destroy a terminal instance.
    /// Returns 0 on success, negative error code on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_close_terminal")]
    internal static partial int sugarloaf_win_close_terminal(
        IntPtr handle,
        int terminalId);

    // =========================================================================
    // Render layout (like macOS TerminalPool.set_render_layout)
    // =========================================================================

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_set_render_layout")]
    internal static partial int sugarloaf_win_set_render_layout(
        IntPtr handle,
        [In] TerminalRenderLayout[] layout,
        nuint count);

    // =========================================================================
    // Resize
    // =========================================================================

    /// <summary>
    /// Notify the engine that a terminal's viewport has been resized.
    /// Returns 0 on success, negative error code on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_resize")]
    internal static partial int sugarloaf_win_resize(
        IntPtr handle,
        int terminalId,
        ushort cols,
        ushort rows,
        ushort width,
        ushort height);

    // =========================================================================
    // Rendering
    // =========================================================================

    /// <summary>
    /// Render the current frame.
    /// Called each frame by the WinUI 3 compositor callback.
    /// Returns 0 on success, negative error code on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_render")]
    internal static partial int sugarloaf_win_render(IntPtr handle);

    // =========================================================================
    // Input
    // =========================================================================

    /// <summary>
    /// Write user input (keystrokes) to a terminal's PTY.
    /// Returns 0 on success, negative error code on failure.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_write")]
    internal static unsafe partial int sugarloaf_win_write(
        IntPtr handle,
        int terminalId,
        byte* data,
        uint len);

    // =========================================================================
    // Queries
    // =========================================================================

    /// <summary>
    /// Get the current title of a terminal (set via OSC escape sequences).
    /// Returns a null-terminated UTF-8 string pointer, or IntPtr.Zero if
    /// the terminal does not exist or has no title.
    /// The caller must free the returned pointer via sugarloaf_win_free_string.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_get_title")]
    internal static partial IntPtr sugarloaf_win_get_title(
        IntPtr handle,
        int terminalId);

    // =========================================================================
    // Memory management
    // =========================================================================

    /// <summary>
    /// Free a string that was allocated by the native library.
    /// Must be called for every non-null string returned by functions like
    /// sugarloaf_win_get_title. Passing IntPtr.Zero is a safe no-op.
    /// </summary>
    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_free_string")]
    internal static partial void sugarloaf_win_free_string(IntPtr s);

    // =========================================================================
    // Font metrics
    // =========================================================================

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_get_font_metrics")]
    internal static partial int sugarloaf_win_get_font_metrics(
        IntPtr handle,
        out FontMetrics metrics);

    // =========================================================================
    // Scroll
    // =========================================================================

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_scroll")]
    internal static partial int sugarloaf_win_scroll(
        IntPtr handle,
        int terminalId,
        int delta);

    // =========================================================================
    // Selection
    // =========================================================================

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_screen_to_absolute")]
    internal static partial ScreenToAbsoluteResult sugarloaf_win_screen_to_absolute(
        IntPtr handle,
        int terminalId,
        nuint screenRow,
        nuint screenCol);

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_set_selection")]
    internal static partial int sugarloaf_win_set_selection(
        IntPtr handle,
        int terminalId,
        long startAbsoluteRow,
        nuint startCol,
        long endAbsoluteRow,
        nuint endCol);

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_clear_selection")]
    internal static partial int sugarloaf_win_clear_selection(
        IntPtr handle,
        int terminalId);

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_get_selection_text")]
    internal static partial SelectionTextResult sugarloaf_win_get_selection_text(
        IntPtr handle,
        int terminalId);

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_finalize_selection")]
    internal static partial SelectionTextResult sugarloaf_win_finalize_selection(
        IntPtr handle,
        int terminalId);

    // =========================================================================
    // Cursor
    // =========================================================================

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_get_cursor_pos")]
    internal static partial CursorPosition sugarloaf_win_get_cursor_pos(
        IntPtr handle,
        int terminalId);

    // =========================================================================
    // Bracketed paste
    // =========================================================================

    [LibraryImport(DllName, EntryPoint = "sugarloaf_win_is_bracketed_paste_enabled")]
    [return: MarshalAs(UnmanagedType.U1)]
    internal static partial bool sugarloaf_win_is_bracketed_paste_enabled(
        IntPtr handle,
        int terminalId);
}

[StructLayout(LayoutKind.Sequential)]
internal struct TerminalRenderLayout
{
    public int TerminalId;
    public float X;
    public float Y;
    public float Width;
    public float Height;
}

[StructLayout(LayoutKind.Sequential)]
internal struct FontMetrics
{
    public float CellWidth;
    public float CellHeight;
    public float LineHeight;
}

[StructLayout(LayoutKind.Sequential)]
internal struct ScreenToAbsoluteResult
{
    public long AbsoluteRow;
    public nuint Col;
    public byte SuccessRaw;
    public bool Success => SuccessRaw != 0;
}

[StructLayout(LayoutKind.Sequential)]
internal struct SelectionTextResult
{
    public IntPtr Text;
    public nuint TextLen;
    public byte SuccessRaw;
    public bool Success => SuccessRaw != 0;
}

[StructLayout(LayoutKind.Sequential)]
internal struct CursorPosition
{
    public int Row;
    public int Col;
}
