using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.ApplicationModel.DataTransfer;

namespace ETerm;

public sealed class TerminalControl : SwapChainPanel
{
    private IntPtr _engineHandle = IntPtr.Zero;
    private float _cellW = 8.0f;
    private float _cellH = 16.0f;

    public Func<int>? GetFocusedTerminalId;
    public Func<double, double, int>? GetTerminalAtPosition;

    public event Action? NewTabRequested;
    public event Action? CloseTabRequested;
    public event Action? NextTabRequested;
    public event Action? PreviousTabRequested;
    public event Action? SplitVerticalRequested;
    public event Action? SplitHorizontalRequested;
    public event Action? ClosePaneRequested;
    public event Action? MoveFocusNextRequested;

    public TerminalControl()
    {
        IsTabStop = true;
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        PointerWheelChanged += OnPointerWheelChanged;
    }

    public float CellW { get => _cellW; set => _cellW = value; }
    public float CellH { get => _cellH; set => _cellH = value; }

    public void SetEngine(IntPtr handle) => _engineHandle = handle;

    private int FocusedId => GetFocusedTerminalId?.Invoke() ?? -1;

    private int TerminalAt(double x, double y) =>
        GetTerminalAtPosition?.Invoke(x, y) ?? FocusedId;

    // ── Keyboard ──

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var alt = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        if (ctrl && shift && e.Key == VirtualKey.T)
        { NewTabRequested?.Invoke(); e.Handled = true; return; }
        if (ctrl && shift && e.Key == VirtualKey.W)
        { CloseTabRequested?.Invoke(); e.Handled = true; return; }
        if (ctrl && !shift && e.Key == VirtualKey.Tab)
        { NextTabRequested?.Invoke(); e.Handled = true; return; }
        if (ctrl && shift && e.Key == VirtualKey.Tab)
        { PreviousTabRequested?.Invoke(); e.Handled = true; return; }

        if (alt && shift && e.Key == VirtualKey.D)
        { SplitVerticalRequested?.Invoke(); e.Handled = true; return; }
        if (alt && shift && (e.Key == (VirtualKey)0xBD))
        { SplitHorizontalRequested?.Invoke(); e.Handled = true; return; }
        if (alt && e.Key == VirtualKey.W)
        { ClosePaneRequested?.Invoke(); e.Handled = true; return; }
        if (alt && e.Key == VirtualKey.Tab)
        { MoveFocusNextRequested?.Invoke(); e.Handled = true; return; }

        int tid = FocusedId;
        if (_engineHandle == IntPtr.Zero || tid < 0) return;

        if (ctrl && !shift && !alt && e.Key == VirtualKey.C)
        { if (TryCopySelection(tid)) { e.Handled = true; return; } }
        if (ctrl && !shift && !alt && e.Key == VirtualKey.V)
        { _ = PasteFromClipboardAsync(tid); e.Handled = true; return; }

        if (HandleVirtualKey(tid, e.Key, shift, ctrl, alt))
            e.Handled = true;
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        int tid = FocusedId;
        if (_engineHandle == IntPtr.Zero || tid < 0) return;

        if (e.Character >= 0x20)
        {
            byte[] utf8 = Encoding.UTF8.GetBytes(new[] { (char)e.Character });
            WriteToTerminal(tid, utf8);
            e.Handled = true;
        }
    }

    private bool HandleVirtualKey(int tid, VirtualKey vk, bool shift, bool ctrl, bool alt)
    {
        if (ctrl)
        {
            byte? ctrlByte = vk switch
            {
                >= VirtualKey.A and <= VirtualKey.Z => (byte)((int)vk - 0x40),
                (VirtualKey)0xBE => 0x1C,
                (VirtualKey)0xDB => 0x1B,
                (VirtualKey)0xDD => 0x1D,
                _ => null,
            };
            if (ctrlByte is byte b) { WriteToTerminal(tid, [b]); return true; }
        }

        byte[]? seq = vk switch
        {
            VirtualKey.Up => alt ? "\x1b[1;3A"u8.ToArray() : ctrl ? "\x1b[1;5A"u8.ToArray() : shift ? "\x1b[1;2A"u8.ToArray() : "\x1b[A"u8.ToArray(),
            VirtualKey.Down => alt ? "\x1b[1;3B"u8.ToArray() : ctrl ? "\x1b[1;5B"u8.ToArray() : shift ? "\x1b[1;2B"u8.ToArray() : "\x1b[B"u8.ToArray(),
            VirtualKey.Right => alt ? "\x1b[1;3C"u8.ToArray() : ctrl ? "\x1b[1;5C"u8.ToArray() : shift ? "\x1b[1;2C"u8.ToArray() : "\x1b[C"u8.ToArray(),
            VirtualKey.Left => alt ? "\x1b[1;3D"u8.ToArray() : ctrl ? "\x1b[1;5D"u8.ToArray() : shift ? "\x1b[1;2D"u8.ToArray() : "\x1b[D"u8.ToArray(),
            VirtualKey.Home => ctrl ? "\x1b[1;5H"u8.ToArray() : "\x1b[H"u8.ToArray(),
            VirtualKey.End => ctrl ? "\x1b[1;5F"u8.ToArray() : "\x1b[F"u8.ToArray(),
            VirtualKey.Insert => "\x1b[2~"u8.ToArray(),
            VirtualKey.Delete => "\x1b[3~"u8.ToArray(),
            VirtualKey.PageUp => "\x1b[5~"u8.ToArray(),
            VirtualKey.PageDown => "\x1b[6~"u8.ToArray(),
            VirtualKey.F1 => "\x1bOP"u8.ToArray(),
            VirtualKey.F2 => "\x1bOQ"u8.ToArray(),
            VirtualKey.F3 => "\x1bOR"u8.ToArray(),
            VirtualKey.F4 => "\x1bOS"u8.ToArray(),
            VirtualKey.F5 => "\x1b[15~"u8.ToArray(),
            VirtualKey.F6 => "\x1b[17~"u8.ToArray(),
            VirtualKey.F7 => "\x1b[18~"u8.ToArray(),
            VirtualKey.F8 => "\x1b[19~"u8.ToArray(),
            VirtualKey.F9 => "\x1b[20~"u8.ToArray(),
            VirtualKey.F10 => "\x1b[21~"u8.ToArray(),
            VirtualKey.F11 => "\x1b[23~"u8.ToArray(),
            VirtualKey.F12 => "\x1b[24~"u8.ToArray(),
            VirtualKey.Back => alt ? "\x1b\x7f"u8.ToArray() : "\x7f"u8.ToArray(),
            VirtualKey.Tab => shift ? "\x1b[Z"u8.ToArray() : "\t"u8.ToArray(),
            VirtualKey.Enter => "\r"u8.ToArray(),
            VirtualKey.Escape => "\x1b"u8.ToArray(),
            _ => null,
        };

        if (seq is not null) { WriteToTerminal(tid, seq); return true; }
        return false;
    }

    // ── Selection ──

    private bool _selecting;
    private int _selTerminalId = -1;
    private long _selStartAbsRow;
    private nuint _selStartCol;
    private (nuint col, nuint row) PixelToCell(double x, double y)
    {
        nuint col = (nuint)(Math.Max(0, x) / CellW);
        nuint row = (nuint)(Math.Max(0, y) / CellH);
        return (col, row);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        if (_engineHandle == IntPtr.Zero) return;
        var pt = e.GetCurrentPoint(this);
        if (!pt.Properties.IsLeftButtonPressed) return;

        int tid = TerminalAt(pt.Position.X, pt.Position.Y);
        if (tid < 0) return;

        NativeMethods.sugarloaf_win_clear_selection(_engineHandle, tid);

        var (col, row) = PixelToCell(pt.Position.X, pt.Position.Y);
        var abs = NativeMethods.sugarloaf_win_screen_to_absolute(
            _engineHandle, tid, row, col);

        if (abs.Success)
        {
            _selecting = true;
            _selTerminalId = tid;
            _selStartAbsRow = abs.AbsoluteRow;
            _selStartCol = abs.Col;
            CapturePointer(e.Pointer);
        }
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_selecting || _selTerminalId < 0) return;
        var pt = e.GetCurrentPoint(this);
        var (col, row) = PixelToCell(pt.Position.X, pt.Position.Y);
        var abs = NativeMethods.sugarloaf_win_screen_to_absolute(
            _engineHandle, _selTerminalId, row, col);

        if (abs.Success)
        {
            NativeMethods.sugarloaf_win_set_selection(
                _engineHandle, _selTerminalId,
                _selStartAbsRow, _selStartCol,
                abs.AbsoluteRow, abs.Col);
        }
        e.Handled = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_selecting) return;
        _selecting = false;
        ReleasePointerCapture(e.Pointer);

        if (_selTerminalId >= 0)
        {
            var result = NativeMethods.sugarloaf_win_finalize_selection(
                _engineHandle, _selTerminalId);
            if (result.Success && result.Text != IntPtr.Zero)
                NativeMethods.sugarloaf_win_free_string(result.Text);
        }
        _selTerminalId = -1;
        e.Handled = true;
    }

    // ── Scroll ──

    private int _wheelAccum;

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        if (_engineHandle == IntPtr.Zero) return;
        var pt = e.GetCurrentPoint(this);
        int tid = TerminalAt(pt.Position.X, pt.Position.Y);
        if (tid < 0) return;

        int delta = pt.Properties.MouseWheelDelta;
        _wheelAccum += delta;
        int ticks = _wheelAccum / 120;
        _wheelAccum -= ticks * 120;

        int lines = ticks * 3;
        if (lines != 0)
            NativeMethods.sugarloaf_win_scroll(_engineHandle, tid, lines);
        e.Handled = true;
    }

    // ── Clipboard ──

    private bool TryCopySelection(int tid)
    {
        if (_engineHandle == IntPtr.Zero) return false;
        var result = NativeMethods.sugarloaf_win_get_selection_text(_engineHandle, tid);
        if (!result.Success || result.Text == IntPtr.Zero) return false;

        string? text = Marshal.PtrToStringUTF8(result.Text);
        NativeMethods.sugarloaf_win_free_string(result.Text);
        NativeMethods.sugarloaf_win_clear_selection(_engineHandle, tid);

        if (string.IsNullOrEmpty(text)) return false;
        var dp = new DataPackage();
        dp.SetText(text);
        Clipboard.SetContent(dp);
        return true;
    }

    private async System.Threading.Tasks.Task PasteFromClipboardAsync(int tid)
    {
        if (_engineHandle == IntPtr.Zero) return;
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text)) return;

        string text = await content.GetTextAsync();
        if (string.IsNullOrEmpty(text)) return;

        string normalized = text.Replace("\r\n", "\r");
        byte[] data = Encoding.UTF8.GetBytes(normalized);

        if (NativeMethods.sugarloaf_win_is_bracketed_paste_enabled(_engineHandle, tid))
        {
            WriteToTerminal(tid, "\x1b[200~"u8.ToArray());
            WriteToTerminal(tid, data);
            WriteToTerminal(tid, "\x1b[201~"u8.ToArray());
        }
        else
        {
            WriteToTerminal(tid, data);
        }
    }

    // ── PTY write ──

    private void WriteToTerminal(int tid, byte[] data)
    {
        if (_engineHandle == IntPtr.Zero || data.Length == 0) return;
        unsafe
        {
            fixed (byte* ptr = data)
            {
                NativeMethods.sugarloaf_win_write(_engineHandle, tid, ptr, (uint)data.Length);
            }
        }
    }
}
