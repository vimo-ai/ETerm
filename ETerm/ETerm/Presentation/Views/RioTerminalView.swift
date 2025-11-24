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
            RioRenderView(coordinator: coordinator)
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
    /// Page 栏视图（在顶部）
    private let pageBarView: PageBarView

    /// Metal 渲染层（在底部）
    let renderView: RioMetalView

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
        renderView = RioMetalView()
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - RioMetalView

class RioMetalView: NSView, RenderViewProtocol {

    weak var coordinator: TerminalWindowCoordinator?

    private var sugarloaf: SugarloafHandle?
    /// 多终端支持：每个终端一个独立的 richTextId
    private var richTextIds: [Int: Int] = [:]
    private var terminalPool: RioTerminalPoolWrapper?

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

            if window.isKeyWindow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.initialize()
                }
            }
        } else {
            NotificationCenter.default.removeObserver(self)
        }
    }

    /// 窗口切换屏幕时更新 scale（DPI 变化）
    @objc private func windowDidChangeScreen() {
        guard let window = window,
              let sugarloaf = sugarloaf else { return }

        let newScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let currentScale = layer?.contentsScale ?? 2.0

        // 只有 scale 变化时才更新
        if abs(newScale - currentScale) > 0.01 {

            // 更新 layer 的 scale
            layer?.contentsScale = newScale

            // 通知 Sugarloaf 更新 scale
            sugarloaf_rescale(sugarloaf, Float(newScale))

            // 更新 CoordinateMapper
            coordinateMapper = CoordinateMapper(scale: newScale, containerBounds: bounds)
            coordinator?.setCoordinateMapper(coordinateMapper!)

            // 触发 resize（使用新的 scale 计算物理尺寸）
            let width = Float(bounds.width * newScale)
            let height = Float(bounds.height * newScale)
            if width > 0 && height > 0 {
                sugarloaf_resize(sugarloaf, width, height)
            }

            // 重新渲染
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
        let width = Float(bounds.width * scale)
        let height = Float(bounds.height * scale)

        if width > 0 && height > 0 {
            sugarloaf_resize(sugarloaf, width, height)

            // 更新 coordinateMapper
            coordinateMapper = CoordinateMapper(scale: scale, containerBounds: bounds)
            coordinator?.setCoordinateMapper(coordinateMapper!)

            requestRender()
        }
    }

    // MARK: - Sugarloaf Initialization

    private func initializeSugarloaf() {
        guard let window = window else { return }

        // 优先使用 window 关联的 screen 的 scale，更可靠
        let effectiveScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let scale = Float(effectiveScale)
        let width = Float(bounds.width) * scale
        let height = Float(bounds.height) * scale

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

        guard let sugarloaf = sugarloaf else {
            print("[RioMetalView] Failed to create Sugarloaf")
            return
        }

        // fontMetrics 会在第一次创建 RichText 后更新为真实值
        // 这里先不获取，等 renderTerminal 中创建 RichText 后再更新

        // 创建 CoordinateMapper（使用前面定义的 effectiveScale）
        coordinateMapper = CoordinateMapper(scale: effectiveScale, containerBounds: bounds)
        coordinator?.setCoordinateMapper(coordinateMapper!)

        // 创建终端池
        terminalPool = RioTerminalPoolWrapper(sugarloafHandle: sugarloaf)

        // 设置渲染回调
        terminalPool?.onNeedsRender = { [weak self] in
            self?.requestRender()
        }

        // 设置终端池到 coordinator
        if let pool = terminalPool {
            coordinator?.setTerminalPool(pool)
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
        guard let sugarloaf = sugarloaf,
              let pool = terminalPool,
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
                sugarloaf: sugarloaf,
                pool: pool
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
        sugarloaf: SugarloafHandle,
        pool: RioTerminalPoolWrapper
    ) {
        guard let mapper = coordinateMapper else { return }
        guard let snapshot = pool.getSnapshot(terminalId: terminalId) else { return }

        // 1. 坐标转换：Swift 坐标 → Rust 逻辑坐标（Y 轴翻转）
        let logicalRect = mapper.swiftToRust(rect: contentBounds)

        // 2. 网格计算：使用物理像素计算 cols/rows
        // fontMetrics (cellWidth, lineHeight) 是物理像素
        // 所以需要用物理尺寸来计算
        let physicalWidth = logicalRect.width * mapper.scale
        let physicalHeight = logicalRect.height * mapper.scale
        let cols = UInt16(max(1, physicalWidth / cellWidth))
        let rows = UInt16(max(1, physicalHeight / lineHeight))

        // 3. Resize 终端（如果 cols/rows 变化了）
        if cols != snapshot.columns || rows != snapshot.screen_lines {
            _ = pool.resize(terminalId: terminalId, cols: cols, rows: rows)
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
            let cells = pool.getRowCells(terminalId: terminalId, rowIndex: rowIndex, maxCells: colsToRender)

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
            let char = String(Character(scalar))

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

            sugarloaf_content_add_text_full(
                content,
                char,
                fgR, fgG, fgB, 1.0,
                hasBg,
                bgR, bgG, bgB, 1.0,
                glyphWidth,
                hasCursor && snapshot.cursor_shape == 0,
                cursorR, cursorG, cursorB, cursorA
            )
        }
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

    // MARK: - 键盘输入

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    /// 拦截系统快捷键
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 如果有 KeyboardSystem，使用它处理
        if let keyboardSystem = coordinator?.keyboardSystem {
            let keyStroke = KeyStroke.from(event)

            // 需要拦截的系统快捷键
            let interceptedShortcuts: [KeyStroke] = [
                .cmd("w"),
                .cmd("t"),
                .cmd("n"),
                .cmdShift("w"),
                .cmdShift("t"),
                .cmd("["),
                .cmd("]"),
                .cmdShift("["),
                .cmdShift("]"),
                .cmd("="),
                .cmd("+"),  // Shift+= 产生 +
                .cmd("-"),
                .cmd("0"),
                .cmd("v"),
                .cmd("c"),
            ]

            let shouldIntercept = interceptedShortcuts.contains { $0.matches(keyStroke) }

            if shouldIntercept {
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
        guard let terminalId = coordinator?.getActiveTerminalId(),
              let pool = terminalPool else {
            super.keyDown(with: event)
            return
        }

        let keyStroke = KeyStroke.from(event)

        if handleEditShortcut(keyStroke, pool: pool, terminalId: Int(terminalId)) {
            return
        }

        if shouldHandleDirectly(keyStroke) {
            let sequence = keyStroke.toTerminalSequence()
            if !sequence.isEmpty {
                _ = pool.writeInput(terminalId: Int(terminalId), data: sequence)
            }
        } else {
            interpretKeyEvents([event])
        }
    }

    /// 处理编辑快捷键
    private func handleEditShortcut(_ keyStroke: KeyStroke, pool: RioTerminalPoolWrapper, terminalId: Int) -> Bool {
        // Cmd+C 复制选中文本
        if keyStroke.matches(.cmd("c")) {
            return handleCopy(terminalId: UInt32(terminalId))
        }

        // Cmd+V 粘贴
        if keyStroke.matches(.cmd("v")) {
            if let text = NSPasteboard.general.string(forType: .string) {
                _ = pool.writeInput(terminalId: terminalId, data: text)
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

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)

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

        // 触发渲染（事件驱动模式下必须手动触发）
        requestRender()

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
        guard let coordinator = coordinator,
              let terminalId = coordinator.getActiveTerminalId(),
              let pool = terminalPool else {
            super.scrollWheel(with: event)
            return
        }

        let deltaY = event.scrollingDeltaY
        let delta = Int32(deltaY / 3)

        if delta != 0 {
            _ = pool.scroll(terminalId: Int(terminalId), deltaLines: delta)
            requestRender()
        }
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
           let cursor = terminalPool?.getCursorPosition(terminalId: Int(terminalId)) {
            let x = CGFloat(cursor.col) * cellWidth
            let y = bounds.height - CGFloat(cursor.row + 1) * cellHeight

            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
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
        guard let terminalId = coordinator?.getActiveTerminalId(),
              let pool = terminalPool else { return }
        _ = pool.writeInput(terminalId: Int(terminalId), data: committedText)
    }
}
