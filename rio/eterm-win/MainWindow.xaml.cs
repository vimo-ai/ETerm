using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ETerm;

public sealed partial class MainWindow : Window
{
    private IntPtr _engineHandle = IntPtr.Zero;
    private DispatcherTimer? _renderTimer;
    private DispatcherTimer? _titleTimer;
    private DispatcherTimer? _resizeTimer;
    private bool _ready;
    private float _cellW = 8.0f;
    private float _cellH = 16.0f;
    private float _scale = 1.0f;
    private float _surfaceW;
    private float _surfaceH;

    private readonly List<TabState> _tabs = new();
    private int _activeTabIndex = -1;
    private int _draggedTabIndex = -1;
    private Windows.Foundation.Point _dragStartPoint;
    private bool _isDragging;

    private List<(int terminalId, float x, float y, float w, float h)> _currentLayout = new();

    public MainWindow()
    {
        this.InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarDragRegion);

        TerminalSurface.Loaded += OnSurfaceLoaded;
        TerminalSurface.SizeChanged += OnSurfaceSizeChanged;
        this.Closed += OnWindowClosed;

        TerminalSurface.GetFocusedTerminalId = () =>
        {
            if (_activeTabIndex < 0 || _activeTabIndex >= _tabs.Count) return -1;
            return _tabs[_activeTabIndex].FocusedTerminalId;
        };

        TerminalSurface.GetTerminalAtPosition = (x, y) =>
        {
            foreach (var (tid, lx, ly, lw, lh) in _currentLayout)
            {
                if (x >= lx && x < lx + lw && y >= ly && y < ly + lh)
                    return tid;
            }
            return _activeTabIndex >= 0 && _activeTabIndex < _tabs.Count
                ? _tabs[_activeTabIndex].FocusedTerminalId : -1;
        };

        TabStrip.AddHandler(UIElement.PointerPressedEvent,
            new Microsoft.UI.Xaml.Input.PointerEventHandler(OnTabStripPointerPressed), true);
        TabStrip.AddHandler(UIElement.PointerMovedEvent,
            new Microsoft.UI.Xaml.Input.PointerEventHandler(OnTabStripPointerMoved), true);
        TabStrip.AddHandler(UIElement.PointerReleasedEvent,
            new Microsoft.UI.Xaml.Input.PointerEventHandler(OnTabStripPointerReleased), true);

        TerminalSurface.NewTabRequested += () => CreateTab();
        TerminalSurface.CloseTabRequested += CloseActiveTab;
        TerminalSurface.NextTabRequested += () => SwitchTabRelative(1);
        TerminalSurface.PreviousTabRequested += () => SwitchTabRelative(-1);
        TerminalSurface.SplitVerticalRequested += () => SplitActivePane(SplitDirection.Vertical);
        TerminalSurface.SplitHorizontalRequested += () => SplitActivePane(SplitDirection.Horizontal);
        TerminalSurface.ClosePaneRequested += CloseActivePane;
        TerminalSurface.MoveFocusNextRequested += MoveFocusNext;
    }

    // ── Init ──

    private void OnSurfaceLoaded(object sender, RoutedEventArgs e)
    {
        _engineHandle = NativeMethods.sugarloaf_win_init();
        if (_engineHandle == IntPtr.Zero) return;

        _scale = (float)(TerminalSurface.XamlRoot?.RasterizationScale ?? 1.0);

        _surfaceW = (float)TerminalSurface.ActualWidth;
        _surfaceH = (float)TerminalSurface.ActualHeight;
        if (_surfaceW < 1) _surfaceW = 800;
        if (_surfaceH < 1) _surfaceH = 600;

        IntPtr swapChain = NativeMethods.sugarloaf_win_init_renderer_composition(
            _engineHandle, _surfaceW, _surfaceH, _scale);
        if (swapChain == IntPtr.Zero) return;

        SwapChainPanelInterop.SetSwapChainOnPanel(TerminalSurface, swapChain);
        TerminalSurface.SetEngine(_engineHandle);

        if (NativeMethods.sugarloaf_win_get_font_metrics(_engineHandle, out var metrics) == 0)
        {
            _cellW = metrics.CellWidth;
            _cellH = metrics.LineHeight;
        }
        TerminalSurface.CellW = _cellW;
        TerminalSurface.CellH = _cellH;

        ushort cols = (ushort)(_surfaceW / _cellW);
        ushort rows = (ushort)(_surfaceH / _cellH);
        if (cols < 1) cols = 1;
        if (rows < 1) rows = 1;

        int tid = NativeMethods.sugarloaf_win_create_terminal(_engineHandle, cols, rows);
        if (tid < 0) return;

        _ready = true;

        var leaf = new LeafPane { TerminalId = tid };
        var tab = new TabState
        {
            Root = leaf,
            FocusedTerminalId = tid,
            Title = "PowerShell",
        };
        tab.TabButton = CreateTabButton(tab);
        _tabs.Add(tab);
        TabStrip.Children.Add(tab.TabButton);
        _activeTabIndex = 0;
        UpdateTabStyles();
        SyncRenderLayout();

        _renderTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        _renderTimer.Tick += (_, _) => NativeMethods.sugarloaf_win_render(_engineHandle);
        _renderTimer.Start();

        _titleTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _titleTimer.Tick += OnTitleTick;
        _titleTimer.Start();

        TerminalSurface.Focus(FocusState.Programmatic);
    }

    // ── Render layout sync ──

    private void SyncRenderLayout()
    {
        if (!_ready || _activeTabIndex < 0) return;
        var tab = _tabs[_activeTabIndex];

        var layout = new List<(int tid, float x, float y, float w, float h)>();
        CalculateLayout(tab.Root, 0, 0, _surfaceW, _surfaceH, layout);
        _currentLayout = layout;

        var arr = layout.Select(l => new TerminalRenderLayout
        {
            TerminalId = l.tid,
            X = l.x,
            Y = l.y,
            Width = l.w,
            Height = l.h,
        }).ToArray();

        NativeMethods.sugarloaf_win_set_render_layout(
            _engineHandle, arr, (nuint)arr.Length);

        foreach (var (tid, _, _, w, h) in layout)
        {
            ushort cols = (ushort)(w / _cellW);
            ushort rows = (ushort)(h / _cellH);
            if (cols < 1) cols = 1;
            if (rows < 1) rows = 1;
            NativeMethods.sugarloaf_win_resize(
                _engineHandle, tid, cols, rows, (ushort)w, (ushort)h);
        }
    }

    private static void CalculateLayout(
        PaneNode node, float x, float y, float w, float h,
        List<(int, float, float, float, float)> result)
    {
        if (node is LeafPane leaf)
        {
            result.Add((leaf.TerminalId, x, y, w, h));
            return;
        }

        if (node is SplitNode split)
        {
            const float divider = 2f;
            if (split.Direction == SplitDirection.Vertical)
            {
                float half = (w - divider) / 2;
                CalculateLayout(split.First, x, y, half, h, result);
                CalculateLayout(split.Second, x + half + divider, y, half, h, result);
            }
            else
            {
                float half = (h - divider) / 2;
                CalculateLayout(split.First, x, y, w, half, result);
                CalculateLayout(split.Second, x, y + half + divider, w, half, result);
            }
        }
    }

    // ── Resize ──

    private void OnSurfaceSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_ready || _engineHandle == IntPtr.Zero) return;

        float w = (float)e.NewSize.Width;
        float h = (float)e.NewSize.Height;
        if (w < 1 || h < 1) return;

        _surfaceW = w;
        _surfaceH = h;

        NativeMethods.sugarloaf_win_resize_renderer(_engineHandle, w, h);

        IntPtr sc = NativeMethods.sugarloaf_win_get_swap_chain(_engineHandle);
        if (sc != IntPtr.Zero)
            SwapChainPanelInterop.SetSwapChainOnPanel(TerminalSurface, sc);

        _resizeTimer?.Stop();
        _resizeTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _resizeTimer.Tick += OnResizeCommit;
        _resizeTimer.Start();
    }

    private void OnResizeCommit(object? sender, object e)
    {
        _resizeTimer?.Stop();
        if (_resizeTimer != null) _resizeTimer.Tick -= OnResizeCommit;
        SyncRenderLayout();
    }

    // ── Tab management ──

    private int CreateTerminal()
    {
        ushort cols = (ushort)(_surfaceW / _cellW);
        ushort rows = (ushort)(_surfaceH / _cellH);
        if (cols < 1) cols = 1;
        if (rows < 1) rows = 1;
        return NativeMethods.sugarloaf_win_create_terminal(_engineHandle, cols, rows);
    }

    private void CreateTab()
    {
        if (!_ready) return;

        int tid = CreateTerminal();
        if (tid < 0) return;

        var leaf = new LeafPane { TerminalId = tid };
        var tab = new TabState
        {
            Root = leaf,
            FocusedTerminalId = tid,
            Title = "PowerShell",
        };
        tab.TabButton = CreateTabButton(tab);
        _tabs.Add(tab);
        TabStrip.Children.Add(tab.TabButton);
        SwitchToTab(_tabs.Count - 1);
    }

    private Button CreateTabButton(TabState tab)
    {
        var titleText = new TextBlock
        {
            Text = tab.Title,
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(
                Windows.UI.Color.FromArgb(255, 204, 204, 204)),
            MaxWidth = 160,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        tab.TitleTextBlock = titleText;

        var closeBtn = new Button
        {
            Content = "\xE711",
            FontFamily = new FontFamily("Segoe MDL2 Assets"),
            FontSize = 9,
            Width = 20, Height = 20,
            Padding = new Thickness(0),
            Margin = new Thickness(6, 0, 0, 0),
            Background = new SolidColorBrush(
                Windows.UI.Color.FromArgb(0, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        closeBtn.Click += (_, _) =>
        {
            int idx = _tabs.IndexOf(tab);
            if (idx >= 0) CloseTabAt(idx);
        };

        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children = { titleText, closeBtn },
        };

        var btn = new Button
        {
            Content = panel,
            Height = 28, MinWidth = 80, MaxWidth = 200,
            Padding = new Thickness(10, 4, 6, 4),
            Background = new SolidColorBrush(
                Windows.UI.Color.FromArgb(255, 30, 30, 30)),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(6, 6, 0, 0),
        };
        btn.Click += (_, _) =>
        {
            if (_isDragging) return;
            int idx = _tabs.IndexOf(tab);
            if (idx >= 0) SwitchToTab(idx);
        };

        return btn;
    }

    private void SwitchToTab(int index)
    {
        if (index < 0 || index >= _tabs.Count) return;
        _activeTabIndex = index;
        SyncRenderLayout();
        UpdateTabStyles();
        UpdateWindowTitle();
        TerminalSurface.Focus(FocusState.Programmatic);
    }

    private void SwitchTabRelative(int delta)
    {
        if (_tabs.Count <= 1) return;
        int next = (_activeTabIndex + delta + _tabs.Count) % _tabs.Count;
        SwitchToTab(next);
    }

    private void CloseActiveTab()
    {
        if (_activeTabIndex >= 0 && _activeTabIndex < _tabs.Count)
            CloseTabAt(_activeTabIndex);
    }

    private void CloseTabAt(int idx)
    {
        if (idx < 0 || idx >= _tabs.Count) return;

        if (_tabs.Count == 1)
        {
            this.Close();
            return;
        }

        var tab = _tabs[idx];
        foreach (var leaf in CollectLeaves(tab.Root))
            NativeMethods.sugarloaf_win_close_terminal(_engineHandle, leaf.TerminalId);

        TabStrip.Children.Remove(tab.TabButton);
        _tabs.RemoveAt(idx);

        if (_activeTabIndex >= _tabs.Count)
            _activeTabIndex = _tabs.Count - 1;
        else if (idx <= _activeTabIndex && _activeTabIndex > 0)
            _activeTabIndex--;

        SwitchToTab(_activeTabIndex);
    }

    private void UpdateTabStyles()
    {
        for (int i = 0; i < _tabs.Count; i++)
        {
            bool active = i == _activeTabIndex;
            _tabs[i].TabButton.Background = new SolidColorBrush(
                active
                    ? Windows.UI.Color.FromArgb(255, 12, 12, 12)
                    : Windows.UI.Color.FromArgb(255, 30, 30, 30));
        }
    }

    private void OnNewTabClick(object sender, RoutedEventArgs e) => CreateTab();

    // ── Tab drag reorder (pointer-based on TabStrip) ──

    private int HitTestTab(double x)
    {
        for (int i = 0; i < _tabs.Count; i++)
        {
            var tabBtn = _tabs[i].TabButton;
            var transform = tabBtn.TransformToVisual(TabStrip);
            var origin = transform.TransformPoint(
                new Windows.Foundation.Point(0, 0));
            if (x >= origin.X && x < origin.X + tabBtn.ActualWidth)
                return i;
        }
        return -1;
    }

    private void OnTabStripPointerPressed(object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        var pos = e.GetCurrentPoint(TabStrip).Position;
        int idx = HitTestTab(pos.X);
        if (idx < 0) return;

        _draggedTabIndex = idx;
        _dragStartPoint = pos;
        _isDragging = false;
        TabStrip.CapturePointer(e.Pointer);
    }

    private void OnTabStripPointerMoved(object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (_draggedTabIndex < 0) return;
        var pos = e.GetCurrentPoint(TabStrip).Position;

        if (!_isDragging && Math.Abs(pos.X - _dragStartPoint.X) > 8)
            _isDragging = true;
        if (!_isDragging) return;

        int targetIdx = HitTestTab(pos.X);
        if (targetIdx >= 0 && targetIdx != _draggedTabIndex)
        {
            var active = _tabs[_activeTabIndex];
            var dragged = _tabs[_draggedTabIndex];
            _tabs.RemoveAt(_draggedTabIndex);
            _tabs.Insert(targetIdx, dragged);

            TabStrip.Children.Clear();
            foreach (var t in _tabs)
                TabStrip.Children.Add(t.TabButton);

            _activeTabIndex = _tabs.IndexOf(active);
            _draggedTabIndex = targetIdx;
            UpdateTabStyles();
        }
    }

    private void OnTabStripPointerReleased(object sender,
        Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (_draggedTabIndex >= 0)
            TabStrip.ReleasePointerCapture(e.Pointer);
        _draggedTabIndex = -1;
        _isDragging = false;
    }

    // ── Pane split / close ──

    private void SplitActivePane(SplitDirection dir)
    {
        if (!_ready || _activeTabIndex < 0) return;
        var tab = _tabs[_activeTabIndex];

        int tid = CreateTerminal();
        if (tid < 0) return;

        var oldLeaf = FindLeaf(tab.Root, tab.FocusedTerminalId);
        if (oldLeaf == null) return;

        var newLeaf = new LeafPane { TerminalId = tid };
        var split = new SplitNode
        {
            First = oldLeaf,
            Second = newLeaf,
            Direction = dir,
        };

        if (tab.Root == oldLeaf)
            tab.Root = split;
        else
            ReplaceInTree(tab.Root, oldLeaf, split);

        tab.FocusedTerminalId = tid;
        SyncRenderLayout();
    }

    private void CloseActivePane()
    {
        if (_activeTabIndex < 0) return;
        var tab = _tabs[_activeTabIndex];

        if (tab.Root is LeafPane)
        {
            CloseTabAt(_activeTabIndex);
            return;
        }

        var leaf = FindLeaf(tab.Root, tab.FocusedTerminalId);
        if (leaf == null) return;

        var parent = FindParentSplit(tab.Root, leaf);
        if (parent == null) return;

        var sibling = parent.First == leaf ? parent.Second : parent.First;

        if (tab.Root == parent)
            tab.Root = sibling;
        else
            ReplaceInTree(tab.Root, parent, sibling);

        NativeMethods.sugarloaf_win_close_terminal(_engineHandle, leaf.TerminalId);

        var leaves = CollectLeaves(tab.Root);
        tab.FocusedTerminalId = leaves.First().TerminalId;
        SyncRenderLayout();
    }

    private void MoveFocusNext()
    {
        if (_activeTabIndex < 0) return;
        var tab = _tabs[_activeTabIndex];
        var leaves = CollectLeaves(tab.Root);
        if (leaves.Count <= 1) return;

        int idx = leaves.FindIndex(l => l.TerminalId == tab.FocusedTerminalId);
        int next = (idx + 1) % leaves.Count;
        tab.FocusedTerminalId = leaves[next].TerminalId;
    }

    // ── Tree helpers ──

    private static List<LeafPane> CollectLeaves(PaneNode node)
    {
        var result = new List<LeafPane>();
        CollectLeavesInner(node, result);
        return result;
    }

    private static void CollectLeavesInner(PaneNode node, List<LeafPane> result)
    {
        if (node is LeafPane leaf) result.Add(leaf);
        else if (node is SplitNode split)
        {
            CollectLeavesInner(split.First, result);
            CollectLeavesInner(split.Second, result);
        }
    }

    private static LeafPane? FindLeaf(PaneNode root, int terminalId)
    {
        if (root is LeafPane leaf && leaf.TerminalId == terminalId) return leaf;
        if (root is SplitNode split)
            return FindLeaf(split.First, terminalId) ?? FindLeaf(split.Second, terminalId);
        return null;
    }

    private static SplitNode? FindParentSplit(PaneNode root, PaneNode target)
    {
        if (root is SplitNode split)
        {
            if (split.First == target || split.Second == target)
                return split;
            return FindParentSplit(split.First, target)
                ?? FindParentSplit(split.Second, target);
        }
        return null;
    }

    private static bool ReplaceInTree(PaneNode root, PaneNode target, PaneNode replacement)
    {
        if (root is SplitNode split)
        {
            if (split.First == target) { split.First = replacement; return true; }
            if (split.Second == target) { split.Second = replacement; return true; }
            return ReplaceInTree(split.First, target, replacement)
                || ReplaceInTree(split.Second, target, replacement);
        }
        return false;
    }

    // ── Title polling ──

    private void OnTitleTick(object? sender, object e)
    {
        if (_engineHandle == IntPtr.Zero) return;

        foreach (var tab in _tabs)
        {
            IntPtr titlePtr = NativeMethods.sugarloaf_win_get_title(
                _engineHandle, tab.FocusedTerminalId);
            if (titlePtr == IntPtr.Zero) continue;

            string? title = Marshal.PtrToStringUTF8(titlePtr);
            NativeMethods.sugarloaf_win_free_string(titlePtr);

            if (!string.IsNullOrEmpty(title) && title != tab.Title)
            {
                tab.Title = title;
                tab.TitleTextBlock.Text = title;
            }
        }

        UpdateWindowTitle();
    }

    private void UpdateWindowTitle()
    {
        if (_activeTabIndex >= 0 && _activeTabIndex < _tabs.Count)
            this.Title = $"ETerm - {_tabs[_activeTabIndex].Title}";
    }

    // ── Cleanup ──

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _renderTimer?.Stop();
        _titleTimer?.Stop();
        _resizeTimer?.Stop();

        foreach (var tab in _tabs)
            foreach (var leaf in CollectLeaves(tab.Root))
                NativeMethods.sugarloaf_win_close_terminal(_engineHandle, leaf.TerminalId);
        _tabs.Clear();

        if (_engineHandle != IntPtr.Zero)
        {
            NativeMethods.sugarloaf_win_destroy(_engineHandle);
            _engineHandle = IntPtr.Zero;
        }
    }
}

// ── Pane tree data structures ──

enum SplitDirection { Vertical, Horizontal }

abstract class PaneNode { }

class LeafPane : PaneNode
{
    public int TerminalId { get; set; } = -1;
}

class SplitNode : PaneNode
{
    public PaneNode First { get; set; } = null!;
    public PaneNode Second { get; set; } = null!;
    public SplitDirection Direction { get; set; }
}

class TabState
{
    public PaneNode Root { get; set; } = null!;
    public int FocusedTerminalId { get; set; } = -1;
    public string Title { get; set; } = "";
    public Button TabButton { get; set; } = null!;
    public TextBlock TitleTextBlock { get; set; } = null!;
}

// ── COM interop for SwapChainPanel ──

[ComImport]
[Guid("63aad0b8-7c24-40ff-85a8-640d944cc325")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISwapChainPanelNative
{
    void SetSwapChain(IntPtr swapChain);
}

static partial class SwapChainPanelInterop
{
    private static readonly Guid IID_ISwapChainPanelNative =
        new("63aad0b8-7c24-40ff-85a8-640d944cc325");

    [DllImport("api-ms-win-core-winrt-l1-1-0.dll", PreserveSig = false)]
    private static extern void RoGetActivationFactory(
        [MarshalAs(UnmanagedType.HString)] string activatableClassId,
        ref Guid iid,
        out IntPtr factory);

    internal static void SetSwapChainOnPanel(
        SwapChainPanel panel, IntPtr swapChain)
    {
        IntPtr panelUnknown = Marshal.GetIUnknownForObject(panel);
        try
        {
            Guid iid = IID_ISwapChainPanelNative;
            Marshal.ThrowExceptionForHR(
                Marshal.QueryInterface(panelUnknown, ref iid, out IntPtr nativePtr));
            try
            {
                var native = (ISwapChainPanelNative)Marshal.GetObjectForIUnknown(nativePtr);
                native.SetSwapChain(swapChain);
            }
            finally
            {
                Marshal.Release(nativePtr);
            }
        }
        finally
        {
            Marshal.Release(panelUnknown);
        }
    }
}
