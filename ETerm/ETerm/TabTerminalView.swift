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

// MARK: - Forward Declaration
class DividerOverlayView: NSView {
    // 🎯 使用真正的存储属性，而不是 associated objects
    weak var controller: WindowController?
    var onDividerDragged: (() -> Void)?

    // 拖动状态
    private var isDraggingDivider: Bool = false
    private var draggingDivider: PanelDivider?
    private var currentHoverDivider: PanelDivider?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
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

    // WindowController 引用 (用于分隔线拖动)
    weak var controller: WindowController?

    // 🎯 分隔线 overlay 视图引用
    weak var dividerOverlay: DividerOverlayView?

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

        // ❌ 临时禁用：等待 Swift 实现 pane 位置查询
        // let locationInView = convert(event.locationInWindow, from: nil)
        // let x = Float(locationInView.x)
        // let y = Float(locationInView.y)
        // let paneId = tab_manager_get_pane_at_position(tabManager.handle, x, y)

        scrollAccumulator += deltaY
        let threshold: CGFloat = 10.0

        while abs(scrollAccumulator) >= threshold {
            let direction: Int32 = scrollAccumulator > 0 ? 1 : -1

            // 暂时总是滚动激活的 pane
            tabManager.scrollActiveTab(direction)

            scrollAccumulator -= threshold * (scrollAccumulator > 0 ? 1 : -1)
        }

        requestRender()
    }

    // 🎯 辅助函数：全局坐标 → 终端网格坐标（相对于 Pane）
    private func pixelToGridCoords(
        globalX: Float,
        globalY: Float,
        paneX: Float,
        paneY: Float,
        paneHeight: Float,  // 🎯 新增：Pane 的高度
        metrics: SugarloafFontMetrics
    ) -> (UInt16, UInt16) {
        // 1️⃣ 转换为 Pane 内的相对坐标（NSView 左下角原点）
        let relativeX = globalX - paneX
        let relativeY = globalY - paneY

        // 2️⃣ 扣除 padding（测试：暂时不扣除 padding）
        let adjustedX = max(0, relativeX - 0.0)
        let adjustedY = max(0, relativeY - 0.0)

        // 3️⃣ 转换为网格坐标
        // X 轴：直接向下取整
        let col = UInt16(adjustedX / metrics.cell_width)

        // 🎯 Y 轴：需要翻转
        // NSView: Y 向上递增（左下角原点）
        // 终端: row 向下递增（第一行是 row=0）
        let contentHeight = paneHeight - 0.0  // 测试：暂时不扣除 padding
        let yFromTop = contentHeight - adjustedY  // 从顶部的距离
        let row = UInt16(max(0, yFromTop / metrics.line_height))

        // 调试输出
        print("""
        [Coords] Global: (\(globalX), \(globalY))
                 Pane: (\(paneX), \(paneY), h=\(paneHeight))
                 Relative: (\(relativeX), \(relativeY))
                 Adjusted: (\(adjustedX), \(adjustedY))
                 yFromTop: \(yFromTop)
                 Metrics: cell=(\(metrics.cell_width), \(metrics.line_height))
                 Grid: (\(col), \(row))
        """)

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

    // 🎯 新增：controller 引用（用于拖动时更新配置）
    weak var controller: WindowController?

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

    /// 设置分隔线 overlay 的回调
    func setupDividerOverlay(_ overlay: DividerOverlayView) {
        overlay.onDividerDragged = { [weak self] in
            self?.updateRustConfigs()
        }
    }

    /// 更新 Rust 配置（从 TabTerminalView 提取）
    func updateRustConfigs() {
        guard let terminalView = terminalView,
              let tabManager = terminalView.tabManager,
              let controller = controller else {
            return
        }

        let configs = controller.panelRenderConfigs

        for (panelId, config) in configs {
            let rustPanelId = controller.registerPanel(panelId)

            tab_manager_update_panel_config(
                tabManager.handle,
                size_t(rustPanelId),
                config.x,
                config.y,
                config.width,
                config.height,
                config.cols,
                config.rows
            )
        }

        // 触发重新渲染
        terminalView.renderTerminal()

        // 触发分隔线 overlay 重绘
        terminalView.dividerOverlay?.needsDisplay = true
    }
}

// MARK: - Divider Overlay Implementation

/// 分隔线绘制视图（Overlay）
extension DividerOverlayView {
    // 所有属性都已在类定义中声明为真正的存储属性
    // 不再需要 associated objects

    // 🎯 关键：让 overlay 只响应分隔线区域的点击
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查点击位置是否在分隔线附近
        guard let controller = controller else {
            return nil  // 没有 controller，不响应任何点击
        }

        let containerBounds = CGRect(origin: .zero, size: controller.containerSize)
        let dividers = controller.panelDividers

        // 如果点击位置在任何一条分隔线附近，返回自己
        for divider in dividers {
            if divider.contains(point: point, in: containerBounds, tolerance: 5.0) {
                return self  // 响应此点击
            }
        }

        // 否则返回 nil，让事件穿透到下层视图
        return nil
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的 tracking area
        trackingAreas.forEach { removeTrackingArea($0) }

        // 添加新的 tracking area
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    // MARK: - Mouse Events

    /// 查找鼠标位置处的分隔线
    private func findDividerAtPosition(_ location: CGPoint) -> PanelDivider? {
        guard let controller = controller else { return nil }

        let containerBounds = CGRect(origin: .zero, size: controller.containerSize)
        return controller.panelDividers.first { divider in
            divider.contains(point: location, in: containerBounds, tolerance: 5.0)
        }
    }

    /// 鼠标移动 - 检测分隔线悬停
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if let divider = findDividerAtPosition(location) {
            print("[DividerOverlay] 🖱️ Hovering over \(divider.direction) divider")
            // 设置光标
            switch divider.direction {
            case .horizontal:
                NSCursor.resizeLeftRight.set()
            case .vertical:
                NSCursor.resizeUpDown.set()
            }

            currentHoverDivider = divider
        } else {
            if currentHoverDivider != nil {
                print("[DividerOverlay] ⬅️ Left divider area, resetting cursor")
                NSCursor.arrow.set()
                currentHoverDivider = nil
            }
        }

        super.mouseMoved(with: event)
    }

    /// 鼠标退出视图 - 恢复光标
    override func mouseExited(with event: NSEvent) {
        print("[DividerOverlay] 🚪 Mouse exited view")
        NSCursor.arrow.set()
        currentHoverDivider = nil
        super.mouseExited(with: event)
    }

    /// 鼠标按下 - 开始拖动分隔线
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        print("[DividerOverlay] 🖱️ mouseDown at: \(location)")

        if let divider = findDividerAtPosition(location) {
            print("[DividerOverlay] ✅ Start dragging \(divider.direction) divider")
            isDraggingDivider = true
            draggingDivider = divider
            return
        }

        print("[DividerOverlay] ⚠️ No divider found at click position")
        super.mouseDown(with: event)
    }

    /// 鼠标拖拽 - 更新分隔线位置
    override func mouseDragged(with event: NSEvent) {
        guard isDraggingDivider,
              let divider = draggingDivider,
              let controller = controller else {
            print("[DividerOverlay] ⚠️ mouseDragged but not dragging or no controller")
            super.mouseDragged(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)

        // 计算新位置
        let newPosition: CGFloat
        switch divider.direction {
        case .horizontal:
            newPosition = location.x
        case .vertical:
            newPosition = location.y
        }

        print("[DividerOverlay] 📏 Dragging to: \(newPosition)")

        // 更新分隔线比例
        controller.updateDivider(divider, newPosition: newPosition)

        // 触发回调，通知上层更新 Rust 配置
        onDividerDragged?()

        // 触发重绘
        needsDisplay = true
    }

    /// 鼠标松开 - 结束拖动
    override func mouseUp(with event: NSEvent) {
        if isDraggingDivider {
            print("[DividerOverlay] ✅ Drag ended")
            isDraggingDivider = false
            draggingDivider = nil
            return
        }

        super.mouseUp(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let controller = controller else {
            print("[DividerOverlay] ⚠️ draw: no controller")
            return
        }

        let containerSize = controller.containerSize

        // 🎯 调试标尺：绘制坐标网格
        drawDebugRuler(containerSize: containerSize)

        // 🎯 调试：绘制 Panel 边界和坐标信息
        drawPanelBounds(controller: controller)

        // 绘制分隔线
        let dividers = controller.panelDividers
        print("[DividerOverlay] 🎨 draw: found \(dividers.count) dividers")

        // 设置绘制颜色为更明显的颜色用于测试
        NSColor.systemRed.setFill()
        let dividerWidth: CGFloat = 3.0  // 暂时用粗一点的线便于观察

        for (index, divider) in dividers.enumerated() {
            let rect: NSRect

            switch divider.direction {
            case .horizontal:
                // 垂直分隔线（左右分割）
                rect = NSRect(
                    x: divider.position - dividerWidth / 2,
                    y: 0,
                    width: dividerWidth,
                    height: containerSize.height
                )

            case .vertical:
                // 水平分隔线（上下分割）
                rect = NSRect(
                    x: 0,
                    y: divider.position - dividerWidth / 2,
                    width: containerSize.width,
                    height: dividerWidth
                )
            }

            print("[DividerOverlay] 🖍️ Drawing divider \(index): \(divider.direction) at \(divider.position), rect: \(rect)")
            rect.fill()
        }
    }

    // MARK: - Debug Drawing

    /// 绘制调试标尺：显示坐标网格
    private func drawDebugRuler(containerSize: CGSize) {
        // 网格线颜色：淡蓝色
        NSColor.systemBlue.withAlphaComponent(0.3).setStroke()

        let path = NSBezierPath()
        path.lineWidth = 0.5

        // 垂直线：每 100pt 一条
        var x: CGFloat = 0
        while x <= containerSize.width {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: containerSize.height))

            // 绘制 X 坐标标签
            drawCoordinateLabel(text: "x=\(Int(x))", at: NSPoint(x: x + 2, y: containerSize.height - 20), color: .systemBlue)

            x += 100
        }

        // 水平线：每 100pt 一条
        var y: CGFloat = 0
        while y <= containerSize.height {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: containerSize.width, y: y))

            // 绘制 Y 坐标标签
            drawCoordinateLabel(text: "y=\(Int(y))", at: NSPoint(x: 5, y: y + 2), color: .systemBlue)

            y += 100
        }

        path.stroke()

        // 特殊标记：关键坐标点
        drawKeyPoint(at: NSPoint(x: 0, y: 0), label: "(0,0) 左下角")
        drawKeyPoint(at: NSPoint(x: 0, y: containerSize.height), label: "(0,\(Int(containerSize.height))) 左上角")
        drawKeyPoint(at: NSPoint(x: containerSize.width, y: 0), label: "(\(Int(containerSize.width)),0) 右下角")
        drawKeyPoint(at: NSPoint(x: containerSize.width, y: containerSize.height), label: "(\(Int(containerSize.width)),\(Int(containerSize.height))) 右上角")
    }

    /// 绘制 Panel 边界和坐标信息
    private func drawPanelBounds(controller: WindowController) {
        let panelBounds = controller.panelBounds
        let panelConfigs = controller.panelRenderConfigs

        let colors: [NSColor] = [.systemGreen, .systemOrange, .systemPurple, .systemPink]
        var colorIndex = 0

        for (panelId, bounds) in panelBounds {
            let color = colors[colorIndex % colors.count]
            colorIndex += 1

            // 绘制 Panel 边界矩形
            color.withAlphaComponent(0.2).setStroke()
            let borderPath = NSBezierPath(rect: NSRect(
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height
            ))
            borderPath.lineWidth = 2.0
            borderPath.stroke()

            // 获取传给 Rust 的配置
            if let config = panelConfigs[panelId] {
                let rustPanelId = controller.getRustPanelId(panelId) ?? 0

                // 在 Panel 中心显示信息
                let centerX = bounds.x + bounds.width / 2
                let centerY = bounds.y + bounds.height / 2

                let info = """
                Panel \(rustPanelId)
                Swift: (\(Int(bounds.x)), \(Int(bounds.y)))
                Size: \(Int(bounds.width))x\(Int(bounds.height))
                Rust: (\(Int(config.x)), \(Int(config.y)))
                Grid: \(config.cols)x\(config.rows)
                """

                drawMultilineLabel(text: info, at: NSPoint(x: centerX - 100, y: centerY), color: color)
            }

            // 标注四个角
            drawCornerMarker(at: NSPoint(x: bounds.x, y: bounds.y), label: "左下", color: color)
            drawCornerMarker(at: NSPoint(x: bounds.x, y: bounds.y + bounds.height), label: "左上", color: color)
            drawCornerMarker(at: NSPoint(x: bounds.x + bounds.width, y: bounds.y), label: "右下", color: color)
            drawCornerMarker(at: NSPoint(x: bounds.x + bounds.width, y: bounds.y + bounds.height), label: "右上", color: color)
        }
    }

    /// 绘制坐标标签
    private func drawCoordinateLabel(text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: color
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        attributedString.draw(at: point)
    }

    /// 绘制多行文本标签
    private func drawMultilineLabel(text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        attributedString.draw(at: point)
    }

    /// 绘制关键坐标点
    private func drawKeyPoint(at point: NSPoint, label: String) {
        // 绘制圆点
        NSColor.systemRed.setFill()
        let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        circle.fill()

        // 绘制标签
        drawCoordinateLabel(text: label, at: NSPoint(x: point.x + 5, y: point.y + 5), color: .systemRed)
    }

    /// 绘制角标记
    private func drawCornerMarker(at point: NSPoint, label: String, color: NSColor) {
        color.setFill()
        let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
        circle.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: color
        ]
        let attributedString = NSAttributedString(string: label, attributes: attributes)
        attributedString.draw(at: NSPoint(x: point.x + 3, y: point.y + 3))
    }
}

/// SwiftUI 包装器 - 单例视图
struct TerminalManagerView: NSViewRepresentable {
    @ObservedObject var coordinator = TerminalCoordinator.shared
    let controller: WindowController

    func makeNSView(context: Context) -> NSView {
        print("[TerminalManagerView] makeNSView called")

        // 如果已有实例，直接返回容器
        if let existingView = coordinator.terminalView,
           let existingContainer = existingView.superview {
            print("[TerminalManagerView] Reusing existing view")
            existingView.controller = controller

            // 更新已有的 overlay
            if let overlay = existingView.dividerOverlay {
                overlay.controller = controller
                print("[TerminalManagerView] ✅ Updated existing overlay controller")
            }

            return existingContainer
        }

        print("[TerminalManagerView] Creating new view")

        // 创建新实例
        let terminalView = TerminalManagerNSView()
        terminalView.controller = controller
        coordinator.setTerminalView(terminalView)

        return createContainerView(with: terminalView)
    }

    private func createContainerView(with terminalView: TerminalManagerNSView) -> NSView {
        let container = NSView()

        // 添加终端视图
        terminalView.frame = container.bounds
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)

        // 添加分隔线 overlay
        let overlayView = DividerOverlayView(frame: container.bounds)
        overlayView.controller = controller
        overlayView.autoresizingMask = [.width, .height]
        container.addSubview(overlayView)

        print("[TerminalManagerView] ✅ Created new overlay with controller")

        // 保存 overlay 引用以便后续更新
        terminalView.dividerOverlay = overlayView

        // 🎯 设置 overlay 的拖动回调
        coordinator.setupDividerOverlay(overlayView)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 确保 controller 引用是最新的
        // nsView 是 container，包含 terminalView 和 overlayView
        print("[TerminalManagerView] updateNSView: subviews count = \(nsView.subviews.count)")

        // 🎯 关键修复：从实际的 view bounds 更新 containerSize
        let actualSize = nsView.bounds.size
        let currentSize = controller.containerSize
        if actualSize != currentSize && actualSize.width > 0 && actualSize.height > 0 {
            if let window = nsView.window {
                let scale = window.backingScaleFactor
                print("[TerminalManagerView] 📏 Updating containerSize from \(currentSize) to \(actualSize), scale=\(scale)")
                controller.resizeContainer(newSize: actualSize, scale: scale)
            }
        }

        guard nsView.subviews.count >= 2 else {
            print("[TerminalManagerView] ⚠️ Not enough subviews!")
            return
        }

        if let terminalView = nsView.subviews[0] as? TerminalManagerNSView {
            terminalView.controller = controller
            print("[TerminalManagerView] ✅ Updated terminalView controller")
        }

        // 更新 overlay (第二个 subview)
        if let overlay = nsView.subviews[1] as? DividerOverlayView {
            overlay.controller = controller
            overlay.needsDisplay = true
            print("[TerminalManagerView] ✅ Updated overlay controller, dividers: \(controller.panelDividers.count)")
        } else {
            print("[TerminalManagerView] ❌ Failed to get overlay from subviews[1]")
        }
    }
}

/// 使用原生 SwiftUI TabView 的终端视图
struct TabTerminalView: View {
    @Bindable var controller: WindowController
    @ObservedObject var coordinator = TerminalCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Button(action: createNewTab) {
                    Label("新建 Tab", systemImage: "plus")
                }
                .keyboardShortcut("t", modifiers: .command)
                .help("⌘T")

                Divider()
                    .frame(height: 20)

                Button(action: splitRight) {
                    Label("垂直分割（左右）", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut("d", modifiers: .command)
                .help("⌘D - 垂直分割（左右）")

                Button(action: splitDown) {
                    Label("水平分割（上下）", systemImage: "rectangle.split.1x2")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("⌘⇧D - 水平分割（上下）")

                Divider()
                    .frame(height: 20)

                // 🧪 测试按钮
                Button(action: testCornerPanes) {
                    Label("测试四角", systemImage: "square.grid.2x2")
                }
                .help("测试 Rust 坐标系")

                Spacer()

                Text("\(controller.panelCount) panel\(controller.panelCount > 1 ? "s" : "")")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(8)
            .background(Color.clear)

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
                    TerminalManagerView(controller: controller)
                        .padding(10)  // 添加 10pt 的内边距
                        .contentShape(Rectangle())  // 确保整个区域可以接收点击
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    handlePaneClick(at: value.location, in: geometry)
                                }
                        )
                        .onChange(of: controller.containerSize) { oldSize, newSize in
                            updateRustConfigs()
                        }
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
        .onAppear {
            // 🎯 设置 coordinator 的 controller 引用
            coordinator.controller = controller
        }
    }

    private func createNewTab() {
        coordinator.terminalView?.createNewTab()
    }

    // 🧪 测试四角坐标
    private func testCornerPanes() {
        guard let terminalView = coordinator.terminalView,
              let tabManager = terminalView.tabManager else {
            print("[Test] ⚠️ No terminal view or tab manager")
            return
        }

        // 获取容器尺寸（物理像素）
        let bounds = terminalView.bounds
        let scale = terminalView.window?.backingScaleFactor ?? 2.0
        let containerWidth = Float(bounds.width) * Float(scale)
        let containerHeight = Float(bounds.height) * Float(scale)

        print("[Test] 🧪 Testing corner panes: container \(containerWidth)x\(containerHeight) pixels")

        // 调用 Rust 测试函数
        tab_manager_test_corner_panes(tabManager.handle, containerWidth, containerHeight)

        // 触发渲染
        terminalView.renderTerminal()

        print("[Test] 🧪 Test initiated. Look for [[TL]], [[TR]], [[BL]], [[BR]] in corners")
    }

    /// 处理 Pane 点击事件
    private func handlePaneClick(at location: CGPoint, in geometry: GeometryProxy) {
        print("[Focus] 🖱️ Click at: \(location)")

        // 获取所有 Panel 的边界
        let panelBounds = controller.panelBounds
        print("[Focus] Panel bounds: \(panelBounds.mapValues { "(\($0.x), \($0.y), \($0.width)x\($0.height))" })")

        // 查找包含点击位置的 Panel
        for (panelId, bounds) in panelBounds {
            if bounds.contains(location) {
                print("[Focus] ✅ Found panel: \(panelId)")

                // 获取 Rust Panel ID
                let rustPanelId = controller.registerPanel(panelId)

                // 调用 Rust FFI 设置激活 Pane
                guard let terminalView = coordinator.terminalView,
                      let tabManager = terminalView.tabManager else {
                    print("[Focus] ❌ No terminalView or tabManager")
                    return
                }

                print("[Focus] 🎯 Setting active pane to: \(rustPanelId)")
                tab_manager_set_active_pane(tabManager.handle, size_t(rustPanelId))
                return
            }
        }

        print("[Focus] ❌ No panel found at click location")
    }

    private func splitRight() {
        print("[Split] 🔪 splitRight called, current panels: \(controller.panelCount)")
        // 使用新的 DDD 架构
        if let firstPanelId = controller.allPanelIds.first {
            if let newPanelId = controller.splitPanel(
                panelId: firstPanelId,
                direction: .horizontal
            ) {
                print("[Split] ✅ Created new panel: \(newPanelId), total: \(controller.panelCount)")
                print("[Split] 📏 Dividers: \(controller.panelDividers.count)")
                updateRustConfigs()

                // 触发 overlay 重绘
                coordinator.terminalView?.dividerOverlay?.needsDisplay = true
            } else {
                print("[Split] ❌ Failed to split")
            }
        }
    }

    private func splitDown() {
        print("[Split] 🔪 splitDown called, current panels: \(controller.panelCount)")
        // 使用新的 DDD 架构
        if let firstPanelId = controller.allPanelIds.first {
            if let newPanelId = controller.splitPanel(
                panelId: firstPanelId,
                direction: .vertical
            ) {
                print("[Split] ✅ Created new panel: \(newPanelId), total: \(controller.panelCount)")
                print("[Split] 📏 Dividers: \(controller.panelDividers.count)")
                updateRustConfigs()

                // 触发 overlay 重绘
                coordinator.terminalView?.dividerOverlay?.needsDisplay = true
            } else {
                print("[Split] ❌ Failed to split")
            }
        }
    }

    // 更新 Rust 配置
    private func updateRustConfigs() {
        guard let terminalView = coordinator.terminalView,
              let tabManager = terminalView.tabManager else {
            return
        }

        let configs = controller.panelRenderConfigs

        // 🎯 关键修复：按 Y 坐标排序，确保遍历顺序稳定
        // Y 坐标小的在前（Rust 坐标系，Y 向下，所以 Y 小的在上面）
        let sortedConfigs = configs.sorted { $0.value.y < $1.value.y }

        for (panelId, config) in sortedConfigs {
            let rustPanelId = controller.registerPanel(panelId)

            print("[Swift→Rust] Panel \(rustPanelId): pos=(\(config.x), \(config.y)), size=\(config.width)x\(config.height), grid=\(config.cols)x\(config.rows)")

            tab_manager_update_panel_config(
                tabManager.handle,
                size_t(rustPanelId),
                config.x,
                config.y,
                config.width,
                config.height,
                config.cols,
                config.rows
            )
        }

        // 触发重新渲染
        terminalView.renderTerminal()

        // 触发分隔线 overlay 重绘
        terminalView.dividerOverlay?.needsDisplay = true
    }
}

// MARK: - Preview
struct TabTerminalView_Previews: PreviewProvider {
    static var previews: some View {
        let controller = WindowController(
            containerSize: CGSize(width: 800, height: 600),
            scale: 2.0
        )
        return TabTerminalView(controller: controller)
            .frame(width: 800, height: 600)
    }
}
