using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace ETerm;

public sealed partial class MainWindow : Window
{
    private IntPtr _engineHandle = IntPtr.Zero;
    private int _terminalId = -1;
    private DispatcherTimer? _renderTimer;
    private bool _rendererReady;

    private const ushort DefaultCols = 80;
    private const ushort DefaultRows = 24;

    public MainWindow()
    {
        this.InitializeComponent();

        TerminalControl.Loaded += OnTerminalControlLoaded;
        TerminalControl.SizeChanged += OnSizeChanged;
        this.Closed += OnWindowClosed;
    }

    private void OnTerminalControlLoaded(object sender, RoutedEventArgs e)
    {
        _engineHandle = NativeMethods.sugarloaf_win_init();
        if (_engineHandle == IntPtr.Zero)
        {
            System.Diagnostics.Debug.WriteLine("[ETerm] sugarloaf_win_init failed");
            return;
        }

        IntPtr hwnd = WindowNative.GetWindowHandle(this);

        float width = (float)TerminalControl.ActualWidth;
        float height = (float)TerminalControl.ActualHeight;
        if (width < 1) width = 800;
        if (height < 1) height = 600;

        float scale = (float)(TerminalControl.XamlRoot?.RasterizationScale ?? 1.0);

        int result = NativeMethods.sugarloaf_win_init_renderer(
            _engineHandle, hwnd, width, height, scale);

        if (result != 0)
        {
            System.Diagnostics.Debug.WriteLine(
                $"[ETerm] init_renderer failed: {result}");
            return;
        }

        _rendererReady = true;

        _terminalId = NativeMethods.sugarloaf_win_create_terminal(
            _engineHandle, DefaultCols, DefaultRows);

        TerminalControl.Attach(_engineHandle, _terminalId);

        _renderTimer = new DispatcherTimer();
        _renderTimer.Interval = TimeSpan.FromMilliseconds(16);
        _renderTimer.Tick += OnRenderTick;
        _renderTimer.Start();

        System.Diagnostics.Debug.WriteLine(
            $"[ETerm] Ready: terminal={_terminalId}, {width}x{height} @{scale}x");
    }

    private void OnRenderTick(object? sender, object e)
    {
        if (!_rendererReady || _engineHandle == IntPtr.Zero)
            return;

        NativeMethods.sugarloaf_win_render(_engineHandle);
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_engineHandle == IntPtr.Zero || !_rendererReady)
            return;

        float width = (float)e.NewSize.Width;
        float height = (float)e.NewSize.Height;
        if (width < 1 || height < 1)
            return;

        NativeMethods.sugarloaf_win_resize_renderer(_engineHandle, width, height);

        if (_terminalId >= 0)
        {
            NativeMethods.sugarloaf_win_resize(
                _engineHandle, _terminalId,
                DefaultCols, DefaultRows,
                (ushort)width, (ushort)height);
        }
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _renderTimer?.Stop();
        _renderTimer = null;

        if (_engineHandle == IntPtr.Zero)
            return;

        TerminalControl.Detach();

        if (_terminalId >= 0)
        {
            NativeMethods.sugarloaf_win_close_terminal(_engineHandle, _terminalId);
            _terminalId = -1;
        }

        NativeMethods.sugarloaf_win_destroy(_engineHandle);
        _engineHandle = IntPtr.Zero;
    }

    public string? GetTerminalTitle()
    {
        if (_engineHandle == IntPtr.Zero || _terminalId < 0)
            return null;

        IntPtr titlePtr = NativeMethods.sugarloaf_win_get_title(_engineHandle, _terminalId);
        if (titlePtr == IntPtr.Zero)
            return null;

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
