//
//  TabTerminalView.swift
//  ETerm
//
//  带 Tab 功能的终端视图 - 使用原生 SwiftUI TabView
//

import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine

/// 完整的终端管理器（包含 Sugarloaf 和多个 Tab）
class TerminalManagerNSView: NSView {
    private var sugarloaf: SugarloafWrapper?
    private var tabManager: TabManagerWrapper?
    private var updateTimer: Timer?
    private var hasRenderedFirstFrame = false
    private var scrollAccumulator: CGFloat = 0.0
    private var fontMetrics: SugarloafFontMetrics?

    // 公开属性供 SwiftUI 访问
    var tabIds: [Int] = []
    var activeTabId: Int = -1

    // 回调
    var onTabsChanged: (([Int]) -> Void)?
    var onActiveTabChanged: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setupView() {
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? 2.0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidBecomeKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initialize()
        }
    }

    private func initialize() {
        guard sugarloaf == nil, let window = window else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let windowScale = window.backingScaleFactor
        let layerScale = layer?.contentsScale ?? windowScale
        let screenScale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        let effectiveScale = max(screenScale, max(windowScale, layerScale))
        layer?.contentsScale = effectiveScale

        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)
        let displayHandle = windowHandle

        let scale = Float(effectiveScale)

        let PADDING_LEFT: Float = 10.0
        let PADDING_TOP: Float = 10.0
        let PADDING_RIGHT: Float = 10.0
        let PADDING_BOTTOM: Float = 10.0

        let widthPoints = Float(bounds.width) - PADDING_LEFT - PADDING_RIGHT
        let heightPoints = Float(bounds.height) - PADDING_TOP - PADDING_BOTTOM
        let widthPixels = widthPoints * scale
        let heightPixels = heightPoints * scale

        guard let sugarloaf = SugarloafWrapper(
            windowHandle: windowHandle,
            displayHandle: displayHandle,
            width: widthPixels,
            height: heightPixels,
            scale: scale,
            fontSize: 14.0
        ) else {
            return
        }

        self.sugarloaf = sugarloaf
        let fontSize: Float = 14.0

        let metricsInPixels = sugarloaf.fontMetrics ?? SugarloafFontMetrics(
            cell_width: fontSize * 0.6 * scale,
            cell_height: fontSize * 1.2 * scale,
            line_height: fontSize * 1.2 * scale
        )

        let metricsInPoints = SugarloafFontMetrics(
            cell_width: metricsInPixels.cell_width / scale,
            cell_height: metricsInPixels.cell_height / scale,
            line_height: metricsInPixels.line_height / scale
        )

        fontMetrics = metricsInPoints

        let (cols, rows) = calculateGridSize(
            widthPoints: widthPoints,
            heightPoints: heightPoints,
            metrics: metricsInPoints
        )

        guard let tabManager = TabManagerWrapper(
            sugarloaf: sugarloaf,
            cols: cols,
            rows: rows,
            shell: "/bin/zsh"
        ) else {
            return
        }

        self.tabManager = tabManager

        // 创建第一个 Tab
        createNewTab()

        startUpdateTimer()
        renderTerminal()
        needsDisplay = true
    }

    func createNewTab() {
        guard let tabManager = tabManager else { return }

        let newTabId = tabManager.createTab()
        if newTabId >= 0 {
            tabIds.append(newTabId)
            activeTabId = newTabId
            tabManager.setTabTitle(newTabId, title: "Shell")
            onTabsChanged?(tabIds)
            onActiveTabChanged?(activeTabId)
        }
    }

    func switchToTab(_ tabId: Int) {
        guard let tabManager = tabManager else { return }
        guard tabIds.contains(tabId) else { return }

        if tabManager.switchTab(tabId) {
            activeTabId = tabId
            onActiveTabChanged?(activeTabId)
            renderTerminal()
        }
    }

    private func startUpdateTimer() {
        let interval = 1.0 / 60.0
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateTerminal()
        }
    }

    private func updateTerminal() {
        guard let tabManager = tabManager else { return }

        let hasNewData = tabManager.readAllTabs()

        if !hasRenderedFirstFrame || hasNewData {
            renderTerminal()
            hasRenderedFirstFrame = true
        }
    }

    private func renderTerminal() {
        guard let tabManager = tabManager else { return }
        _ = tabManager.renderActiveTab()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let tabManager = tabManager else {
            super.scrollWheel(with: event)
            return
        }

        let deltaY: CGFloat

        if event.hasPreciseScrollingDeltas {
            deltaY = event.scrollingDeltaY
        } else {
            deltaY = event.deltaY
        }

        if deltaY == 0 {
            super.scrollWheel(with: event)
            return
        }

        scrollAccumulator += deltaY
        let threshold: CGFloat = 10.0

        while abs(scrollAccumulator) >= threshold {
            let direction: Int32 = scrollAccumulator > 0 ? 1 : -1
            tabManager.scrollActiveTab(direction)
            scrollAccumulator -= threshold * (scrollAccumulator > 0 ? 1 : -1)
        }

        renderTerminal()
    }

    override func keyDown(with event: NSEvent) {
        guard let tabManager = tabManager else {
            super.keyDown(with: event)
            return
        }

        if let characters = event.characters {
            if event.modifierFlags.contains(.control) && characters == "c" {
                tabManager.writeInput("\u{03}")
                return
            }

            if event.keyCode == 36 {  // Return
                tabManager.writeInput("\r")
                return
            }

            if event.keyCode == 51 {  // Delete
                tabManager.writeInput("\u{7F}")
                return
            }

            tabManager.writeInput(characters)
        }
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func layout() {
        super.layout()
        guard let tabManager else { return }

        let PADDING_LEFT: Float = 10.0
        let PADDING_TOP: Float = 10.0
        let PADDING_RIGHT: Float = 10.0
        let PADDING_BOTTOM: Float = 10.0

        let widthPoints = Float(bounds.width) - PADDING_LEFT - PADDING_RIGHT
        let heightPoints = Float(bounds.height) - PADDING_TOP - PADDING_BOTTOM

        let metricsInPoints = self.fontMetrics ?? fallbackMetrics(for: 14.0)

        let (cols, rows) = calculateGridSize(
            widthPoints: widthPoints,
            heightPoints: heightPoints,
            metrics: metricsInPoints
        )

        tabManager.resizeAllTabs(cols: cols, rows: rows)
        renderTerminal()
    }

    private func fallbackMetrics(for fontSize: Float) -> SugarloafFontMetrics {
        SugarloafFontMetrics(
            cell_width: fontSize * 0.6,
            cell_height: fontSize * 1.2,
            line_height: fontSize * 1.2
        )
    }

    private func calculateGridSize(
        widthPoints: Float,
        heightPoints: Float,
        metrics: SugarloafFontMetrics
    ) -> (UInt16, UInt16) {
        let width = max(widthPoints, 1.0)
        let height = max(heightPoints, 1.0)
        let charWidth = max(metrics.cell_width, 1.0)
        let lineHeight = max(metrics.line_height, 1.0)

        let rawCols = Int(width / charWidth)
        let rawRows = Int(height / lineHeight)
        let cols = max(2, rawCols)
        let rows = max(1, rawRows)

        let clampedCols = UInt16(min(cols, Int(UInt16.max)))
        let clampedRows = UInt16(min(rows, Int(UInt16.max)))
        return (clampedCols, clampedRows)
    }

    deinit {
        updateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

/// 终端管理器协调器 - 保持单例
class TerminalCoordinator: ObservableObject {
    static let shared = TerminalCoordinator()

    @Published var terminalView: TerminalManagerNSView?
    @Published var tabIds: [Int] = []
    @Published var activeTabId: Int = -1

    private init() {}

    func setTerminalView(_ view: TerminalManagerNSView) {
        self.terminalView = view
        view.onTabsChanged = { [weak self] ids in
            DispatchQueue.main.async {
                self?.tabIds = ids
            }
        }
        view.onActiveTabChanged = { [weak self] id in
            DispatchQueue.main.async {
                self?.activeTabId = id
            }
        }
    }
}

/// SwiftUI 包装器 - 单例视图
struct TerminalManagerView: NSViewRepresentable {
    @ObservedObject var coordinator = TerminalCoordinator.shared

    func makeNSView(context: Context) -> TerminalManagerNSView {
        // 如果已有实例，直接返回
        if let existingView = coordinator.terminalView {
            return existingView
        }

        // 创建新实例
        let view = TerminalManagerNSView()
        coordinator.setTerminalView(view)
        return view
    }

    func updateNSView(_ nsView: TerminalManagerNSView, context: Context) {
        // 不需要做什么，状态由 coordinator 管理
    }
}

/// 使用原生 SwiftUI TabView 的终端视图
struct TabTerminalView: View {
    @ObservedObject var coordinator = TerminalCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            if !coordinator.tabIds.isEmpty {
                HStack {
                    Button(action: createNewTab) {
                        Label("新建 Tab", systemImage: "plus")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("⌘T")

                    Spacer()

                    Text("\(coordinator.tabIds.count) tab\(coordinator.tabIds.count > 1 ? "s" : "")")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(8)
                .background(Color.clear)
            }

            // 终端内容
            ZStack {
                // 始终显示终端管理器视图（在后台）
                TerminalManagerView()

                // TabView 只用于显示 tab 栏，不显示内容
                if !coordinator.tabIds.isEmpty {
                    TabView(selection: Binding(
                        get: { coordinator.activeTabId },
                        set: { newId in
                            coordinator.terminalView?.switchToTab(newId)
                        }
                    )) {
                        ForEach(coordinator.tabIds, id: \.self) { tabId in
                            Color.clear
                                .tabItem {
                                    if let index = coordinator.tabIds.firstIndex(of: tabId) {
                                        Text("Tab \(index + 1)")
                                    }
                                }
                                .tag(tabId)
                        }
                    }
                    .tabViewStyle(.automatic)
                }
            }
        }
    }

    private func createNewTab() {
        coordinator.terminalView?.createNewTab()
    }
}

// MARK: - Preview
struct TabTerminalView_Previews: PreviewProvider {
    static var previews: some View {
        TabTerminalView()
            .frame(width: 800, height: 600)
    }
}
