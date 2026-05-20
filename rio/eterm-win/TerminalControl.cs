using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace ETerm;

/// <summary>
/// Custom control for terminal rendering and input handling.
///
/// This is a stub that will eventually:
///   - Host a SwapChainPanel for GPU-accelerated terminal rendering
///   - Handle keyboard input and forward it to the PTY via sugarloaf_win_write
///   - Manage terminal selection, scrollback, and clipboard
///
/// The actual rendering is performed by the native sugarloaf-ffi-win engine;
/// this control is the WinUI 3 host that owns the rendering surface and
/// dispatches input events.
/// </summary>
public sealed class TerminalControl : SwapChainPanel
{
    /// <summary>
    /// Opaque handle to the native engine (shared with MainWindow).
    /// </summary>
    private IntPtr _engineHandle = IntPtr.Zero;

    /// <summary>
    /// Terminal ID assigned by the native engine.
    /// </summary>
    private int _terminalId = -1;

    public TerminalControl()
    {
        this.IsTabStop = true;

        this.KeyDown += OnKeyDown;
        this.CharacterReceived += OnCharacterReceived;
    }

    /// <summary>
    /// Attach this control to a native engine instance and terminal.
    /// Must be called after sugarloaf_win_init and create_terminal succeed.
    /// </summary>
    public void Attach(IntPtr engineHandle, int terminalId)
    {
        _engineHandle = engineHandle;
        _terminalId = terminalId;
    }

    /// <summary>
    /// Detach from the native engine. No further input will be forwarded.
    /// </summary>
    public void Detach()
    {
        _engineHandle = IntPtr.Zero;
        _terminalId = -1;
    }

    /// <summary>
    /// Whether this control is attached to a live terminal.
    /// </summary>
    public bool IsAttached => _engineHandle != IntPtr.Zero && _terminalId >= 0;

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // TODO: Translate VirtualKey to terminal escape sequences
        // (e.g., arrow keys, function keys, modifier combos)
        // and forward via WriteToTerminal
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (!IsAttached)
        {
            return;
        }

        // Convert the character to UTF-8 and write to the terminal
        char ch = e.Character;
        byte[] utf8 = Encoding.UTF8.GetBytes(new[] { ch });
        WriteToTerminal(utf8);

        e.Handled = true;
    }

    /// <summary>
    /// Write raw bytes to the terminal's PTY input.
    /// </summary>
    private void WriteToTerminal(byte[] data)
    {
        if (!IsAttached || data.Length == 0)
        {
            return;
        }

        unsafe
        {
            fixed (byte* ptr = data)
            {
                NativeMethods.sugarloaf_win_write(
                    _engineHandle,
                    _terminalId,
                    ptr,
                    (uint)data.Length);
            }
        }
    }
}
