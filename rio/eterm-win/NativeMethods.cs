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
}
