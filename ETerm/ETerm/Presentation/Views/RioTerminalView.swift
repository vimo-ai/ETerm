//
//  RioTerminalView.swift
//  ETerm
//
//  照抄 Rio 渲染逻辑的终端视图（支持多窗口）
//
//  架构说明：
//  - 使用 TerminalWindowCoordinator 管理多窗口（Page/Panel/Tab）
//  - 复用 PageBarView 和 DomainPanelView 组件
//  - 使用 RioTerminalPoolWrapper 进行渲染
//

import SwiftUI
import AppKit
import Combine
import Metal
import QuartzCore

// MARK: - RioTerminalView

struct RioTerminalView: View {
    /// Coordinator 由 WindowManager 创建和管理，这里只是观察
    @ObservedObject var coordinator: TerminalWindowCoordinator

    var body: some View {
        ZStack {
            // 背景层 - 宣纸水墨风格（整体透明度 0.5，可调节）
            RicePaperView(showMountain: true, overallOpacity: 0.5) {
                EmptyView()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)  // 不拦截事件，让事件穿透到下面的渲染层

            // 渲染层
            RioRenderView(coordinator: coordinator)

            // Inline Writing Assistant Overlay (Cmd+K)
            if coordinator.showInlineComposer {
                VStack {
                    Spacer()

                    InlineComposerView(
                        onCancel: {
                            coordinator.showInlineComposer = false
                        },
                        coordinator: coordinator
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 20)
                }
            }

            // Terminal Search Overlay (Cmd+F)
            if coordinator.showTerminalSearch {
                VStack {
                    HStack {
                        Spacer()
                        TerminalSearchView(
                            searchText: $coordinator.searchText,
                            isVisible: $coordinator.showTerminalSearch,
                            matchCount: coordinator.searchMatches.count,
                            onClose: {
                                coordinator.clearSearch()
                            }
                        )
                        .padding(.trailing, 20)
                        .padding(.top, 50)  // 在 PageBar 下方
                    }
                    Spacer()
                }
                .onChange(of: coordinator.searchText) {
                    coordinator.performSearch()
                }
            }
        }
    }
}

// MARK: - NSViewRepresentable

struct RioRenderView: NSViewRepresentable {
    @ObservedObject var coordinator: TerminalWindowCoordinator

    func makeNSView(context: Context) -> RioContainerView {
        let containerView = RioContainerView()
        containerView.coordinator = coordinator
        coordinator.renderView = containerView.renderView
        return containerView
    }

    func updateNSView(_ nsView: RioContainerView, context: Context) {
        // 读取 updateTrigger 触发更新
        let _ = coordinator.updateTrigger

        // 读取对话框状态，触发 layout 更新
        let _ = coordinator.showInlineComposer
        let _ = coordinator.composerInputHeight

        // 触发 layout 重新计算（当对话框状态变化时）
        nsView.needsLayout = true

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

class RioContainerView: NSView {
    /// Page 栏视图（SwiftUI 桥接）
    private let pageBarView: PageBarHostingView

    /// Metal 渲染层（在底部）
    let renderView: RioMetalView

    /// Panel UI 视图列表（在上面）
    private var panelUIViews: [UUID: DomainPanelView] = [:]

    /// 分割线视图列表
    private var dividerViews: [DividerView] = []

    /// 分割线可拖拽区域宽度
    private let dividerHitAreaWidth: CGFloat = 6.0

    /// Page 栏高度
    private let pageBarHeight: CGFloat = PageBarHostingView.recommendedHeight()

    weak var coordinator: TerminalWindowCoordinator? {
        didSet {
            renderView.coordinator = coordinator
            setupPageBarCallbacks()
            updatePageBar()
            // 注意：Coordinator 的注册现在由 WindowManager 在创建窗口时完成
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 注意：Coordinator 的注册现在由 WindowManager 在创建窗口时完成
    }

    override init(frame frameRect: NSRect) {
        pageBarView = PageBarHostingView()
        renderView = RioMetalView()
        super.init(frame: frameRect)

        // 添加 Metal 层（底层）
        addSubview(renderView)

        // 添加 PageBar（顶层，最后添加确保在最上面）
        addSubview(pageBarView)

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

        // 监听窗口焦点变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        // 监听窗口即将关闭（用于清理资源）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }

        // 窗口关闭前清理资源
        cleanup()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }

        // 向所有启用了 Focus Reporting 的终端发送焦点获得事件
        if let rioPool = coordinator?.getTerminalPool() as? RioTerminalPoolWrapper {
            // RioTerminalPoolWrapper 暂不支持 Focus Reporting
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }

        // 向所有启用了 Focus Reporting 的终端发送焦点失去事件
        if let rioPool = coordinator?.getTerminalPool() as? RioTerminalPoolWrapper {
            // RioTerminalPoolWrapper 暂不支持 Focus Reporting
        }
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

        pageBarView.onPageReorder = { [weak coordinator] pageIds in
            _ = coordinator?.reorderPages(pageIds)
        }

        // 跨窗口拖拽：Page 拖出当前窗口
        pageBarView.onPageDragOutOfWindow = { [weak coordinator, weak self] pageId, screenPoint in
            guard let coordinator = coordinator,
                  let page = coordinator.terminalWindow.pages.first(where: { $0.pageId == pageId }) else {
                return
            }
            // 创建新窗口
            WindowManager.shared.createWindowWithPage(page, from: coordinator, at: screenPoint)
        }

        // 跨窗口拖拽：从其他窗口接收 Page
        pageBarView.onPageReceivedFromOtherWindow = { [weak self] pageId, sourceWindowNumber in
            guard let self = self,
                  let targetWindow = self.window,
                  let coordinator = self.coordinator else {
                return
            }

            let targetWindowNumber = targetWindow.windowNumber
            WindowManager.shared.movePage(pageId, from: sourceWindowNumber, to: targetWindowNumber)
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

        // PageBar 在顶部
        pageBarView.frame = CGRect(
            x: 0,
            y: bounds.height - pageBarHeight,
            width: bounds.width,
            height: pageBarHeight
        )

        // Metal 层填满 PageBar 下方区域（使用 contentBounds 属性，已考虑对话框空间）
        renderView.frame = contentBounds

        // 更新 Panel UI 视图
        updatePanelViews()
    }

    /// 计算底部预留空间（为对话框留出空间）
    private var bottomReservedSpace: CGFloat {
        if let coordinator = coordinator, coordinator.showInlineComposer {
            return coordinator.composerInputHeight + 30
        }
        return 0
    }

    /// 获取内容区域的 bounds（减去 PageBar 高度和底部预留空间）
    var contentBounds: CGRect {
        return CGRect(
            x: 0,
            y: bottomReservedSpace,
            width: bounds.width,
            height: bounds.height - pageBarHeight - bottomReservedSpace
        )
    }

    @objc func updatePanelViews() {
        guard let coordinator = coordinator else {
            return
        }

        // 更新 Page 栏
        updatePageBar()

        // 获取当前 Page 的所有 Panel
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

                // 设置 Page 激活状态（用于 Tab 通知逻辑）
                existingView.setPageActive(true)  // allPanels 中的都是当前激活 Page 的
            } else {
                // 创建新视图
                let view = DomainPanelView(panel: panel, coordinator: coordinator)
                view.frame = panel.bounds

                // 设置 Page 激活状态（用于 Tab 通知逻辑）
                view.setPageActive(true)  // allPanels 中的都是当前激活 Page 的

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
    private func calculateDividers(
        layout: PanelLayout,
        bounds: CGRect
    ) -> [(frame: CGRect, direction: SplitDirection)] {
        switch layout {
        case .leaf:
            return []

        case .split(let direction, let first, let second, let ratio):
            var result: [(CGRect, SplitDirection)] = []
            let dividerThickness: CGFloat = 1.0

            switch direction {
            case .horizontal:
                let firstWidth = bounds.width * ratio - dividerThickness / 2
                let dividerX = bounds.minX + firstWidth

                let frame = CGRect(
                    x: dividerX - dividerHitAreaWidth / 2 + dividerThickness / 2,
                    y: bounds.minY,
                    width: dividerHitAreaWidth,
                    height: bounds.height
                )
                result.append((frame, direction))

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
                let firstHeight = bounds.height * ratio - dividerThickness / 2
                let secondHeight = bounds.height * (1 - ratio) - dividerThickness / 2
                let dividerY = bounds.minY + secondHeight

                let frame = CGRect(
                    x: bounds.minX,
                    y: dividerY - dividerHitAreaWidth / 2 + dividerThickness / 2,
                    width: bounds.width,
                    height: dividerHitAreaWidth
                )
                result.append((frame, direction))

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

    /// 设置指定 Page 的提醒状态
    func setPageNeedsAttention(_ pageId: UUID, attention: Bool) {
        pageBarView.setPageNeedsAttention(pageId, attention: attention)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 清理资源（在窗口关闭前调用）
    func cleanup() {
        // 清理 Panel UI 视图
        for (_, view) in panelUIViews {
            view.removeFromSuperview()
        }
        panelUIViews.removeAll()

        // 清理分割线视图
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews.removeAll()

        // 清理渲染视图
        renderView.cleanup()

        // 断开 coordinator 引用
        coordinator = nil
    }
}

// MARK: - RioMetalView

class RioMetalView: NSView, RenderViewProtocol {

    weak var coordinator: TerminalWindowCoordinator?

    private var sugarloaf: SugarloafHandle?
    /// 多终端支持：每个终端一个独立的 richTextId
    private var richTextIds: [Int: Int] = [:]

    /// 全局终端管理器（便捷访问）
    private var terminalManager: GlobalTerminalManager { GlobalTerminalManager.shared }

    /// 字体度量（从 Sugarloaf 获取）
    private var cellWidth: CGFloat = 8.0
    private var cellHeight: CGFloat = 16.0
    private var lineHeight: CGFloat = 16.0

    /// 是否已初始化
    private var isInitialized = false

    /// 坐标映射器
    private var coordinateMapper: CoordinateMapper?

    // MARK: - 光标闪烁相关（照抄 Rio）

    private var lastBlinkToggle: Date?
    private var isBlinkingCursorVisible: Bool = true
    private var lastTypingTime: Date?
    private let blinkInterval: TimeInterval = 0.5

    // MARK: - 文本选择状态

    /// 是否正在拖拽选择
    private var isDraggingSelection: Bool = false
    /// 当前选择所在的 Panel ID
    private var selectionPanelId: UUID?
    /// 当前选择所在的 Tab
    private weak var selectionTab: TerminalTab?

    // MARK: - IME 支持

    /// IME 协调器
    private let imeCoordinator = IMECoordinator()

    /// 需要直接处理的特殊键 keyCode
    private let specialKeyCodes: Set<UInt16> = [
        36,   // Return
        48,   // Tab
        51,   // Delete
        53,   // Escape
        123,  // Left Arrow
        124,  // Right Arrow
        125,  // Down Arrow
        126,  // Up Arrow
        115,  // Home
        119,  // End
        116,  // Page Up
        121,  // Page Down
        117,  // Forward Delete
    ]

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func commonInit() {
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.isOpaque = false
        registerForDraggedTypes([.fileURL])
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

            // 监听屏幕切换（DPI 变化）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )

            // 监听窗口即将关闭（用于清理资源）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )

            // 不管 isKeyWindow 状态，都尝试初始化
            // 使用延迟确保视图布局完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.initialize()
            }
        } else {
            NotificationCenter.default.removeObserver(self)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // 窗口关闭前清理资源
        cleanup()
    }

    /// 窗口切换屏幕时更新 scale（DPI 变化）
    @objc private func windowDidChangeScreen() {
        guard let window = window,
              let sugarloaf = sugarloaf else { return }

        let newScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let currentScale = layer?.contentsScale ?? 2.0

        // 只有 scale 变化时才更新
        if abs(newScale - currentScale) > 0.01 {
            // 1. 更新 layer 的 scale
            layer?.contentsScale = newScale

            // 2. 通知 Sugarloaf 更新 scale（内部会自动更新 fontMetrics）
            sugarloaf_rescale(sugarloaf, Float(newScale))

            // 3. 不要在这里调用 resize！
            // layout() 会被自动调用，它会用正确的 scale 计算物理像素并调用 resize

            // 4. 更新 fontMetrics（rescale 后需要重新获取）
            updateFontMetricsFromSugarloaf(sugarloaf)

            // 5. 更新 CoordinateMapper
            let mapper = CoordinateMapper(scale: newScale, containerBounds: bounds)
            coordinateMapper = mapper
            coordinator?.setCoordinateMapper(mapper)

            // 6. 触发 layout（确保 resize 被正确调用）
            needsLayout = true
            layoutSubtreeIfNeeded()

            // 7. 重新渲染
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
        guard window != nil else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        isInitialized = true
        initializeSugarloaf()
    }

    override func layout() {
        super.layout()

        guard isInitialized, let sugarloaf = sugarloaf else { return }

        // 优先使用 window 关联的 screen 的 scale，更可靠
        let scale = window?.screen?.backingScaleFactor ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // ⚠️ 重要：resize 应该传逻辑像素，而不是物理像素
        // Rust 侧的 resize 会自动用 scale 计算物理像素
        let width = Float(bounds.width)
        let height = Float(bounds.height)

        if width > 0 && height > 0 {
            sugarloaf_resize(sugarloaf, width, height)

            // 更新 coordinateMapper
            let mapper = CoordinateMapper(scale: scale, containerBounds: bounds)
            coordinateMapper = mapper
            coordinator?.setCoordinateMapper(mapper)

            requestRender()
        }
    }

    // MARK: - Sugarloaf Initialization

    private func initializeSugarloaf() {
        guard let window = window else { return }

        // 优先使用 window 关联的 screen 的 scale，更可靠
        let effectiveScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let scale = Float(effectiveScale)

        // ⚠️ 重要：传递逻辑像素，Rust 侧会用 scale 计算物理像素
        let width = Float(bounds.width)
        let height = Float(bounds.height)

        layer?.contentsScale = effectiveScale

        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        let windowHandle = UnsafeMutableRawPointer(mutating: viewPointer)

        sugarloaf = sugarloaf_new(
            windowHandle,
            windowHandle,
            width,
            height,
            scale,
            14.0
        )

        guard let sugarloaf = sugarloaf else { return }

        // fontMetrics 会在第一次创建 RichText 后更新为真实值
        // 这里先不获取，等 renderTerminal 中创建 RichText 后再更新

        // 创建 CoordinateMapper（使用前面定义的 effectiveScale）
        let mapper = CoordinateMapper(scale: effectiveScale, containerBounds: bounds)
        coordinateMapper = mapper
        coordinator?.setCoordinateMapper(mapper)

        // 初始化全局终端管理器（第一个窗口时）
        if !terminalManager.isInitialized {
            terminalManager.initialize(with: sugarloaf)
        }

        // 注册 coordinator 到全局终端管理器
        if let coordinator = coordinator {
            coordinator.setGlobalTerminalManager(terminalManager)
        }

        // 初始渲染
        requestRender()
    }

    // MARK: - RenderViewProtocol

    func requestRender() {
        guard isInitialized else { return }

        DispatchQueue.main.async { [weak self] in
            self?.render()
        }
    }

    func changeFontSize(operation: SugarloafWrapper.FontSizeOperation) {
        guard let sugarloaf = sugarloaf else { return }

        // 对所有 RichText 调整字体大小
        for (_, richTextId) in richTextIds {
            sugarloaf_change_font_size(sugarloaf, richTextId, operation.rawValue)
        }

        // 更新 fontMetrics
        updateFontMetricsFromSugarloaf(sugarloaf)

        // 重新渲染
        requestRender()
    }

    func setPageNeedsAttention(_ pageId: UUID, attention: Bool) {
        // 通知 PageBarView 高亮指定的 Page
        // 需要通过 superview（RioContainerView）访问 pageBarView
        DispatchQueue.main.async { [weak self] in
            if let containerView = self?.superview as? RioContainerView {
                containerView.setPageNeedsAttention(pageId, attention: attention)
            }
        }
    }

    /// 从 Sugarloaf 更新 fontMetrics
    private func updateFontMetricsFromSugarloaf(_ sugarloaf: SugarloafHandle) {
        var metrics = SugarloafFontMetrics()
        if sugarloaf_get_font_metrics(sugarloaf, &metrics) {
            cellWidth = CGFloat(metrics.cell_width)
            cellHeight = CGFloat(metrics.cell_height)
            lineHeight = CGFloat(metrics.line_height > 0 ? metrics.line_height : metrics.cell_height)
            coordinator?.updateFontMetrics(metrics)
        }
    }

    /// 渲染所有 Panel（多终端支持）
    ///
    /// 使用累积模式：
    /// 1. 清空待渲染列表
    /// 2. 遍历每个终端，构建 RichText 内容并累积到列表
    /// 3. 统一提交所有 objects 并渲染
    private func render() {
        // 关键检查：如果已清理或未初始化，不执行渲染
        guard isInitialized,
              let sugarloaf = sugarloaf,
              let coordinator = coordinator else { return }

        // 从 coordinator 获取所有需要渲染的终端
        let tabsToRender = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: bounds,
            headerHeight: 30.0
        )

        // 如果没有终端，跳过渲染
        if tabsToRender.isEmpty { return }

        // 1. 清空待渲染列表（每帧开始）
        sugarloaf_clear_objects(sugarloaf)

        // 2. 渲染每个终端（累积 RichText 到列表）
        for (terminalId, contentBounds) in tabsToRender {
            renderTerminal(
                terminalId: Int(terminalId),
                contentBounds: contentBounds,
                sugarloaf: sugarloaf
            )
        }

        // 3. 统一提交所有 objects 并渲染（每帧结束）
        sugarloaf_flush_and_render(sugarloaf)
    }

    /// 渲染单个终端
    ///
    /// 多终端渲染：每个终端有独立的 richTextId，通过累积模式统一渲染。
    private func renderTerminal(
        terminalId: Int,
        contentBounds: CGRect,
        sugarloaf: SugarloafHandle
    ) {
        guard let mapper = coordinateMapper else { return }
        guard let snapshot = terminalManager.getSnapshot(terminalId: terminalId) else { return }

        // 1. 坐标转换：Swift 坐标 → Rust 逻辑坐标（Y 轴翻转）
        let logicalRect = mapper.swiftToRust(rect: contentBounds)

        // 2. 网格计算：使用物理像素计算 cols/rows
        // ✅ 关键修复：必须使用 coordinator.fontMetrics，和 screenToGrid 保持一致
        let physicalWidth = logicalRect.width * mapper.scale
        let physicalHeight = logicalRect.height * mapper.scale

        // 从 coordinator 获取字体度量，确保和坐标转换使用同一数据源
        let safeCellWidth: CGFloat
        let safeLineHeight: CGFloat
        if let metrics = coordinator?.fontMetrics {
            safeCellWidth = CGFloat(metrics.cell_width)
            safeLineHeight = CGFloat(metrics.line_height)
        } else {
            // Fallback
            safeCellWidth = 16.8
            safeLineHeight = 33.6
        }

        let cols = UInt16(max(1, min(physicalWidth / safeCellWidth, CGFloat(UInt16.max - 1))))
        let rows = UInt16(max(1, min(physicalHeight / safeLineHeight, CGFloat(UInt16.max - 1))))

        // 3. Resize 终端（如果 cols/rows 变化了）
        if cols != snapshot.columns || rows != snapshot.screen_lines {
            _ = terminalManager.resize(terminalId: terminalId, cols: cols, rows: rows)
        }

        // 4. 获取或创建该终端的 richTextId
        let richTextId: Int
        if let existingId = richTextIds[terminalId] {
            richTextId = existingId
        } else {
            // 为新终端创建 RichText
            let newId = Int(sugarloaf_create_rich_text(sugarloaf))
            richTextIds[terminalId] = newId
            richTextId = newId

            // 🎯 创建 RichText 后更新 fontMetrics（只需要更新一次）
            if richTextIds.count == 1 {
                updateFontMetricsFromSugarloaf(sugarloaf)
                // 请求重新渲染，下一帧会使用正确的 fontMetrics
                DispatchQueue.main.async { [weak self] in
                    self?.requestRender()
                }
            }
        }

        // 选择并清空 RichText
        sugarloaf_content_sel(sugarloaf, richTextId)
        sugarloaf_content_clear(sugarloaf)

        let isCursorVisible = calculateCursorVisibility(snapshot: snapshot)

        // 渲染每一行
        // 使用计算出的 rows（如果有效），否则使用 snapshot 中的值
        let linesToRender = rows > 0 ? Int(rows) : Int(snapshot.screen_lines)
        for rowIndex in 0..<linesToRender {
            if rowIndex > 0 {
                sugarloaf_content_new_line(sugarloaf)
            }

            let colsToRender = cols > 0 ? Int(cols) : Int(snapshot.columns)
            let cells = terminalManager.getRowCells(terminalId: terminalId, rowIndex: rowIndex, maxCells: colsToRender)

            renderLine(
                content: sugarloaf,
                cells: cells,
                rowIndex: rowIndex,
                snapshot: snapshot,
                isCursorVisible: isCursorVisible
            )
        }

        sugarloaf_content_build(sugarloaf)

        // 累积 RichText 到待渲染列表（不立即渲染）
        // 渲染在 render() 方法的 sugarloaf_flush_and_render 中统一执行
        sugarloaf_add_rich_text(
            sugarloaf,
            richTextId,
            Float(logicalRect.origin.x),
            Float(logicalRect.origin.y)
        )
    }

    /// 计算光标可见性
    private func calculateCursorVisibility(snapshot: TerminalSnapshot) -> Bool {
        if snapshot.cursor_visible == 0 {
            return false
        }

        if snapshot.blinking_cursor != 0 {
            let hasSelection = snapshot.has_selection != 0
            if !hasSelection {
                var shouldBlink = true

                if let lastTyping = lastTypingTime, Date().timeIntervalSince(lastTyping) < 1.0 {
                    shouldBlink = false
                }

                if shouldBlink {
                    let now = Date()
                    let shouldToggle: Bool

                    if let lastBlink = lastBlinkToggle {
                        shouldToggle = now.timeIntervalSince(lastBlink) >= blinkInterval
                    } else {
                        isBlinkingCursorVisible = true
                        lastBlinkToggle = now
                        shouldToggle = false
                    }

                    if shouldToggle {
                        isBlinkingCursorVisible = !isBlinkingCursorVisible
                        lastBlinkToggle = now
                    }
                } else {
                    isBlinkingCursorVisible = true
                    lastBlinkToggle = nil
                }

                return isBlinkingCursorVisible
            } else {
                isBlinkingCursorVisible = true
                lastBlinkToggle = nil
                return true
            }
        }

        return true
    }

    /// 渲染单行
    private func renderLine(
        content: SugarloafHandle,
        cells: [FFICell],
        rowIndex: Int,
        snapshot: TerminalSnapshot,
        isCursorVisible: Bool
    ) {
        // Ignore cursor position reports (ESC[row;colR) that can leak into the buffer
        if isCursorPositionReportLine(cells) {
            return
        }

        let cursorRow = Int(snapshot.cursor_row)
        let cursorCol = Int(snapshot.cursor_col)

        let INVERSE: UInt32 = 0x0001
        let WIDE_CHAR: UInt32 = 0x0020
        let WIDE_CHAR_SPACER: UInt32 = 0x0040
        let LEADING_WIDE_CHAR_SPACER: UInt32 = 0x0400

        for (colIndex, cell) in cells.enumerated() {
            let isSpacerFlag = cell.flags & (WIDE_CHAR_SPACER | LEADING_WIDE_CHAR_SPACER)
            if isSpacerFlag != 0 {
                continue
            }

            guard let scalar = UnicodeScalar(cell.character) else { continue }

            // 如果 cell 有 VS16 标记，追加 VS16 形成 emoji 样式
            let charToRender: String
            if cell.has_vs16 {
                charToRender = String(Character(scalar)) + "\u{FE0F}"
            } else {
                charToRender = String(Character(scalar))
            }

            let isWideChar = cell.flags & WIDE_CHAR != 0
            let glyphWidth: Float = isWideChar ? 2.0 : 1.0

            let isInverse = cell.flags & INVERSE != 0

            var fgR = Float(cell.fg_r) / 255.0
            var fgG = Float(cell.fg_g) / 255.0
            var fgB = Float(cell.fg_b) / 255.0

            var bgR = Float(cell.bg_r) / 255.0
            var bgG = Float(cell.bg_g) / 255.0
            var bgB = Float(cell.bg_b) / 255.0

            var hasBg = false
            if isInverse {
                let origFgR = fgR, origFgG = fgG, origFgB = fgB
                fgR = bgR; fgG = bgG; fgB = bgB
                bgR = origFgR; bgG = origFgG; bgB = origFgB
                hasBg = true
            } else {
                hasBg = bgR > 0.01 || bgG > 0.01 || bgB > 0.01
            }

            let hasCursor = isCursorVisible && rowIndex == cursorRow && colIndex == cursorCol

            let cursorR: Float = 1.0
            let cursorG: Float = 1.0
            let cursorB: Float = 1.0
            let cursorA: Float = 0.8

            if hasCursor && snapshot.cursor_shape == 0 {
                fgR = 0.0
                fgG = 0.0
                fgB = 0.0
            }

            if snapshot.has_selection != 0 {
                let selStartRow = Int(snapshot.selection_start_row)
                let selEndRow = Int(snapshot.selection_end_row)
                let selStartCol = Int(snapshot.selection_start_col)
                let selEndCol = Int(snapshot.selection_end_col)

                let inSelection = isInSelection(
                    row: rowIndex, col: colIndex,
                    startRow: selStartRow, startCol: selStartCol,
                    endRow: selEndRow, endCol: selEndCol
                )

                if inSelection {
                    fgR = 1.0
                    fgG = 1.0
                    fgB = 1.0
                    hasBg = true
                    bgR = 0.3
                    bgG = 0.5
                    bgB = 0.8
                }
            }

            // 搜索高亮（优先级低于选中高亮）
            if let coordinator = coordinator,
               !coordinator.searchMatches.isEmpty {
                // 计算绝对行号（考虑滚动偏移）
                let absoluteRow = rowIndex + Int(snapshot.display_offset)

                // 检查当前单元格是否在搜索匹配项中
                let isInSearchMatch = coordinator.searchMatches.contains { match in
                    match.row == absoluteRow &&
                    colIndex >= match.startCol &&
                    colIndex <= match.endCol
                }

                if isInSearchMatch {
                    // 黄色高亮背景
                    hasBg = true
                    bgR = 1.0
                    bgG = 1.0
                    bgB = 0.0
                    // 黑色前景（确保可读性）
                    fgR = 0.0
                    fgG = 0.0
                    fgB = 0.0
                }
            }

            // 使用实际的 alpha 值（支持半透明前景色，如 LightBlack = 50% foreground）
            let fgA = Float(cell.fg_a) / 255.0
            let bgA = Float(cell.bg_a) / 255.0

            sugarloaf_content_add_text_decorated(
                content,
                charToRender,
                fgR, fgG, fgB, fgA,
                hasBg,
                bgR, bgG, bgB, bgA,
                glyphWidth,
                hasCursor && snapshot.cursor_shape == 0,
                cursorR, cursorG, cursorB, cursorA,
                cell.flags
            )
        }
    }

    /// 检测是否为光标位置报告行（如 ESC[25;19R），用于过滤掉被 echo 到屏幕的 DSR 响应
    private func isCursorPositionReportLine(_ cells: [FFICell]) -> Bool {
        guard let first = cells.first, first.character == 27 else { return false }  // 必须以 ESC 开头

        var scalars: [UnicodeScalar] = []
        for cell in cells {
            // 停在第一个空字符，避免遍历整行的空白单元
            guard cell.character != 0 else { break }
            if let scalar = UnicodeScalar(cell.character) {
                scalars.append(scalar)
            }
            // 限制长度，防止异常长行走正则
            if scalars.count > 32 { return false }
        }

        guard !scalars.isEmpty else { return false }
        let text = String(String.UnicodeScalarView(scalars))

        // ^\e\[\d+;\d+R$ 形式的 DSR 响应
        return text.range(of: #"^\u{1B}\[\d+;\d+R$"#, options: .regularExpression) != nil
    }

    /// 检查位置是否在选区内
    private func isInSelection(
        row: Int, col: Int,
        startRow: Int, startCol: Int,
        endRow: Int, endCol: Int
    ) -> Bool {
        let (sRow, sCol, eRow, eCol): (Int, Int, Int, Int)
        if startRow < endRow || (startRow == endRow && startCol <= endCol) {
            (sRow, sCol, eRow, eCol) = (startRow, startCol, endRow, endCol)
        } else {
            (sRow, sCol, eRow, eCol) = (endRow, endCol, startRow, startCol)
        }

        if row < sRow || row > eRow {
            return false
        }

        if row == sRow && row == eRow {
            return col >= sCol && col <= eCol
        } else if row == sRow {
            return col >= sCol
        } else if row == eRow {
            return col <= eCol
        } else {
            return true
        }
    }

    // MARK: - Drag & Drop（文件/文件夹路径）

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFileURLs(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        containsFileURLs(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return false
        }

        guard let terminalId = coordinator?.getActiveTerminalId() else { return false }

        let paths = urls.map { $0.path }
        let payload = paths.joined(separator: " ") + " "
        _ = terminalManager.writeInput(terminalId: Int(terminalId), data: payload)
        return true
    }

    private func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || types.contains(.URL)
    }

    // MARK: - 键盘输入

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    /// 检查当前焦点是否在终端内
    ///
    /// 用于判断编辑类快捷键（Cmd+V, Cmd+C）是否应该被终端拦截。
    /// 如果焦点在对话框等其他 view 中，则不应该拦截。
    private func isFirstResponderInTerminal() -> Bool {
        guard let firstResponder = window?.firstResponder else { return false }

        // 遍历 responder chain，检查是否包含 self (RioMetalView)
        var responder: NSResponder? = firstResponder
        while let current = responder {
            if current == self {
                return true  // 焦点在终端内
            }
            responder = current.nextResponder
        }

        return false  // 焦点在其他地方（如对话框）
    }

    /// 拦截系统快捷键
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 如果 InlineComposer 正在显示，放行事件给文本框
        // 只保留 Cmd+K 的处理（用于关闭 composer）
        if coordinator?.showInlineComposer == true {
            if let keyboardSystem = coordinator?.keyboardSystem {
                let keyStroke = KeyStroke.from(event)
                // Cmd+K 关闭 composer
                if keyStroke.matches(.cmd("k")) {
                    coordinator?.showInlineComposer = false
                    return true
                }
            }
            return false  // 其他事件放行给 composer 文本框
        }

        // 如果有 KeyboardSystem，使用它处理
        if let keyboardSystem = coordinator?.keyboardSystem {
            let keyStroke = KeyStroke.from(event)

            // 需要拦截的系统快捷键
            let interceptedShortcuts: [KeyStroke] = [
                .cmd("k"),  // Inline AI Composer
                .cmd("f"),  // Terminal Search
                .cmd("w"),
                .cmd("t"),
                .cmd("n"),
                .cmdShift("w"),
                .cmdShift("t"),
                .cmd("["),
                .cmd("]"),
                .cmdShift("["),
                .cmdShift("]"),
                .cmdShift("y"),
                .cmd("="),
                .cmd("+"),  // Shift+= 产生 +
                .cmd("-"),
                .cmd("0"),
                .cmd("v"),
                .cmd("c"),
            ]

            let shouldIntercept = interceptedShortcuts.contains { $0.matches(keyStroke) }

            if shouldIntercept {
                // Cmd+K 直接处理，不经过键盘系统
                if keyStroke.matches(.cmd("k")) {
                    showInlineComposer()
                    return true
                }

                // Cmd+F 显示/隐藏搜索框
                if keyStroke.matches(.cmd("f")) {
                    coordinator?.toggleTerminalSearch()
                    return true
                }

                let result = keyboardSystem.handleKeyDown(event)
                switch result {
                case .handled:
                    return true
                case .passToIME:
                    return false
                }
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastTypingTime = Date()
        isBlinkingCursorVisible = true
        lastBlinkToggle = nil

        // 使用键盘系统处理
        if let keyboardSystem = coordinator?.keyboardSystem {
            let result = keyboardSystem.handleKeyDown(event)

            switch result {
            case .handled:
                return

            case .passToIME:
                interpretKeyEvents([event])
                return
            }
        }

        // 降级处理：直接发送到当前终端
        guard let terminalId = coordinator?.getActiveTerminalId() else {
            super.keyDown(with: event)
            return
        }

        let keyStroke = KeyStroke.from(event)

        if handleEditShortcut(keyStroke, terminalId: Int(terminalId)) {
            return
        }

        if shouldHandleDirectly(keyStroke) {
            let sequence = keyStroke.toTerminalSequence()
            if !sequence.isEmpty {
                _ = terminalManager.writeInput(terminalId: Int(terminalId), data: sequence)
            }
        } else {
            interpretKeyEvents([event])
        }
    }

    /// 处理编辑快捷键
    private func handleEditShortcut(_ keyStroke: KeyStroke, terminalId: Int) -> Bool {
        // Cmd+C 复制选中文本
        if keyStroke.matches(.cmd("c")) {
            return handleCopy(terminalId: UInt32(terminalId))
        }

        // Cmd+V 粘贴
        if keyStroke.matches(.cmd("v")) {
            if let text = NSPasteboard.general.string(forType: .string) {
                _ = terminalManager.writeInput(terminalId: terminalId, data: text)
            }
            return true
        }

        return false
    }

    /// 处理复制操作
    private func handleCopy(terminalId: UInt32) -> Bool {
        guard let activeTab = selectionTab,
              let selection = activeTab.textSelection,
              !selection.isEmpty,
              let coordinator = coordinator else {
            return false
        }

        // 从 Rust 获取选中的文本
        if let text = coordinator.getSelectedText(terminalId: terminalId, selection: selection) {
            // 复制到剪贴板
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true
        }

        return false
    }

    /// 判断是否应该直接处理
    private func shouldHandleDirectly(_ keyStroke: KeyStroke) -> Bool {
        if specialKeyCodes.contains(keyStroke.keyCode) {
            return true
        }

        if keyStroke.modifiers.contains(.control) {
            return true
        }

        if keyStroke.modifiers.contains(.option) && !keyStroke.modifiers.contains(.shift) {
            return true
        }

        return false
    }

    override func flagsChanged(with event: NSEvent) {
        // 处理修饰键
    }

    // MARK: - Inline AI Composer

    /// 显示 AI 命令输入框
    private func showInlineComposer() {
        guard let coordinator = coordinator else { return }

        // 计算输入框位置（在视图中心偏上）
        let centerX = bounds.midX
        let centerY = bounds.midY + 50  // 稍微偏上一点

        coordinator.composerPosition = CGPoint(x: centerX, y: centerY)
        coordinator.showInlineComposer = true
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

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

        // 双击选中单词
        if event.clickCount == 2 {
            selectWordAt(gridPos: gridPos, activeTab: activeTab, terminalId: terminalId, panelId: panelId, event: event)
            return
        }

        // 单击：开始拖拽选择
        activeTab.startSelection(at: gridPos)

        // 通知 Rust 层渲染高亮
        if let selection = activeTab.textSelection {
            _ = coordinator.setSelection(terminalId: terminalId, selection: selection)
        }

        // 触发渲染
        requestRender()

        // 记录选中状态
        isDraggingSelection = true
        selectionPanelId = panelId
        selectionTab = activeTab
    }

    // MARK: - 双击选中单词

    /// 双击选中单词（使用 WordBoundaryDetector 支持中文分词）
    private func selectWordAt(
        gridPos: CursorPosition,
        activeTab: TerminalTab,
        terminalId: UInt32,
        panelId: UUID,
        event: NSEvent
    ) {
        let row = Int(gridPos.row)
        let col = Int(gridPos.col)

        // 获取该行的所有单元格
        let cells = terminalManager.getRowCells(terminalId: Int(terminalId), rowIndex: row, maxCells: 500)
        guard !cells.isEmpty else { return }

        // 将单元格转换为字符串
        let lineText = cells.map { cell in
            guard let scalar = UnicodeScalar(cell.character) else { return " " }
            return String(Character(scalar))
        }.joined()

        // 使用 WordBoundaryDetector 查找词边界
        let detector = WordBoundaryDetector()
        guard let boundary = detector.findBoundary(in: lineText, at: col) else {
            return
        }

        // 设置选区
        let startPos = CursorPosition(col: UInt16(boundary.startIndex), row: UInt16(row))
        let endPos = CursorPosition(col: UInt16(boundary.endIndex - 1), row: UInt16(row))

        activeTab.startSelection(at: startPos)
        activeTab.updateSelection(to: endPos)

        // 通知 Rust 层渲染高亮
        if let selection = activeTab.textSelection {
            _ = coordinator?.setSelection(terminalId: terminalId, selection: selection)
        }

        // 触发渲染
        requestRender()

        // 记录选中状态（双击后不进入拖拽模式，直接完成选中）
        isDraggingSelection = false
        selectionPanelId = panelId
        selectionTab = activeTab

        // 发布选中结束事件（双击选中）
        let trimmed = boundary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let mouseLoc = self.convert(event.locationInWindow, from: nil)
            let rect = NSRect(origin: mouseLoc, size: NSSize(width: 1, height: 1))

            let payload = SelectionEndPayload(
                text: trimmed,
                screenRect: rect,
                sourceView: self
            )
            EventBus.shared.publish(TerminalEvent.selectionEnd, payload: payload)
        }
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

        // 触发渲染（事件驱动模式下必须手动触发）
        requestRender()
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
                    requestRender()
                } else {
                    // 发布选中结束事件（拖拽选中）
                    let mouseLoc = self.convert(event.locationInWindow, from: nil)
                    let rect = NSRect(origin: mouseLoc, size: NSSize(width: 1, height: 1))

                    let payload = SelectionEndPayload(
                        text: text,
                        screenRect: rect,
                        sourceView: self
                    )
                    EventBus.shared.publish(TerminalEvent.selectionEnd, payload: payload)
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
              let mapper = coordinateMapper else {
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
        let cellWidthVal: CGFloat
        let cellHeightVal: CGFloat
        if let metrics = coordinator.fontMetrics {
            // fontMetrics 是物理像素，需要转换为逻辑点
            cellWidthVal = CGFloat(metrics.cell_width) / mapper.scale
            cellHeightVal = CGFloat(metrics.line_height) / mapper.scale
        } else {
            cellWidthVal = 9.6
            cellHeightVal = 20.0
        }

        // 使用 CoordinateMapper 转换
        var gridPos = mapper.screenToGrid(
            screenPoint: location,
            panelOrigin: contentBounds.origin,
            panelHeight: contentBounds.height,
            cellWidth: cellWidthVal,
            cellHeight: cellHeightVal
        )

        // 边界检查：确保网格坐标不越界
        // 计算终端的行列数
        let physicalWidth = contentBounds.width * mapper.scale
        let physicalHeight = contentBounds.height * mapper.scale
        let maxCols = UInt16(physicalWidth / CGFloat(coordinator.fontMetrics?.cell_width ?? 15))
        let maxRows = UInt16(physicalHeight / CGFloat(coordinator.fontMetrics?.line_height ?? 33))

        // 限制在有效范围内（0 到 max-1）
        if maxCols > 0 && gridPos.col >= maxCols {
            gridPos = CursorPosition(col: maxCols - 1, row: gridPos.row)
        }
        if maxRows > 0 && gridPos.row >= maxRows {
            gridPos = CursorPosition(col: gridPos.col, row: maxRows - 1)
        }

        return gridPos
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator = coordinator else {
            super.scrollWheel(with: event)
            return
        }

        // 使用鼠标所在位置确定目标 Panel/Tab，再滚动对应终端
        let locationInView = convert(event.locationInWindow, from: nil)
        let terminalId = coordinator.getTerminalIdAtPoint(locationInView, containerBounds: bounds)

        guard let terminalId else {
            super.scrollWheel(with: event)
            return
        }

        // 默认每次滚动 1 行（根据方向确定正负）
        let deltaY = event.scrollingDeltaY
        let delta = Int32(deltaY == 0 ? 0 : (deltaY > 0 ? 1 : -1))

        if delta != 0 {
            _ = terminalManager.scroll(terminalId: Int(terminalId), deltaLines: delta)
            requestRender()
        }
    }

    /// 清理资源（在窗口关闭前调用）
    ///
    /// 必须在主线程调用，确保 Metal 渲染完成后再释放资源
    func cleanup() {
        // 标记为未初始化，阻止后续渲染
        isInitialized = false

        // 清除 coordinator 引用
        coordinator = nil

        // 清除 richTextIds（不再需要渲染）
        richTextIds.removeAll()

        // 清除坐标映射器
        coordinateMapper = nil

        // 注意：不在这里释放 sugarloaf handle
        // 因为 GlobalTerminalManager 可能还在使用同一个 Sugarloaf 实例
        // Sugarloaf 的生命周期由 GlobalTerminalManager 管理
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - NSTextInputClient (IME 支持)

extension RioMetalView: NSTextInputClient {

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let str = string as? String {
            text = str
        } else if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else {
            text = ""
        }

        // 如果有 KeyboardSystem，使用它的 IME 协调器
        if let keyboardSystem = coordinator?.keyboardSystem {
            keyboardSystem.imeCoordinator.setMarkedText(text)
        } else {
            imeCoordinator.setMarkedText(text)
        }
    }

    func unmarkText() {
        if let keyboardSystem = coordinator?.keyboardSystem {
            keyboardSystem.imeCoordinator.cancelComposition()
        } else {
            imeCoordinator.cancelComposition()
        }
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        let imeCoord = coordinator?.keyboardSystem?.imeCoordinator ?? imeCoordinator
        if imeCoord.isComposing {
            return NSRange(location: 0, length: imeCoord.markedText.count)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        return coordinator?.keyboardSystem?.imeCoordinator.isComposing ?? imeCoordinator.isComposing
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = window else {
            return .zero
        }

        // 获取光标位置用于输入法候选框定位
        if let terminalId = coordinator?.getActiveTerminalId(),
           let cursor = terminalManager.getCursor(terminalId: Int(terminalId)),
           let mapper = coordinateMapper {

            // ✅ 关键修复：cellWidth/cellHeight 是物理像素，需要转换为逻辑点
            // bounds 是逻辑坐标，必须用逻辑点来计算
            let logicalCellWidth = cellWidth / mapper.scale
            let logicalCellHeight = cellHeight / mapper.scale

            let x = CGFloat(cursor.col) * logicalCellWidth
            let y = bounds.height - CGFloat(cursor.row + 1) * logicalCellHeight

            let rect = CGRect(x: x, y: y, width: logicalCellWidth, height: logicalCellHeight)
            return window.convertToScreen(convert(rect, to: nil))
        }

        return window.convertToScreen(convert(bounds, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let str = string as? String {
            text = str
        } else if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else {
            return
        }

        // 通过 IME 协调器提交
        let imeCoord = coordinator?.keyboardSystem?.imeCoordinator ?? imeCoordinator
        let committedText = imeCoord.commitText(text)

        // 发送到终端
        guard let terminalId = coordinator?.getActiveTerminalId() else { return }
        _ = terminalManager.writeInput(terminalId: Int(terminalId), data: committedText)
    }
}
