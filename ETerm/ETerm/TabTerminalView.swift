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

/// 分隔线类型
enum PaneDividerType {
    case vertical    // 垂直（左右分割）
    case horizontal  // 水平（上下分割）
}

/// 分隔线信息
struct PaneDivider {
    let paneId1: Int
    let paneId2: Int
    let type: PaneDividerType
    let position: CGFloat  // 逻辑坐标
}

/// 完整的终端管理器（包含 Sugarloaf 和多个 Tab）
class TerminalManagerNSView: NSView {
    private var sugarloaf: SugarloafWrapper?
    var tabManager: TabManagerWrapper?  // 改为 internal，供 Split 功能访问
    private var displayLink: CVDisplayLink?
    private var needsRender = false
    private let renderLock = NSLock()  // 保护 needsRender 标记
    private var scrollAccumulator: CGFloat = 0.0
    private var fontMetrics: SugarloafFontMetrics?
    private var lastResizePixels: (width: Float, height: Float) = (0, 0)
    private var lastScale: Float = 0.0
    private var ptyReadQueue: DispatchQueue?  // 后台队列用于读取 PTY
    private var shouldStopReading = false

    // 公开属性供 SwiftUI 访问
    var tabIds: [Int] = []
    var activeTabId: Int = -1

    // 回调
    var onTabsChanged: (([Int]) -> Void)?
    var onActiveTabChanged: ((Int) -> Void)?

    // 🎯 分隔线拖动相关
    private var isDraggingDivider = false
    private var draggingDivider: PaneDivider?
    private var dragStartLocation: CGPoint = .zero
    private var currentHoverDivider: PaneDivider?

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

        // 🎯 启用鼠标移动追踪（用于检测分隔线悬停）
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    // 🎯 确保 view 可以接收鼠标事件
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
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

        // 不再手动扣除 padding，SwiftUI 层面已经通过 .padding() 处理了
        let widthPoints = Float(bounds.width)
        let heightPoints = Float(bounds.height)
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
        self.lastResizePixels = (widthPixels, heightPixels)  // 记录初始尺寸
        self.lastScale = scale  // 记录初始缩放
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

        // 设置渲染回调
        tabManager.setRenderCallback { [weak self] in
            guard let self = self else { return }
            self.renderLock.lock()
            self.needsRender = true
            self.renderLock.unlock()
        }

        // 创建第一个 Tab
        createNewTab()

        // 启动 CVDisplayLink (替代 Timer)
        setupDisplayLink()

        // 启动后台 PTY 读取线程
        startPTYReadLoop()

        // 初始渲染
        renderTerminal()
        needsDisplay = true
    }

    /// 启动后台 PTY 读取循环
    private func startPTYReadLoop() {
        let queue = DispatchQueue(label: "com.eterm.pty-reader", qos: .userInteractive)
        self.ptyReadQueue = queue

        queue.async { [weak self] in
            guard let self = self else { return }

            print("[PTY Reader] ✅ Background read loop started")

            while !self.shouldStopReading {
                // 读取所有 Tab 的 PTY 输出
                // readAllTabs() 内部会在有数据时调用渲染回调
                self.tabManager?.readAllTabs()

                // 短暂休眠,避免过度占用 CPU (可以调整这个值)
                usleep(1000)  // 1ms
            }

            print("[PTY Reader] ✅ Background read loop stopped")
        }
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
            requestRender()
        }
    }

    /// 设置 CVDisplayLink (替代 Timer 轮询)
    private func setupDisplayLink() {
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard status == kCVReturnSuccess, let displayLink = link else {
            print("[CVDisplayLink] ❌ Failed to create CVDisplayLink: \(status)")
            return
        }

        // 设置回调
        let callbackContext = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, context) -> CVReturn in
            guard let context = context else { return kCVReturnSuccess }

            let view = Unmanaged<TerminalManagerNSView>.fromOpaque(context).takeUnretainedValue()

            // 检查是否需要渲染
            view.renderLock.lock()
            let shouldRender = view.needsRender
            if shouldRender {
                view.needsRender = false
            }
            view.renderLock.unlock()

            // 在主线程执行渲染
            if shouldRender {
                DispatchQueue.main.async {
                    view.performRender()
                }
            }

            return kCVReturnSuccess
        }, callbackContext)

        // 启动 CVDisplayLink
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink

        print("[CVDisplayLink] ✅ Started successfully")
    }

    /// 标记需要渲染 (线程安全)
    private func requestRender() {
        renderLock.lock()
        needsRender = true
        renderLock.unlock()
    }

    /// 执行实际的渲染 (必须在主线程调用)
    private func performRender() {
        guard let tabManager = tabManager else { return }
        _ = tabManager.renderActiveTab()
    }

    func renderTerminal() {  // 改为 internal，供 Split 功能访问(兼容旧代码)
        requestRender()
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

        // 🎯 获取鼠标位置（逻辑坐标）
        let locationInView = convert(event.locationInWindow, from: nil)
        let x = Float(locationInView.x)
        let y = Float(locationInView.y)

        // 查找鼠标下的 pane
        let paneId = tab_manager_get_pane_at_position(tabManager.handle, x, y)

        scrollAccumulator += deltaY
        let threshold: CGFloat = 10.0

        while abs(scrollAccumulator) >= threshold {
            let direction: Int32 = scrollAccumulator > 0 ? 1 : -1

            if paneId >= 0 {
                // 🎯 滚动鼠标下的 pane（不改变焦点）
                tab_manager_scroll_pane(tabManager.handle, size_t(paneId), direction)
            } else {
                // 鼠标不在任何 pane 上（例如在 padding 区域），滚动激活的 pane
                tabManager.scrollActiveTab(direction)
            }

            scrollAccumulator -= threshold * (scrollAccumulator > 0 ? 1 : -1)
        }

        requestRender()
    }

    // 🎯 检查鼠标位置是否在分隔线上
    private func findDividerAtPosition(x: CGFloat, y: CGFloat, tolerance: CGFloat = 5.0) -> PaneDivider? {
        guard let tabManager = tabManager else { return nil }

        // 获取所有分隔线（使用 C struct）
        var dividersArray = Array(repeating: DividerInfo(pane_id_1: 0, pane_id_2: 0, divider_type: 0, position: 0), count: 10)
        let count = tab_manager_get_dividers(tabManager.handle, &dividersArray, 10)

        guard count > 0 else { return nil }

        // 检查每条分隔线
        for i in 0..<count {
            let dividerInfo = dividersArray[i]
            let position = CGFloat(dividerInfo.position)

            if dividerInfo.divider_type == 0 {
                // 垂直分隔线（检查 x 坐标）
                if abs(x - position) <= tolerance {
                    return PaneDivider(
                        paneId1: Int(dividerInfo.pane_id_1),
                        paneId2: Int(dividerInfo.pane_id_2),
                        type: .vertical,
                        position: position
                    )
                }
            } else {
                // 水平分隔线（检查 y 坐标）
                if abs(y - position) <= tolerance {
                    return PaneDivider(
                        paneId1: Int(dividerInfo.pane_id_1),
                        paneId2: Int(dividerInfo.pane_id_2),
                        type: .horizontal,
                        position: position
                    )
                }
            }
        }

        return nil
    }

    // 🎯 鼠标移动：检测是否悬停在分隔线上
    override func mouseMoved(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)

        if let divider = findDividerAtPosition(x: locationInView.x, y: locationInView.y) {
            // 鼠标在分隔线上，改变鼠标样式
            if divider.type == .vertical {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.resizeUpDown.set()
            }
            currentHoverDivider = divider
        } else {
            // 鼠标不在分隔线上，恢复箭头
            NSCursor.arrow.set()
            currentHoverDivider = nil
        }

        super.mouseMoved(with: event)
    }

    // 🎯 鼠标按下：开始拖动分隔线或切换焦点
    override func mouseDown(with event: NSEvent) {
        guard let tabManager = tabManager else {
            super.mouseDown(with: event)
            return
        }

        let locationInView = convert(event.locationInWindow, from: nil)
        let x = Float(locationInView.x)
        let y = Float(locationInView.y)

        // 🎯 优先检查是否点击在分隔线上
        if let divider = findDividerAtPosition(x: CGFloat(x), y: CGFloat(y)) {
            isDraggingDivider = true
            draggingDivider = divider
            dragStartLocation = locationInView
            print("[Divider] 🖱️ Started dragging \(divider.type) divider at \(divider.position)")
            return
        }

        // 否则切换 pane 焦点
        let paneId = tab_manager_get_pane_at_position(tabManager.handle, x, y)
        if paneId >= 0 {
            tab_manager_set_active_pane(tabManager.handle, size_t(paneId))
            requestRender()
        }

        super.mouseDown(with: event)
    }

    // 🎯 鼠标拖拽：拖动分隔线
    override func mouseDragged(with event: NSEvent) {
        guard isDraggingDivider, let divider = draggingDivider, let tabManager = tabManager else {
            super.mouseDragged(with: event)
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)

        // 计算拖动偏移量（逻辑坐标）
        let delta: Float
        if divider.type == .vertical {
            delta = Float(currentLocation.x - dragStartLocation.x)
        } else {
            // macOS 坐标系 Y 轴向上，需要反转：向下拖动（Y减小）应该让上面 pane 变大
            delta = Float(dragStartLocation.y - currentLocation.y)
        }

        print("[Divider] 🎯 Drag delta: \(delta), current: \(currentLocation), start: \(dragStartLocation), scale: \(window?.backingScaleFactor ?? 1.0)")

        // 调用 Rust FFI 调整分隔线
        let success = tab_manager_resize_divider(
            tabManager.handle,
            size_t(divider.paneId1),
            size_t(divider.paneId2),
            delta
        )

        if success != 0 {
            // 更新起始位置（累积拖动）
            dragStartLocation = currentLocation

            // 触发重新渲染
            requestRender()
        }

        // 不调用 super，避免其他拖动行为
    }

    // 🎯 鼠标松开：结束拖动
    override func mouseUp(with event: NSEvent) {
        if isDraggingDivider {
            isDraggingDivider = false
            draggingDivider = nil
            print("[Divider] ✅ Finished dragging")

            // 恢复鼠标样式
            NSCursor.arrow.set()
        }

        super.mouseUp(with: event)
    }

    // 🎯 辅助函数：全局坐标 → 终端网格坐标（相对于 Pane）
    private func pixelToGridCoords(
        globalX: Float,
        globalY: Float,
        paneX: Float,
        paneY: Float,
        metrics: SugarloafFontMetrics
    ) -> (UInt16, UInt16) {
        // 1️⃣ 转换为 Pane 内的相对坐标
        let relativeX = globalX - paneX
        let relativeY = globalY - paneY

        // 2️⃣ 扣除 padding（每个 Pane 内部有 10pt padding）
        let adjustedX = max(0, relativeX - 10.0)
        let adjustedY = max(0, relativeY - 10.0)

        // 3️⃣ 转换为网格坐标
        // metrics 已经是 points（逻辑坐标），不需要除以 scale
        let col = UInt16(adjustedX / metrics.cell_width)
        let row = UInt16(adjustedY / metrics.line_height)

        // 调试输出
        print("[Coords] Global: (\(globalX), \(globalY)) -> Pane: (\(paneX), \(paneY)) -> Relative: (\(relativeX), \(relativeY)) -> Grid: (\(col), \(row))")

        return (col, row)
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
        guard let tabManager, let sugarloaf else { return }

        // 不再手动扣除 padding，SwiftUI 层面已经通过 .padding() 处理了
        let widthPoints = Float(bounds.width)
        let heightPoints = Float(bounds.height)

        // 1️⃣ 检测 scale 和尺寸变化
        let scale = Float(window?.backingScaleFactor ?? 2.0)
        let widthPixels = widthPoints * scale
        let heightPixels = heightPoints * scale

        let scaleChanged = abs(scale - lastScale) > 0.01
        let sizeChanged = abs(widthPixels - lastResizePixels.width) > 1.0 ||
                         abs(heightPixels - lastResizePixels.height) > 1.0

        // 先处理 scale 变化（DPI 变化，如切换显示器）
        if scaleChanged {
            print("[TabTerminalView] 🔄 Scale changed from \(lastScale) to \(scale) - rescaling")
            sugarloaf.rescale(scale: scale)
            lastScale = scale
        }

        // 再处理尺寸变化
        if sizeChanged || scaleChanged {
            print("[TabTerminalView] layout() - bounds: \(bounds.width)x\(bounds.height), scale: \(scale)")
            print("[TabTerminalView] layout() - resizing Sugarloaf to: \(widthPixels)x\(heightPixels) pixels")
            sugarloaf.resize(width: widthPixels, height: heightPixels)
            lastResizePixels = (widthPixels, heightPixels)
        }

        // 2️⃣ 再通知 Terminal 调整网格尺寸（行列）
        let metricsInPoints = self.fontMetrics ?? fallbackMetrics(for: 14.0)

        let (cols, rows) = calculateGridSize(
            widthPoints: widthPoints,
            heightPoints: heightPoints,
            metrics: metricsInPoints
        )

        tabManager.resizeAllTabs(cols: cols, rows: rows)
        requestRender()
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
        // 停止后台读取循环
        shouldStopReading = true

        // 停止并释放 CVDisplayLink
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            print("[CVDisplayLink] ✅ Stopped")
        }

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

                    Divider()
                        .frame(height: 20)

                    Button(action: splitRight) {
                        Label("垂直分割", systemImage: "rectangle.split.2x1")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("⌘D - 垂直分割")

                    Button(action: splitDown) {
                        Label("水平分割", systemImage: "rectangle.split.1x2")
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .help("⌘⇧D - 水平分割")

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
                // 背景图片层（最底层）
                GeometryReader { geometry in
                    Image("night")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(0.3)  // 高透明度
                }
                .ignoresSafeArea()

                // 始终显示终端管理器视图（在背景之上）
                GeometryReader { geometry in
                    TerminalManagerView()
                        .padding(10)  // 添加 10pt 的内边距
                        .contentShape(Rectangle())  // 确保整个区域可以接收点击
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    handlePaneClick(at: value.location, in: geometry)
                                }
                        )
                }

                // 🧪 临时注释掉 TabView 测试点击事件
                // TabView 只用于显示 tab 栏，不显示内容
//                if !coordinator.tabIds.isEmpty {
//                    TabView(selection: Binding(
//                        get: { coordinator.activeTabId },
//                        set: { newId in
//                            coordinator.terminalView?.switchToTab(newId)
//                        }
//                    )) {
//                        ForEach(coordinator.tabIds, id: \.self) { tabId in
//                            Color.clear
//                                .tabItem {
//                                    if let index = coordinator.tabIds.firstIndex(of: tabId) {
//                                        Text("Tab \(index + 1)")
//                                    }
//                                }
//                                .tag(tabId)
//                        }
//                    }
//                    .tabViewStyle(.automatic)
//                }
            }
        }
    }

    private func createNewTab() {
        coordinator.terminalView?.createNewTab()
    }

    // 🎯 处理 Pane 点击切换焦点
    private func handlePaneClick(at location: CGPoint, in geometry: GeometryProxy) {
        print("[TabTerminalView] 🖱️ Click detected at: \(location)")

        guard let terminalView = coordinator.terminalView,
              let tabManager = terminalView.tabManager else {
            print("[TabTerminalView] ⚠️ No terminal view or tab manager")
            return
        }

        // 调整坐标（需要减去 padding）
        let x = Float(location.x - 10)  // 减去 padding
        let y = Float(location.y - 10)

        print("[TabTerminalView] Adjusted coords: (\(x), \(y))")
        print("[TabTerminalView] Geometry size: \(geometry.size)")
        print("[TabTerminalView] Current pane count: \(tab_manager_get_pane_count(tabManager.handle))")

        // 查找点击的 pane
        let paneId = tab_manager_get_pane_at_position(tabManager.handle, x, y)
        print("[TabTerminalView] Found pane ID: \(paneId)")

        if paneId >= 0 {
            // 切换焦点
            let result = tab_manager_set_active_pane(tabManager.handle, size_t(paneId))
            print("[TabTerminalView] Set active pane result: \(result)")

            if result != 0 {
                print("[TabTerminalView] ✅ Switched focus to pane \(paneId)")
                terminalView.renderTerminal()
            } else {
                print("[TabTerminalView] ❌ Failed to switch focus")
            }
        } else {
            print("[TabTerminalView] ❌ No pane found at this position")
        }
    }

    private func splitRight() {
        print("[Split] splitRight() called")
        guard let tabManager = coordinator.terminalView?.tabManager else {
            print("[Split] ERROR: tabManager is nil")
            return
        }
        print("[Split] Calling tabManager.splitRight()")
        let newPaneId = tabManager.splitRight()
        print("[Split] splitRight returned paneId: \(newPaneId)")

        if newPaneId >= 0 {
            let paneCount = tabManager.getPaneCount()
            print("[Split] ✅ Created right pane with ID: \(newPaneId), total panes: \(paneCount)")
            // 触发重新渲染
            coordinator.terminalView?.renderTerminal()
        } else {
            print("[Split] ❌ Failed to create right pane")
        }
    }

    private func splitDown() {
        print("[Split] splitDown() called")
        guard let tabManager = coordinator.terminalView?.tabManager else {
            print("[Split] ERROR: tabManager is nil")
            return
        }
        print("[Split] Calling tabManager.splitDown()")
        let newPaneId = tabManager.splitDown()
        print("[Split] splitDown returned paneId: \(newPaneId)")

        if newPaneId >= 0 {
            let paneCount = tabManager.getPaneCount()
            print("[Split] ✅ Created down pane with ID: \(newPaneId), total panes: \(paneCount)")
            // 触发重新渲染
            coordinator.terminalView?.renderTerminal()
        } else {
            print("[Split] ❌ Failed to create down pane")
        }
    }
}

// MARK: - Preview
struct TabTerminalView_Previews: PreviewProvider {
    static var previews: some View {
        TabTerminalView()
            .frame(width: 800, height: 600)
    }
}
