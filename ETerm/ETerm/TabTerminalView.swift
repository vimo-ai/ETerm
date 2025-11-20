//
//  TabTerminalView.swift
//  ETerm
//
//  终端视图 - 使用 PanelLayoutKit 新架构
//
//  架构说明：
//  - Swift 管理布局（PanelLayoutKit）和终端生命周期
//  - Rust 只负责渲染（TerminalPoolWrapper）
//  - Tab ↔ Terminal 一对一映射
//

import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import PanelLayoutKit

// MARK: - Panel 渲染视图

/// Panel 渲染视图
///
/// 包含 Metal 渲染层，支持真实的终端渲染
class PanelRenderView: NSView {
    private var sugarloaf: SugarloafWrapper?
    private var displayLink: CVDisplayLink?
    private var needsRender = false
    private let renderLock = NSLock()
    private var ptyReadQueue: DispatchQueue?
    private var shouldStopReading = false
    private var isInitialized = false

    weak var coordinator: TerminalCoordinator?

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
        layer?.isOpaque = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window = window {
            // 只监听当前窗口的事件
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )

            // 如果窗口已经是焦点，立即初始化
            if window.isKeyWindow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.initialize()
                }
            }
        } else {
            // 窗口被移除时，清理观察者
            NotificationCenter.default.removeObserver(self)
        }
    }

    @objc private func windowDidBecomeKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initialize()
        }
    }

    private func initialize() {
        // 防止重复初始化
        guard !isInitialized else {
            print("[PanelRenderView] ⚠️ Already initialized, skipping")
            return
        }
        guard sugarloaf == nil, let window = window else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        isInitialized = true

        let windowScale = window.backingScaleFactor
        let effectiveScale = max(windowScale, layer?.contentsScale ?? windowScale)
        layer?.contentsScale = effectiveScale

        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)
        let displayHandle = windowHandle
        let scale = Float(effectiveScale)

        let widthPixels = Float(bounds.width) * scale
        let heightPixels = Float(bounds.height) * scale

        guard let sugarloaf = SugarloafWrapper(
            windowHandle: windowHandle,
            displayHandle: displayHandle,
            width: widthPixels,
            height: heightPixels,
            scale: scale,
            fontSize: 14.0
        ) else {
            print("[PanelRenderView] ❌ Failed to create SugarloafWrapper")
            return
        }

        self.sugarloaf = sugarloaf
        print("[PanelRenderView] ✅ Sugarloaf initialized")

        // 创建真实的 TerminalPoolWrapper
        guard let realTerminalPool = TerminalPoolWrapper(sugarloaf: sugarloaf) else {
            print("[PanelRenderView] ❌ Failed to create TerminalPoolWrapper")
            return
        }

        coordinator?.setTerminalPool(realTerminalPool)

        // 更新坐标映射器（传入 scale 和 containerBounds）
        coordinator?.updateCoordinateMapper(scale: CGFloat(scale), containerBounds: bounds)

        // 更新字体度量（从 Sugarloaf 获取实际字符尺寸）
        if let metrics = sugarloaf.fontMetrics {
            coordinator?.updateFontMetrics(metrics)
        }

        // 设置渲染回调
        realTerminalPool.setRenderCallback { [weak self] in
            self?.requestRender()
        }

        // 启动 PTY 读取循环
        startPTYReadLoop(terminalPool: realTerminalPool)

        // 启动 CVDisplayLink
        setupDisplayLink()

        print("[PanelRenderView] ✅ Initialization complete")

        // 🎯 重要：初始化完成后，触发一次 PanelView 创建
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let coordinator = self.coordinator else { return }
            let currentSize = self.bounds.size
            print("[PanelRenderView] 🔄 Triggering initial panel view update, bounds: \(currentSize)")

            // 更新 containerSize
            if currentSize.width > 0 && currentSize.height > 0 {
                coordinator.containerSize = currentSize
                coordinator.updatePanelViews(in: self)
            } else {
                print("[PanelRenderView] ⚠️ Bounds size is zero, skipping panel view update")
            }
        }
    }

    private func startPTYReadLoop(terminalPool: TerminalPoolWrapper) {
        let queue = DispatchQueue(label: "com.eterm.pty-reader", qos: .userInteractive)
        self.ptyReadQueue = queue

        queue.async { [weak self, weak terminalPool] in
            guard let self = self else { return }
            print("[PTY Reader] ✅ Background read loop started")

            while !self.shouldStopReading {
                terminalPool?.readAllOutputs()
                usleep(1000)  // 1ms
            }

            print("[PTY Reader] ✅ Background read loop stopped")
        }
    }

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard status == kCVReturnSuccess, let displayLink = link else {
            print("[CVDisplayLink] ❌ Failed to create: \(status)")
            return
        }

        let callbackContext = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, context) -> CVReturn in
            guard let context = context else { return kCVReturnSuccess }

            let view = Unmanaged<PanelRenderView>.fromOpaque(context).takeUnretainedValue()

            view.renderLock.lock()
            let shouldRender = view.needsRender
            if shouldRender {
                view.needsRender = false
            }
            view.renderLock.unlock()

            if shouldRender {
                DispatchQueue.main.async {
                    view.performRender()
                }
            }

            return kCVReturnSuccess
        }, callbackContext)

        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
        print("[CVDisplayLink] ✅ Started")
    }

    fileprivate func requestRender() {
        renderLock.lock()
        needsRender = true
        renderLock.unlock()
    }

    private func performRender() {
        coordinator?.renderAllPanels()

        // 🎯 关键：调用 Sugarloaf 的最终渲染，将内容绘制到 Metal layer
        sugarloaf?.render()
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    // MARK: - 键盘输入处理

    override func keyDown(with event: NSEvent) {
        guard let coordinator = coordinator,
              let characters = event.characters else {
            super.keyDown(with: event)
            return
        }

        // 获取当前活动的终端
        guard let activeTerminalId = coordinator.getActiveTerminalId() else {
            super.keyDown(with: event)
            return
        }

        // 处理特殊键
        var inputText: String?

        if event.modifierFlags.contains(.control) && characters == "c" {
            // Ctrl+C
            inputText = "\u{03}"
        } else if event.keyCode == 36 {  // Return key
            inputText = "\r"
        } else if event.keyCode == 51 {  // Delete key (Backspace)
            inputText = "\u{7F}"
        } else if event.keyCode == 48 {  // Tab key
            inputText = "\t"
        } else if event.keyCode == 53 {  // Escape key
            inputText = "\u{1B}"
        } else if event.keyCode == 123 {  // Left arrow
            inputText = "\u{1B}[D"
        } else if event.keyCode == 124 {  // Right arrow
            inputText = "\u{1B}[C"
        } else if event.keyCode == 125 {  // Down arrow
            inputText = "\u{1B}[B"
        } else if event.keyCode == 126 {  // Up arrow
            inputText = "\u{1B}[A"
        } else {
            // 普通字符
            inputText = characters
        }

        if let inputText = inputText {
            coordinator.writeInput(terminalId: activeTerminalId, data: inputText)
        }
    }

    deinit {
        print("[PanelRenderView] 🔄 开始清理资源...")

        // 1. 移除通知观察者（最重要！防止访问已释放对象）
        NotificationCenter.default.removeObserver(self)

        // 2. 停止 PTY 读取循环
        shouldStopReading = true

        // 3. 停止 CVDisplayLink
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }

        print("[PanelRenderView] ✅ 资源清理完成")
    }
}

// MARK: - 终端协调器

/// 终端协调器
///
/// 管理布局树、终端池、以及两者之间的映射关系
class TerminalCoordinator: ObservableObject {
    // MARK: - 数据模型

    /// 布局树（主数据源）
    @Published var layoutTree: LayoutTree

    /// 终端池
    private var terminalPool: TerminalPoolProtocol

    /// Tab ID 到终端 ID 的映射
    private var tabTerminalMapping: [UUID: Int] = [:]

    /// PanelLayoutKit 实例
    private let layoutKit = PanelLayoutKit()

    /// Panel 视图映射
    private var panelViews: [UUID: PanelView] = [:]

    /// 容器尺寸
    var containerSize: CGSize = .zero

    /// 坐标映射器（处理 Swift ↔ Rust 坐标转换和 Scale）
    private var coordinateMapper: CoordinateMapper?

    /// 字体度量（从 Sugarloaf 获取实际字符尺寸）
    private var fontMetrics: SugarloafFontMetrics?

    /// 渲染视图引用（用于触发重新渲染）
    weak var renderView: PanelRenderView?

    // MARK: - 初始化

    init(initialLayoutTree: LayoutTree, terminalPool: TerminalPoolProtocol? = nil) {
        self.layoutTree = initialLayoutTree
        self.terminalPool = terminalPool ?? MockTerminalPool()

        // 为初始的 Tab 创建终端
        ensureTerminalsForAllTabs(initialLayoutTree)
    }

    deinit {
        print("[TerminalCoordinator] 🔄 析构，检查终端泄露...")
        // 如果是 MockTerminalPool，打印统计信息
        if let mockPool = terminalPool as? MockTerminalPool {
            mockPool.printStatistics()
        }
    }

    // MARK: - 终端池管理

    /// 设置终端池（由 PanelRenderView 调用）
    func setTerminalPool(_ pool: TerminalPoolProtocol) {
        print("[TerminalCoordinator] 🔄 切换到真实终端池")

        // 1. 清空旧的映射（旧终端池的 ID 已无效）
        tabTerminalMapping.removeAll()

        // 2. 设置新的终端池
        self.terminalPool = pool

        // 3. 为所有 Tab 重新创建终端
        ensureTerminalsForAllTabs(layoutTree)
    }

    /// 更新坐标映射器（由 PanelRenderView 调用）
    func updateCoordinateMapper(scale: CGFloat, containerBounds: CGRect) {
        self.coordinateMapper = CoordinateMapper(scale: scale, containerBounds: containerBounds)
        print("[TerminalCoordinator] 🗺️ Updated CoordinateMapper: scale=\(scale), bounds=\(containerBounds)")
    }

    /// 更新字体度量（由 PanelRenderView 调用）
    func updateFontMetrics(_ metrics: SugarloafFontMetrics) {
        self.fontMetrics = metrics
        print("[TerminalCoordinator] 🔤 Updated FontMetrics: cellWidth=\(metrics.cell_width), cellHeight=\(metrics.cell_height)")
    }

    /// 确保所有 Tab 都有对应的终端
    private func ensureTerminalsForAllTabs(_ layoutTree: LayoutTree) {
        let allTabs = layoutTree.allTabs()

        // 1. 为新 Tab 创建终端
        for tab in allTabs {
            if tabTerminalMapping[tab.id] == nil {
                let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                tabTerminalMapping[tab.id] = terminalId
                print("[TerminalCoordinator] ➕ Created terminal \(terminalId) for tab \(tab.id.uuidString.prefix(8))")
            }
        }

        // 2. 清理孤立的终端（Tab 已删除但终端还在）
        let allTabIds = Set(allTabs.map { $0.id })
        let orphanedTabIds = tabTerminalMapping.keys.filter { !allTabIds.contains($0) }

        for tabId in orphanedTabIds {
            if let terminalId = tabTerminalMapping[tabId] {
                terminalPool.closeTerminal(terminalId)
                tabTerminalMapping.removeValue(forKey: tabId)
                print("[TerminalCoordinator] ❌ Closed orphaned terminal \(terminalId)")
            }
        }
    }

    // MARK: - 布局管理

    /// 更新布局树
    func updateLayoutTree(_ newLayoutTree: LayoutTree, in containerView: NSView) {
        self.layoutTree = newLayoutTree
        ensureTerminalsForAllTabs(newLayoutTree)
        updatePanelViews(in: containerView)
    }

    // MARK: - 输入处理

    /// 获取当前活动的终端 ID
    func getActiveTerminalId() -> Int? {
        // 遍历所有 Panel，找到第一个活动的 Tab
        for panel in layoutTree.allPanels() {
            if let activeTab = panel.activeTab,
               let terminalId = tabTerminalMapping[activeTab.id] {
                return terminalId
            }
        }
        return nil
    }

    /// 写入输入到指定终端
    func writeInput(terminalId: Int, data: String) {
        _ = terminalPool.writeInput(terminalId: terminalId, data: data)
    }

    /// 更新 Panel 视图
    func updatePanelViews(in containerView: NSView) {
        print("[TerminalCoordinator] 🔄 Updating panel views, containerSize: \(containerSize)")

        // 清除旧的视图
        for subview in containerView.subviews {
            if subview is PanelView {
                subview.removeFromSuperview()
            }
        }
        panelViews.removeAll()

        // 计算布局
        let panelBounds = layoutKit.calculateBounds(
            layout: layoutTree,
            containerSize: containerSize
        )
        print("[TerminalCoordinator] 📐 Calculated \(panelBounds.count) panel bounds")

        // 创建新的 Panel 视图
        for (panelId, bounds) in panelBounds {
            print("[TerminalCoordinator] 🎨 Creating PanelView for \(panelId.uuidString.prefix(8)), bounds: \(bounds)")
            guard let panel = layoutTree.findPanel(byId: panelId) else { continue }

            let panelView = PanelView(
                panel: panel,
                frame: bounds,
                layoutKit: layoutKit
            )

            // 设置回调
            panelView.onTabClick = { [weak self] tabId in
                self?.handleTabClick(panelId: panelId, tabId: tabId)
            }

            panelView.onTabClose = { [weak self] tabId in
                self?.handleTabClose(tabId: tabId, in: containerView)
            }

            panelView.onAddTab = { [weak self] in
                self?.handleAddTab(panelId: panelId, in: containerView)
            }

            containerView.addSubview(panelView)
            panelViews[panelId] = panelView
        }

        // 🎯 重要：Panel 创建后，主动触发一次渲染
        DispatchQueue.main.async { [weak self] in
            self?.renderAllPanels()
        }
    }

    // MARK: - 事件处理

    private func handleTabClick(panelId: UUID, tabId: UUID) {
        print("[TerminalCoordinator] 👆 handleTabClick called: panelId=\(panelId.uuidString.prefix(8)), tabId=\(tabId.uuidString.prefix(8))")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 🎯 防止重复点击：如果点击的 Tab 已经是 active，直接返回
            if let currentPanel = self.layoutTree.findPanel(byId: panelId),
               let currentActiveTab = currentPanel.activeTab,
               currentActiveTab.id == tabId {
                print("[TerminalCoordinator] ⏭️ Tab already active, ignoring click")
                return
            }

            print("[TerminalCoordinator] 🔄 Switching tab...")
            let newLayoutTree = self.layoutTree.updatingPanel(panelId) { panel in
                panel.activatingTab(tabId)
            }
            self.layoutTree = newLayoutTree

            // 🎯 关键：更新 PanelView 的数据（否则 UI 不会变化）
            if let panelView = self.panelViews[panelId],
               let updatedPanel = newLayoutTree.findPanel(byId: panelId) {
                print("[TerminalCoordinator] ✅ Updated to tab: \(tabId.uuidString.prefix(8))")
                panelView.updatePanel(updatedPanel)
            }

            // 触发重新渲染，显示切换后的 Tab 内容
            self.renderView?.requestRender()
        }
    }

    private func handleTabClose(tabId: UUID, in containerView: NSView) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. 销毁对应的终端
            if let terminalId = self.tabTerminalMapping[tabId] {
                self.terminalPool.closeTerminal(terminalId)
                self.tabTerminalMapping.removeValue(forKey: tabId)
            }

            // 2. 从布局树中移除 Tab
            if let newLayoutTree = self.layoutTree.removingTab(tabId) {
                self.layoutTree = newLayoutTree
                self.updatePanelViews(in: containerView)
            } else {
                // 最后一个 Tab 被关闭，创建新的默认 Tab
                let terminalId = self.terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                let defaultTab = TabNode(id: UUID(), title: "终端 1", rustTerminalId: terminalId)
                self.tabTerminalMapping[defaultTab.id] = terminalId

                let defaultPanel = PanelNode(tabs: [defaultTab], activeTabIndex: 0)
                self.layoutTree = .panel(defaultPanel)
                self.updatePanelViews(in: containerView)
            }
        }
    }

    private func handleAddTab(panelId: UUID, in containerView: NSView) {
        print("[TerminalCoordinator] ➕ Adding new tab to panel \(panelId.uuidString.prefix(8))")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. 创建终端
            let terminalId = self.terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
            print("[TerminalCoordinator] ➕ Created terminal \(terminalId) for new tab")

            // 2. 创建 Tab
            let panel = self.layoutTree.findPanel(byId: panelId)
            let tabNumber = (panel?.tabs.count ?? 0) + 1
            let newTab = TabNode(id: UUID(), title: "终端 \(tabNumber)", rustTerminalId: terminalId)
            self.tabTerminalMapping[newTab.id] = terminalId
            print("[TerminalCoordinator] 📝 Mapped tab \(newTab.id.uuidString.prefix(8)) → terminal \(terminalId)")

            // 3. 更新布局树
            let newLayoutTree = self.layoutTree.updatingPanel(panelId) { panel in
                panel.addingTab(newTab)
            }
            self.layoutTree = newLayoutTree
            self.updatePanelViews(in: containerView)
        }
    }

    // MARK: - 渲染

    /// 渲染所有 Panel
    func renderAllPanels() {
        guard let terminalPool = terminalPool as? TerminalPoolWrapper else {
            // 如果是 MockTerminalPool，不需要渲染
            print("[TerminalCoordinator] ⚠️ Still using MockTerminalPool, skipping render")
            return
        }

        let allPanels = layoutTree.allPanels()
        print("[TerminalCoordinator] 🎨 Rendering \(allPanels.count) panels")

        // 遍历所有 Panel，渲染激活的 Tab
        for panel in allPanels {
            guard let activeTab = panel.activeTab else {
                print("[TerminalCoordinator] ⚠️ Panel \(panel.id.uuidString.prefix(8)) has no active tab")
                continue
            }

            guard let panelView = panelViews[panel.id] else {
                print("[TerminalCoordinator] ⚠️ No view found for panel \(panel.id.uuidString.prefix(8))")
                continue
            }

            // 🎯 从 tabTerminalMapping 中查找当前的终端 ID
            guard let terminalId = tabTerminalMapping[activeTab.id] else {
                print("[TerminalCoordinator] ⚠️ No terminal mapping for tab \(activeTab.id.uuidString.prefix(8))")
                continue
            }

            // 🎯 关键：需要 contentView 在 PanelRenderView 内的全局坐标
            // 而不是在 PanelView 内的相对坐标
            guard let containerView = panelView.superview else {
                print("[TerminalCoordinator] ⚠️ PanelView has no superview")
                continue
            }

            // 🎯 步骤1: 计算 contentView 的实际边界
            // 注意：不能直接使用 contentView.bounds，因为 layout() 可能还没执行
            let headerHeight = PanelHeaderView.recommendedHeight()
            let contentHeight = panelView.bounds.height - headerHeight
            let contentWidth = panelView.bounds.width

            // 手动构建 contentView 在 PanelView 内的 bounds
            let contentBoundsInPanel = CGRect(
                x: 0,
                y: 0,
                width: contentWidth,
                height: contentHeight
            )

            // 转换为 containerView（PanelRenderView）的坐标系
            let contentBoundsInContainer = panelView.convert(
                contentBoundsInPanel,
                to: containerView
            )

            // 🎯 步骤2: 使用 CoordinateMapper 转换坐标
            guard let mapper = coordinateMapper else {
                print("[TerminalCoordinator] ⚠️ CoordinateMapper not initialized")
                continue
            }

            // 🎯 步骤3: 获取字体度量
            guard let metrics = fontMetrics else {
                print("[TerminalCoordinator] ⚠️ FontMetrics not initialized")
                continue
            }

            // 🎯 步骤4: Swift 坐标 → Rust 坐标（Y 轴翻转，保持逻辑坐标）
            // 注意：传给 Rust 的是逻辑坐标，Sugarloaf 内部会 × scale_factor
            let rustRect = mapper.swiftToRust(rect: contentBoundsInContainer)

            // 🎯 步骤5: 计算终端网格尺寸（必须用物理坐标尺寸）
            // 原因：终端的列数基于物理像素，cellWidth/Height 是物理单位
            let scale = mapper.scale
            let physicalWidth = rustRect.width * scale
            let physicalHeight = rustRect.height * scale

            let cellWidth = Float(metrics.cell_width)
            let cellHeight = Float(metrics.cell_height)
            let cols = UInt16(Float(physicalWidth) / cellWidth)
            let rows = UInt16(Float(physicalHeight) / cellHeight)

            print("[TerminalCoordinator] 🖥️ Rendering terminal \(terminalId)")
            print("  Tab: \(activeTab.id.uuidString.prefix(8))")
            print("  Panel: \(panel.id.uuidString.prefix(8))")
            print("  Swift Rect: \(contentBoundsInContainer)")
            print("  Rust Rect (logical): \(rustRect)")
            print("  Cell Size: \(cellWidth) × \(cellHeight)")
            print("  Grid: \(cols)×\(rows)")

            let success = terminalPool.render(
                terminalId: terminalId,
                x: Float(rustRect.origin.x),
                y: Float(rustRect.origin.y),
                width: Float(rustRect.width),
                height: Float(rustRect.height),
                cols: cols,
                rows: rows
            )

            if !success {
                print("[TerminalCoordinator] ❌ Render failed for terminal \(terminalId)")
            }
        }
    }
}

// MARK: - NSViewRepresentable

struct PanelContainerView: NSViewRepresentable {
    @ObservedObject var coordinator: TerminalCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalCoordinator: coordinator)
    }

    func makeNSView(context: Context) -> NSView {
        let renderView = PanelRenderView()
        renderView.coordinator = coordinator
        context.coordinator.renderView = renderView
        // 设置 TerminalCoordinator 的 renderView 引用，用于触发渲染
        context.coordinator.terminalCoordinator.renderView = renderView
        return renderView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let renderView = nsView as? PanelRenderView else { return }

        // 更新容器尺寸
        let newSize = renderView.bounds.size
        if newSize.width > 0 && newSize.height > 0 {
            if coordinator.containerSize != newSize {
                print("[PanelContainerView] 📏 Container size changed: \(coordinator.containerSize) -> \(newSize)")
                coordinator.containerSize = newSize
                coordinator.updatePanelViews(in: renderView)
            }
        }
    }

    class Coordinator {
        let terminalCoordinator: TerminalCoordinator
        weak var renderView: PanelRenderView?

        init(terminalCoordinator: TerminalCoordinator) {
            self.terminalCoordinator = terminalCoordinator
        }
    }
}

// MARK: - 主视图

/// 终端视图（使用 PanelLayoutKit 新架构）
struct TabTerminalView: View {
    @StateObject private var coordinator: TerminalCoordinator

    init() {
        // 创建初始布局
        let initialTab = TabNode(id: UUID(), title: "终端 1", rustTerminalId: -1)
        let initialPanel = PanelNode(tabs: [initialTab], activeTabIndex: 0)
        let initialLayout = LayoutTree.panel(initialPanel)

        _coordinator = StateObject(wrappedValue: TerminalCoordinator(
            initialLayoutTree: initialLayout
        ))
    }

    var body: some View {
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

            // Panel 渲染视图（在背景之上）
            PanelContainerView(coordinator: coordinator)
        }
    }
}

// MARK: - Preview

#Preview {
    TabTerminalView()
        .frame(width: 1000, height: 800)
}
