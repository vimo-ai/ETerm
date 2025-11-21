//
//  DDDTerminalView.swift
//  ETerm
//
//  基于 DDD 架构的终端视图
//
//  架构原则：
//  - Domain AR 是唯一的状态来源
//  - 数据流单向：AR → UI
//  - 用户操作通过 Coordinator 调用 AR 方法
//

import SwiftUI
import AppKit

// MARK: - SwiftUI 视图

struct DDDTerminalView: View {
    @StateObject private var coordinator: TerminalWindowCoordinator

    init() {
        // 创建初始的 Domain AR
        let initialTab = TerminalTab(tabId: UUID(), title: "终端 1")
        let initialPanel = EditorPanel(initialTab: initialTab)
        let terminalWindow = TerminalWindow(initialPanel: initialPanel)

        _coordinator = StateObject(wrappedValue: TerminalWindowCoordinator(
            initialWindow: terminalWindow
        ))
    }

    var body: some View {
        ZStack {
            // 背景层
            GeometryReader { geometry in
                Image("night")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(0.3)
            }
            .ignoresSafeArea()

            // 渲染层
            DDDRenderView(coordinator: coordinator)
        }
    }
}

// MARK: - NSViewRepresentable

struct DDDRenderView: NSViewRepresentable {
    @ObservedObject var coordinator: TerminalWindowCoordinator

    func makeNSView(context: Context) -> DDDContainerView {
        let containerView = DDDContainerView()
        containerView.coordinator = coordinator
        coordinator.renderView = containerView.renderView
        return containerView
    }

    func updateNSView(_ nsView: DDDContainerView, context: Context) {
        // 读取 updateTrigger 触发更新
        let _ = coordinator.updateTrigger

        // 触发 Panel 视图更新
        nsView.updatePanelViews()

        // 容器尺寸变化时触发重新渲染
        let newSize = nsView.bounds.size
        if newSize.width > 0 && newSize.height > 0 {
            nsView.renderView.requestRender()
        }
    }
}

// MARK: - Container View（分离 Metal 层和 UI 层）

class DDDContainerView: NSView {
    /// Page 栏视图（在顶部）
    private let pageBarView: PageBarView

    /// Metal 渲染层（在底部）
    let renderView: DDDPanelRenderView

    /// Panel UI 视图列表（在上面）
    private var panelUIViews: [UUID: DomainPanelView] = [:]

    /// 分割线视图列表
    private var dividerViews: [DividerView] = []

    /// 分割线可拖拽区域宽度
    private let dividerHitAreaWidth: CGFloat = 6.0

    /// Page 栏高度
    private let pageBarHeight: CGFloat = PageBarView.recommendedHeight()

    weak var coordinator: TerminalWindowCoordinator? {
        didSet {
            renderView.coordinator = coordinator
            setupPageBarCallbacks()
            updatePageBar()
        }
    }

    override init(frame frameRect: NSRect) {
        pageBarView = PageBarView()
        renderView = DDDPanelRenderView()
        super.init(frame: frameRect)

        // 添加 Page 栏（顶部）
        addSubview(pageBarView)

        // 添加 Metal 层（底部）
        addSubview(renderView)

        // 监听 AR 变化，更新 UI
        setupObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupObservers() {
        // 监听 Coordinator 的状态变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePanelViews),
            name: NSNotification.Name("TerminalWindowDidChange"),
            object: nil
        )
    }

    /// 设置 Page 栏的回调
    private func setupPageBarCallbacks() {
        guard let coordinator = coordinator else { return }

        pageBarView.onPageClick = { [weak coordinator] pageId in
            _ = coordinator?.switchToPage(pageId)
        }

        pageBarView.onPageClose = { [weak coordinator] pageId in
            _ = coordinator?.closePage(pageId)
        }

        pageBarView.onPageRename = { [weak coordinator] pageId, newTitle in
            _ = coordinator?.renamePage(pageId, to: newTitle)
        }

        pageBarView.onAddPage = { [weak coordinator] in
            _ = coordinator?.createPage()
        }
    }

    /// 更新 Page 栏
    func updatePageBar() {
        guard let coordinator = coordinator else { return }

        // 设置 Page 列表
        let pages = coordinator.allPages.map { (id: $0.pageId, title: $0.title) }
        pageBarView.setPages(pages)

        // 设置激活的 Page
        if let activePageId = coordinator.activePage?.pageId {
            pageBarView.setActivePage(activePageId)
        }
    }

    override func layout() {
        super.layout()

        // Page 栏在顶部
        pageBarView.frame = CGRect(
            x: 0,
            y: bounds.height - pageBarHeight,
            width: bounds.width,
            height: pageBarHeight
        )

        // Metal 层在 Page 栏下方，填满剩余空间
        let contentBounds = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - pageBarHeight
        )
        renderView.frame = contentBounds

        // 更新 Panel UI 视图
        updatePanelViews()
    }

    /// 获取内容区域的 bounds（不包含 Page 栏）
    var contentBounds: CGRect {
        return CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - pageBarHeight
        )
    }

    @objc func updatePanelViews() {
        guard let coordinator = coordinator else {
            return
        }

        // 更新 Page 栏
        updatePageBar()

        // 🎯 关键：使用内容区域的 bounds（不包含 Page 栏）
        let _ = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: contentBounds,
            headerHeight: 30.0
        )

        let panels = coordinator.terminalWindow.allPanels
        let panelIds = Set(panels.map { $0.panelId })

        // 删除不存在的 Panel UI
        let viewsToRemove = panelUIViews.filter { !panelIds.contains($0.key) }
        for (id, view) in viewsToRemove {
            view.removeFromSuperview()
            panelUIViews.removeValue(forKey: id)
        }

        // 更新或创建 Panel UI
        for panel in panels {
            if let existingView = panelUIViews[panel.panelId] {
                // 更新现有视图
                existingView.updateUI()
                existingView.frame = panel.bounds
            } else {
                // 创建新视图
                let view = DomainPanelView(panel: panel, coordinator: coordinator)
                view.frame = panel.bounds
                addSubview(view)
                panelUIViews[panel.panelId] = view
            }
        }

        // 更新分割线
        updateDividers()
    }

    /// 更新分割线视图
    private func updateDividers() {
        guard let coordinator = coordinator else { return }

        // 移除旧的分割线
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews.removeAll()

        // 从布局树计算分割线位置
        let dividers = calculateDividers(
            layout: coordinator.terminalWindow.rootLayout,
            bounds: contentBounds
        )

        // 创建分割线视图
        for (frame, direction) in dividers {
            let view = DividerView(frame: frame)
            view.direction = direction
            // 分割线在 renderView 之上，但在 panelUIViews 之下
            addSubview(view, positioned: .above, relativeTo: renderView)
            dividerViews.append(view)
        }
    }

    /// 递归计算分割线位置
    ///
    /// - Parameters:
    ///   - layout: 布局树
    ///   - bounds: 可用区域
    /// - Returns: 分割线信息数组 [(frame, direction)]
    private func calculateDividers(
        layout: PanelLayout,
        bounds: CGRect
    ) -> [(frame: CGRect, direction: SplitDirection)] {
        switch layout {
        case .leaf:
            return []

        case .split(let direction, let first, let second, let ratio):
            var result: [(CGRect, SplitDirection)] = []
            let dividerThickness: CGFloat = 1.0  // 与 Page 中的一致

            switch direction {
            case .horizontal:
                // 水平分割（左右）- 垂直分割线
                let firstWidth = bounds.width * ratio - dividerThickness / 2
                let dividerX = bounds.minX + firstWidth

                // 分割线 frame（可拖拽区域稍宽）
                let frame = CGRect(
                    x: dividerX - dividerHitAreaWidth / 2 + dividerThickness / 2,
                    y: bounds.minY,
                    width: dividerHitAreaWidth,
                    height: bounds.height
                )
                result.append((frame, direction))

                // 递归处理子布局
                let firstBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: firstWidth,
                    height: bounds.height
                )
                let secondBounds = CGRect(
                    x: bounds.minX + firstWidth + dividerThickness,
                    y: bounds.minY,
                    width: bounds.width * (1 - ratio) - dividerThickness / 2,
                    height: bounds.height
                )
                result += calculateDividers(layout: first, bounds: firstBounds)
                result += calculateDividers(layout: second, bounds: secondBounds)

            case .vertical:
                // 垂直分割（上下）- 水平分割线
                let firstHeight = bounds.height * ratio - dividerThickness / 2
                let secondHeight = bounds.height * (1 - ratio) - dividerThickness / 2
                let dividerY = bounds.minY + secondHeight

                // 分割线 frame
                let frame = CGRect(
                    x: bounds.minX,
                    y: dividerY - dividerHitAreaWidth / 2 + dividerThickness / 2,
                    width: bounds.width,
                    height: dividerHitAreaWidth
                )
                result.append((frame, direction))

                // 递归处理子布局
                let firstBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + secondHeight + dividerThickness,
                    width: bounds.width,
                    height: firstHeight
                )
                let secondBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: secondHeight
                )
                result += calculateDividers(layout: first, bounds: firstBounds)
                result += calculateDividers(layout: second, bounds: secondBounds)
            }

            return result
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Panel 渲染视图（DDD 版本）

class DDDPanelRenderView: NSView, RenderViewProtocol {
    private var sugarloaf: SugarloafWrapper?
    private var displayLink: CVDisplayLink?
    private var needsRender = false
    private let renderLock = NSLock()
    private var ptyReadQueue: DispatchQueue?
    private var shouldStopReading = false
    private var isInitialized = false

    weak var coordinator: TerminalWindowCoordinator?

    // MARK: - 文本选中状态

    /// 是否正在拖拽选中
    private var isDraggingSelection = false

    /// 当前选中的 Panel ID
    private var selectionPanelId: UUID?

    /// 当前选中的 Tab
    private weak var selectionTab: TerminalTab?

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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )

            if window.isKeyWindow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.initialize()
                }
            }
        } else {
            NotificationCenter.default.removeObserver(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // 尺寸变化时触发渲染
        if newSize.width > 0 && newSize.height > 0 {
            // 通过 Coordinator 的 mapper 获取物理尺寸，统一 scale 处理
            if let sugarloaf = sugarloaf,
               let mapper = coordinator?.coordinateMapper {
                let physicalSize = mapper.logicalToPhysical(size: newSize)
                sugarloaf.resize(width: Float(physicalSize.width), height: Float(physicalSize.height))
            }
            requestRender()
        }
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)

        // bounds 变化时触发渲染
        if newSize.width > 0 && newSize.height > 0 {
            // 通过 Coordinator 的 mapper 获取物理尺寸，统一 scale 处理
            if let sugarloaf = sugarloaf,
               let mapper = coordinator?.coordinateMapper {
                let physicalSize = mapper.logicalToPhysical(size: newSize)
                sugarloaf.resize(width: Float(physicalSize.width), height: Float(physicalSize.height))
            }
            requestRender()
        }
    }

    @objc private func windowDidBecomeKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initialize()
        }
    }

    private func initialize() {
        guard !isInitialized else { return }
        guard sugarloaf == nil, let window = window else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        isInitialized = true

        // 1. 设置 layer scale
        let windowScale = window.backingScaleFactor
        let effectiveScale = max(windowScale, layer?.contentsScale ?? windowScale)
        layer?.contentsScale = effectiveScale

        // 2. 先创建 CoordinateMapper（唯一处理 scale 的地方）
        let mapper = CoordinateMapper(scale: effectiveScale, containerBounds: bounds)

        // 3. 通过 mapper 获取物理尺寸
        let physicalSize = mapper.physicalContainerSize

        // 4. 创建 Sugarloaf（传入物理像素）
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)
        let displayHandle = windowHandle

        guard let sugarloaf = SugarloafWrapper(
            windowHandle: windowHandle,
            displayHandle: displayHandle,
            width: Float(physicalSize.width),
            height: Float(physicalSize.height),
            scale: Float(effectiveScale),
            fontSize: 14.0
        ) else {
            return
        }

        self.sugarloaf = sugarloaf

        // 5. 创建 TerminalPool
        guard let realTerminalPool = TerminalPoolWrapper(sugarloaf: sugarloaf) else {
            print("[DDDPanelRenderView] ❌ Failed to create TerminalPoolWrapper")
            return
        }

        // 6. 设置 Coordinator（传入已创建的 mapper）
        coordinator?.setTerminalPool(realTerminalPool)
        coordinator?.setCoordinateMapper(mapper)

        if let metrics = sugarloaf.fontMetrics {
            coordinator?.updateFontMetrics(metrics)
        }

        realTerminalPool.setRenderCallback { [weak self] in
            self?.requestRender()
        }

        startPTYReadLoop(terminalPool: realTerminalPool)
        setupDisplayLink()

        // 触发初始渲染
        DispatchQueue.main.async { [weak self] in
            self?.requestRender()
        }
    }

    private func startPTYReadLoop(terminalPool: TerminalPoolWrapper) {
        let queue = DispatchQueue(label: "com.eterm.pty-reader", qos: .userInteractive)
        self.ptyReadQueue = queue

        queue.async { [weak self, weak terminalPool] in
            guard let self = self else { return }

            while !self.shouldStopReading {
                terminalPool?.readAllOutputs()
                usleep(1000)
            }
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

            let view = Unmanaged<DDDPanelRenderView>.fromOpaque(context).takeUnretainedValue()

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
    }

    func requestRender() {
        renderLock.lock()
        needsRender = true
        renderLock.unlock()
    }

    private func performRender() {
        // 从 AR 获取数据并渲染
        // flush() 内部已经调用了 render()，不需要再调用
        coordinator?.renderAllPanels(containerBounds: bounds)
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator = coordinator,
              let characters = event.characters else {
            super.keyDown(with: event)
            return
        }

        guard let activeTerminalId = coordinator.getActiveTerminalId() else {
            super.keyDown(with: event)
            return
        }

        let char = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags

        // 粘贴快捷键（Cmd+V 或 Ctrl+V）
        if (modifiers.contains(.command) || modifiers.contains(.control)) && char == "v" {
            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .string) {
                coordinator.writeInput(terminalId: activeTerminalId, data: text)
            }
            return
        }

        // 复制快捷键（Cmd+C）- Ctrl+C 作为中断信号
        if modifiers.contains(.command) && char == "c" {
            // TODO: 实现复制逻辑（需要文本选择功能）
            return
        }

        var inputText: String?

        if event.modifierFlags.contains(.control) && characters == "c" {
            inputText = "\u{03}"
        } else if event.keyCode == 36 {
            inputText = "\r"
        } else if event.keyCode == 51 {
            inputText = "\u{7F}"
        } else if event.keyCode == 48 {
            inputText = "\t"
        } else if event.keyCode == 53 {
            inputText = "\u{1B}"
        } else if event.keyCode == 123 {
            inputText = "\u{1B}[D"
        } else if event.keyCode == 124 {
            inputText = "\u{1B}[C"
        } else if event.keyCode == 125 {
            inputText = "\u{1B}[B"
        } else if event.keyCode == 126 {
            inputText = "\u{1B}[A"
        } else {
            inputText = characters
        }

        if let inputText = inputText {
            coordinator.writeInput(terminalId: activeTerminalId, data: inputText)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 设置 first responder
        window?.makeFirstResponder(self)

        // 获取鼠标位置（相对于当前视图）
        let location = convert(event.locationInWindow, from: nil)

        guard let coordinator = coordinator else {
            super.mouseDown(with: event)
            return
        }

        // 根据位置找到对应的 Panel
        guard let panelId = coordinator.findPanel(at: location, containerBounds: bounds),
              let panel = coordinator.terminalWindow.getPanel(panelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId else {
            super.mouseDown(with: event)
            return
        }

        // 设置激活的 Panel
        coordinator.setActivePanel(panelId)

        // 转换为网格坐标
        let gridPos = screenToGrid(location: location, panelId: panelId)

        // 更新 Domain 层状态
        activeTab.startSelection(at: gridPos)

        // 通知 Rust 层渲染高亮
        if let selection = activeTab.textSelection {
            _ = coordinator.setSelection(terminalId: terminalId, selection: selection)
        }

        // 记录选中状态
        isDraggingSelection = true
        selectionPanelId = panelId
        selectionTab = activeTab
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection,
              let panelId = selectionPanelId,
              let activeTab = selectionTab,
              let terminalId = activeTab.rustTerminalId,
              let coordinator = coordinator else {
            super.mouseDragged(with: event)
            return
        }

        // 获取鼠标位置
        let location = convert(event.locationInWindow, from: nil)

        // 转换为网格坐标
        let gridPos = screenToGrid(location: location, panelId: panelId)

        // 更新 Domain 层状态
        activeTab.updateSelection(to: gridPos)

        // 通知 Rust 层渲染高亮
        if let selection = activeTab.textSelection {
            _ = coordinator.setSelection(terminalId: terminalId, selection: selection)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingSelection else {
            super.mouseUp(with: event)
            return
        }

        // 检查选中内容是否全为空白，如果是则清除选区
        if let activeTab = selectionTab,
           let terminalId = activeTab.rustTerminalId,
           let selection = activeTab.textSelection,
           let coordinator = coordinator {
            if let text = coordinator.getSelectedText(terminalId: terminalId, selection: selection) {
                // 检查是否全为空白字符
                let isAllWhitespace = text.allSatisfy { $0.isWhitespace }
                if isAllWhitespace {
                    // 清除选区
                    activeTab.clearSelection()
                    _ = coordinator.clearSelection(terminalId: terminalId)
                }
            }
        }

        // 重置选中状态
        isDraggingSelection = false
        // 注意：不清除 selectionPanelId 和 selectionTab，保持选中状态用于 Cmd+C 复制
    }

    // MARK: - 坐标转换

    /// 将屏幕坐标转换为网格坐标
    private func screenToGrid(location: CGPoint, panelId: UUID) -> CursorPosition {
        guard let coordinator = coordinator,
              let mapper = coordinator.coordinateMapper else {
            return CursorPosition(col: 0, row: 0)
        }

        // 获取 Panel 的 bounds
        let tabsToRender = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: bounds,
            headerHeight: 30.0  // 与 coordinator 中的 headerHeight 一致
        )

        // 获取 Panel 对应的 contentBounds
        guard let panel = coordinator.terminalWindow.getPanel(panelId),
              let contentBounds = tabsToRender.first(where: { $0.0 == panel.activeTab?.rustTerminalId })?.1 else {
            return CursorPosition(col: 0, row: 0)
        }

        // 从 fontMetrics 获取实际的 cell 尺寸
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        if let metrics = coordinator.fontMetrics {
            // fontMetrics 是物理像素，需要转换为逻辑点
            cellWidth = CGFloat(metrics.cell_width) / mapper.scale
            cellHeight = CGFloat(metrics.line_height) / mapper.scale
        } else {
            cellWidth = 9.6
            cellHeight = 20.0
        }

        // 使用 CoordinateMapper 转换
        let gridPos = mapper.screenToGrid(
            screenPoint: location,
            panelOrigin: contentBounds.origin,
            panelHeight: contentBounds.height,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )

        return gridPos
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator = coordinator else {
            super.scrollWheel(with: event)
            return
        }

        // 获取鼠标位置
        let location = convert(event.locationInWindow, from: nil)

        // 根据位置找到对应的 Panel
        guard let panelId = coordinator.findPanel(at: location, containerBounds: bounds),
              let panel = coordinator.terminalWindow.getPanel(panelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId else {
            super.scrollWheel(with: event)
            return
        }

        // 计算滚动量
        let deltaY = event.scrollingDeltaY

        if abs(deltaY) > 0.1 {
            let deltaLines = Int32(deltaY / 10.0)  // 调整滚动速度
            coordinator.handleScroll(terminalId: terminalId, deltaLines: deltaLines)
        }
    }

    deinit {
        print("[DDDPanelRenderView] 清理资源")
        NotificationCenter.default.removeObserver(self)
        shouldStopReading = true
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}

// MARK: - Preview

#Preview {
    DDDTerminalView()
        .frame(width: 1000, height: 800)
}
