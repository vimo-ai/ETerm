using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace ETerm;

/// <summary>
/// Main window hosting the terminal rendering surface.
///
/// Lifecycle:
///   Loaded  -> sugarloaf_win_init + create_terminal
///   Closed  -> close_terminal + sugarloaf_win_destroy
///   Resized -> sugarloaf_win_resize
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>
    /// Opaque handle to the native sugarloaf-ffi-win engine.
    /// </summary>
    private IntPtr _engineHandle = IntPtr.Zero;

    /// <summary>
    /// ID of the primary terminal (returned by create_terminal).
    /// </summary>
    private int _terminalId = -1;

    /// <summary>
    /// Default terminal dimensions (columns x rows).
    /// </summary>
    private const ushort DefaultCols = 80;
    private const ushort DefaultRows = 24;

    public MainWindow()
    {
        this.InitializeComponent();

        // Wire up lifecycle events
        TerminalPanel.Loaded += OnTerminalPanelLoaded;
        TerminalPanel.SizeChanged += OnTerminalPanelSizeChanged;
        this.Closed += OnWindowClosed;
    }

    private void OnTerminalPanelLoaded(object sender, RoutedEventArgs e)
    {
        _engineHandle = NativeMethods.sugarloaf_win_init();
        if (_engineHandle == IntPtr.Zero)
        {
            // Engine initialization failed -- this is expected until the
            // native DLL stub is replaced with a real implementation.
            return;
        }

        _terminalId = NativeMethods.sugarloaf_win_create_terminal(
            _engineHandle, DefaultCols, DefaultRows);
    }

    private void OnTerminalPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_engineHandle == IntPtr.Zero || _terminalId < 0)
        {
            return;
        }

        // TODO: Compute cols/rows from pixel size and font metrics
        NativeMethods.sugarloaf_win_resize(
            _engineHandle,
            _terminalId,
            DefaultCols,
            DefaultRows,
            (float)e.NewSize.Width,
            (float)e.NewSize.Height);
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        if (_engineHandle == IntPtr.Zero)
        {
            return;
        }

        if (_terminalId >= 0)
        {
            NativeMethods.sugarloaf_win_close_terminal(_engineHandle, _terminalId);
            _terminalId = -1;
        }

        NativeMethods.sugarloaf_win_destroy(_engineHandle);
        _engineHandle = IntPtr.Zero;
    }

    /// <summary>
    /// Helper: get the current terminal title from the native engine.
    /// Returns null if unavailable.
    /// </summary>
    public string? GetTerminalTitle()
    {
        if (_engineHandle == IntPtr.Zero || _terminalId < 0)
        {
            return null;
        }

        IntPtr titlePtr = NativeMethods.sugarloaf_win_get_title(_engineHandle, _terminalId);
        if (titlePtr == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUTF8(titlePtr);
        }
        finally
        {
            NativeMethods.sugarloaf_win_free_string(titlePtr);
        }
    }
}
