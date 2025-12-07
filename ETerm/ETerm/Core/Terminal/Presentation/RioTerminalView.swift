//
//  RioTerminalView.swift
//  ETerm
//
//  终端视图（支持多窗口）
//
//  架构说明：
//  - 使用 TerminalWindowCoordinator 管理多窗口（Page/Panel/Tab）
//  - 复用 PageBarView 和 DomainPanelView 组件
//  - 使用 TerminalPoolWrapper 进行渲染（DDD 新架构）
//

import SwiftUI
import AppKit
import Combine
import Metal
import QuartzCore
import PanelLayoutKit

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
            .allowsHitTesting(false)  // 不拦截事件，让事件穿透到下面的渲染层

            // 渲染层（PageBar 已在 SwiftUI 层，这里不需要 ignoresSafeArea）
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
                TerminalSearchOverlay(coordinator: coordinator)
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
    /// Metal 渲染层（在底部）
    let renderView: RioMetalView

    /// Panel UI 视图列表（在上面）
    private var panelUIViews: [UUID: DomainPanelView] = [:]

    /// 分割线视图列表
    private var dividerViews: [DividerView] = []

    /// Active 终端内发光视图
    private let activeGlowView: ActiveTerminalGlowView

    /// 发光淡出定时器
    private var glowFadeOutTimer: Timer?

    /// 发光显示时长（秒）
    private let glowDisplayDuration: TimeInterval = 3.0

    /// 分割线可拖拽区域宽度
    private let dividerHitAreaWidth: CGFloat = 6.0

    /// PageBar 高度（SwiftUI 层的 PageBar，这里需要预留空间）
    private let pageBarHeight: CGFloat = 28

    weak var coordinator: TerminalWindowCoordinator? {
        didSet {
            renderView.coordinator = coordinator
            // 注意：Coordinator 的注册现在由 WindowManager 在创建窗口时完成
            // PageBar 已移至 SwiftUI 层（ContentView）
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 注意：Coordinator 的注册现在由 WindowManager 在创建窗口时完成
    }

    override init(frame frameRect: NSRect) {
        renderView = RioMetalView()
        activeGlowView = ActiveTerminalGlowView()
        super.init(frame: frameRect)

        // 添加 Metal 层（底层）
        addSubview(renderView)

        // 添加 Active 终端发光层（Metal 层之上）
        activeGlowView.isHidden = true  // 初始隐藏，有 active panel 时显示
        addSubview(activeGlowView)

        // PageBar 已移至 SwiftUI 层（ContentView）

        // 监听状态变化，更新 UI
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

        // 窗口获得焦点时显示发光效果
        showActiveGlow()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }

        // 窗口失去焦点时立即隐藏发光
        hideActiveGlow()
    }

    /// 显示 Active 终端发光效果
    private func showActiveGlow() {
        // 取消之前的淡出定时器
        glowFadeOutTimer?.invalidate()

        // 更新发光位置并显示
        guard let coordinator = coordinator else { return }
        let panels = coordinator.terminalWindow.allPanels
        updateActiveGlow(panels: panels, activePanelId: coordinator.activePanelId, forceShow: true)

        // 设置淡出定时器
        glowFadeOutTimer = Timer.scheduledTimer(withTimeInterval: glowDisplayDuration, repeats: false) { [weak self] _ in
            self?.fadeOutActiveGlow()
        }
    }

    /// 淡出隐藏发光效果
    private func fadeOutActiveGlow() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            activeGlowView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.activeGlowView.isHidden = true
            self?.activeGlowView.alphaValue = 1  // 重置 alpha 供下次使用
        }
    }

    /// 立即隐藏发光效果
    private func hideActiveGlow() {
        glowFadeOutTimer?.invalidate()
        glowFadeOutTimer = nil
        activeGlowView.isHidden = true
    }

    // PageBar 相关回调和更新方法已移至 SwiftUI 层（SwiftUIPageBar）

    override func layout() {
        super.layout()

        // Metal 层填满整个区域（PageBar 已移至 SwiftUI 层）
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

    /// 获取内容区域的 bounds（减去顶部 PageBar 高度和底部预留空间）
    /// PageBar 在 SwiftUI 层但覆盖在此视图上方，需要预留空间
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

        // PageBar 已移至 SwiftUI 层，通过 @ObservedObject 自动更新

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

                // 设置 Panel 激活状态（用于 Tab 颜色高亮）
                let isPanelActive = (panel.panelId == coordinator.activePanelId)
                existingView.setPanelActive(isPanelActive)
            } else {
                // 创建新视图
                let view = DomainPanelView(panel: panel, coordinator: coordinator)
                view.frame = panel.bounds

                // 设置 Page 激活状态（用于 Tab 通知逻辑）
                view.setPageActive(true)  // allPanels 中的都是当前激活 Page 的

                // 设置 Panel 激活状态（用于 Tab 颜色高亮）
                let isPanelActive = (panel.panelId == coordinator.activePanelId)
                view.setPanelActive(isPanelActive)

                addSubview(view)
                panelUIViews[panel.panelId] = view
            }
        }

        // 更新分割线
        updateDividers()

        // 只更新发光位置，不改变显示状态（显示由窗口焦点控制）
        updateActiveGlow(panels: panels, activePanelId: coordinator.activePanelId, forceShow: false)
    }

    /// 更新 Active 终端发光视图
    /// - Parameters:
    ///   - panels: 所有 Panel
    ///   - activePanelId: 激活的 Panel ID
    ///   - forceShow: 是否强制显示（窗口获得焦点时为 true）
    private func updateActiveGlow(panels: [EditorPanel], activePanelId: UUID?, forceShow: Bool) {
        // 只有多个 Panel 时才需要显示发光提示
        guard panels.count > 1 else {
            activeGlowView.isHidden = true
            return
        }

        // 找到 active panel
        guard let activePanelId = activePanelId,
              let activePanel = panels.first(where: { $0.panelId == activePanelId }) else {
            activeGlowView.isHidden = true
            return
        }

        // 计算终端内容区域（panel.bounds 减去 header 高度）
        let headerHeight: CGFloat = 30.0
        let panelBounds = activePanel.bounds
        let contentFrame = CGRect(
            x: panelBounds.origin.x,
            y: panelBounds.origin.y,
            width: panelBounds.width,
            height: panelBounds.height - headerHeight
        )

        // 更新发光视图位置
        activeGlowView.frame = contentFrame

        // 确保发光视图在 Panel UI 之下但在 Metal 层之上
        activeGlowView.removeFromSuperview()
        addSubview(activeGlowView, positioned: .above, relativeTo: renderView)

        // 只有 forceShow 时才显示，否则保持当前状态
        if forceShow {
            activeGlowView.alphaValue = 1
            activeGlowView.isHidden = false
        }
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
            bounds: contentBounds,
            path: []
        )

        // 创建分割线视图
        for (frame, direction, layoutPath, splitBounds) in dividers {
            let view = DividerView(frame: frame)
            view.direction = direction
            view.layoutPath = layoutPath
            view.coordinator = coordinator
            view.splitBounds = splitBounds
            // 分割线必须在 panelUIViews 之上才能接收鼠标事件
            addSubview(view)
            dividerViews.append(view)
        }
    }

    /// 递归计算分割线位置
    private func calculateDividers(
        layout: PanelLayout,
        bounds: CGRect,
        path: [Int]
    ) -> [(frame: CGRect, direction: SplitDirection, layoutPath: [Int], splitBounds: CGRect)] {
        switch layout {
        case .leaf:
            return []

        case .split(let direction, let first, let second, let ratio):
            var result: [(CGRect, SplitDirection, [Int], CGRect)] = []
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
                // 添加当前分割线（path 指向当前分割节点，splitBounds 是整个分割区域）
                result.append((frame, direction, path, bounds))

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
                // 递归处理子节点（path + 0 for first, path + 1 for second）
                result += calculateDividers(layout: first, bounds: firstBounds, path: path + [0])
                result += calculateDividers(layout: second, bounds: secondBounds, path: path + [1])

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
                // 添加当前分割线（path 指向当前分割节点，splitBounds 是整个分割区域）
                result.append((frame, direction, path, bounds))

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
                // 递归处理子节点（path + 0 for first, path + 1 for second）
                result += calculateDividers(layout: first, bounds: firstBounds, path: path + [0])
                result += calculateDividers(layout: second, bounds: secondBounds, path: path + [1])
            }

            return result
        }
    }

    /// 设置指定 Page 的提醒状态
    /// PageBar 已移至 SwiftUI 层，通过 Notification 通知
    func setPageNeedsAttention(_ pageId: UUID, attention: Bool) {
        // 通过通知机制传递到 SwiftUI 层
        NotificationCenter.default.post(
            name: NSNotification.Name("PageNeedsAttention"),
            object: nil,
            userInfo: ["pageId": pageId, "attention": attention]
        )
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

    // 新架构：TerminalPool wrapper（多终端管理 + 统一渲染）
    private var terminalPool: TerminalPoolWrapper?

    /// 公开 bounds 供 Coordinator 访问（用于布局同步）
    /// 注意：NSView.bounds 是 public，这里只是明确声明以便 Coordinator 使用
    override var bounds: NSRect {
        get { super.bounds }
        set { super.bounds = newValue }
    }
    /// 多终端支持：每个终端一个独立的 richTextId
    private var richTextIds: [Int: Int] = [:]

    /// 字体度量（从 Sugarloaf 获取）
    private var cellWidth: CGFloat = 8.0
    private var cellHeight: CGFloat = 16.0
    private var lineHeight: CGFloat = 16.0

    /// 是否已初始化
    private var isInitialized = false

    /// 坐标映射器
    private var coordinateMapper: CoordinateMapper?


    // MARK: - Render Scheduler（帧率限制 - Rust CVDisplayLink）

    /// Rust 侧的渲染调度器（新架构使用，替代 Swift CVDisplayLink）
    private var renderScheduler: RenderSchedulerWrapper?

    /// 需要渲染的标记（原子操作）
    private var needsRender = false
    private let needsRenderLock = NSLock()

    /// 渲染性能统计
    private var renderCount: Int = 0
    private var lastStatTime: Date = Date()
    private var skipCount: Int = 0  // CVDisplayLink 跳过的帧数
    private var totalRenderTime: TimeInterval = 0  // 累计渲染耗时
    private var maxRenderTime: TimeInterval = 0    // 最大单帧耗时
    private var requestCount: Int = 0  // requestRender 调用次数

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
        guard let window = window else { return }

        let newScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let currentScale = layer?.contentsScale ?? 2.0

        // 只有 scale 变化时才更新
        if abs(newScale - currentScale) > 0.01 {
            // 1. 更新 layer 的 scale
            layer?.contentsScale = newScale

            // 2. 更新 CoordinateMapper
            let mapper = CoordinateMapper(scale: newScale, containerBounds: bounds)
            coordinateMapper = mapper
            coordinator?.setCoordinateMapper(mapper)

            // 3. 触发 layout（确保 resize 被正确调用）
            needsLayout = true
            layoutSubtreeIfNeeded()

            // 4. 同步布局到 Rust（DPI 变化）
            coordinator?.syncLayoutToRust()

            // 5. 重新渲染
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

        guard isInitialized, let pool = terminalPool else { return }

        // 优先使用 window 关联的 screen 的 scale
        let scale = window?.screen?.backingScaleFactor ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        if bounds.width > 0 && bounds.height > 0 {
            // 1. 调整 Sugarloaf 渲染表面大小
            pool.resizeSugarloaf(width: Float(bounds.width), height: Float(bounds.height))

            // 2. 更新 coordinateMapper
            let mapper = CoordinateMapper(scale: scale, containerBounds: bounds)
            coordinateMapper = mapper
            coordinator?.setCoordinateMapper(mapper)

            // 3. 同步布局到 Rust（通知各终端尺寸变化）
            coordinator?.syncLayoutToRust()

            requestRender()
        }
    }

    // MARK: - Sugarloaf Initialization

    private func initializeSugarloaf() {
        guard let window = window else { return }

        // 新架构：创建 TerminalPoolWrapper（多终端管理 + 统一渲染）
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()

        // 优先使用 window 关联的 screen 的 scale，更可靠
        let effectiveScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor

        print("📐 [RioMetalView] Initializing TerminalPoolWrapper (bounds: \(bounds.width)x\(bounds.height), scale: \(effectiveScale))")

        // 创建 TerminalPoolWrapper
        terminalPool = TerminalPoolWrapper(
            windowHandle: viewPointer,
            displayHandle: viewPointer,
            width: Float(bounds.width),
            height: Float(bounds.height),
            scale: Float(effectiveScale),
            fontSize: 14.0
        )

        guard let pool = terminalPool else {
            print("⚠️ [RioMetalView] Failed to create TerminalPoolWrapper")
            return
        }

        // 设置渲染回调
        pool.setRenderCallback { [weak self] in
            self?.requestRender()
        }

        // 设置 Bell 回调
        pool.onBell = { _ in
            DispatchQueue.main.async {
                NSSound.beep()
            }
        }

        // 将 TerminalPool 注册到 Coordinator
        if let coordinator = coordinator {
            coordinator.setTerminalPool(pool)
        }

        // 更新 coordinateMapper
        let mapper = CoordinateMapper(scale: effectiveScale, containerBounds: bounds)
        coordinateMapper = mapper
        coordinator?.setCoordinateMapper(mapper)

        // 启动 Rust CVDisplayLink（替代 Swift CVDisplayLink）
        setupRenderScheduler()

        // 初始渲染
        requestRender()
    }

    // MARK: - Render Scheduler Setup (Rust CVDisplayLink)

    /// 设置 Rust 侧的渲染调度器
    private func setupRenderScheduler() {
        guard let pool = terminalPool else {
            print("⚠️ [RenderScheduler] TerminalPool not ready")
            return
        }

        // 创建 RenderScheduler
        let scheduler = RenderSchedulerWrapper()
        self.renderScheduler = scheduler

        // 绑定到 TerminalPool（共享 needs_render 标记）
        scheduler.bind(to: pool)

        // 设置渲染回调
        scheduler.setRenderCallback { [weak self] in
            self?.renderIfNeeded()
        }

        // 启动
        if scheduler.start() {
            print("✅ [RioMetalView] RenderScheduler started (Rust CVDisplayLink)")
        }
    }

    // MARK: - Rendering

    /// 仅在需要时渲染（由 RenderScheduler 调用）
    private func renderIfNeeded() {
        needsRenderLock.lock()
        let shouldRender = needsRender
        needsRender = false
        needsRenderLock.unlock()

        if shouldRender {
            // 测量渲染耗时
            let startTime = Date()
            render()
            let renderTime = Date().timeIntervalSince(startTime)

            renderCount += 1
            totalRenderTime += renderTime
            maxRenderTime = max(maxRenderTime, renderTime)

            // 每秒统计一次
            let now = Date()
            if now.timeIntervalSince(lastStatTime) >= 1.0 {
                let duration = now.timeIntervalSince(lastStatTime)
                let fps = Double(renderCount) / duration
                let avgRenderTime = renderCount > 0 ? totalRenderTime / Double(renderCount) * 1000 : 0
                let maxRenderTimeMs = maxRenderTime * 1000
                let skipRate = Double(skipCount) / Double(renderCount + skipCount) * 100

                // 性能统计日志（已注释，需要时取消注释）
                // print("📊 [Performance Stats]")
                // print("   FPS: \(String(format: "%.1f", fps)) (actual renders)")
                // print("   requestRender() calls: \(requestCount) (\(String(format: "%.1f", Double(requestCount) / duration))/sec)")
                // print("   Skipped frames: \(skipCount) (\(String(format: "%.1f", skipRate))%)")
                // print("   Avg render time: \(String(format: "%.2f", avgRenderTime))ms")
                // print("   Max render time: \(String(format: "%.2f", maxRenderTimeMs))ms")

                // 重置统计
                renderCount = 0
                skipCount = 0
                requestCount = 0
                totalRenderTime = 0
                maxRenderTime = 0
                lastStatTime = now
            }
        } else {
            skipCount += 1
        }
    }

    // MARK: - RenderViewProtocol

    func requestRender() {
        guard isInitialized else { return }

        // 只标记需要渲染，实际渲染由 CVDisplayLink 在下一帧执行
        needsRenderLock.lock()
        needsRender = true
        requestCount += 1
        needsRenderLock.unlock()

        // 通知 Rust 侧的 RenderScheduler
        renderScheduler?.requestRender()
    }

    func changeFontSize(operation: FontSizeOperation) {
        // 新架构：通过 TerminalPoolWrapper 调整字体大小
        terminalPool?.changeFontSize(operation: operation)
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


    /// 渲染所有 Panel（多终端支持）
    ///
    /// 三层分离架构：
    /// - 高层数据层：TerminalWindowCoordinator 管理布局信息
    /// - 同步层：布局变化时主动调用 syncLayoutToRust()
    /// - 渲染层：每帧只负责纯渲染，不管布局
    private func render() {
        // 关键检查：如果已清理或未初始化，不执行渲染
        guard isInitialized else { return }

        // 新架构：统一提交模式
        // beginFrame() → renderTerminal(id, x, y) × N → endFrame()
        guard let pool = terminalPool,
              let coordinator = coordinator else { return }

        // 获取所有需要渲染的终端及其位置
        let tabsToRender = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: bounds,
            headerHeight: 30.0
        )

        // 开始新的一帧
        pool.beginFrame()

        // 渲染每个终端到指定位置
        for (terminalId, contentBounds) in tabsToRender {
            // contentBounds 是 Swift 坐标系（左下角原点）
            // 需要转换为 Rust 坐标系（左上角原点）
            let x = Float(contentBounds.origin.x)
            let y = Float(bounds.height - contentBounds.origin.y - contentBounds.height)
            let width = Float(contentBounds.width)
            let height = Float(contentBounds.height)
            _ = pool.renderTerminal(Int(terminalId), x: x, y: y, width: width, height: height)
        }

        // 结束帧（统一提交渲染）
        pool.endFrame()
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

        _ = terminalPool?.writeInput(terminalId: Int(terminalId), data: payload)
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
        // 检查当前焦点是否在文本输入框（如设置页面）
        if let firstResponder = window?.firstResponder as? NSText {
            // 如果是 NSText（TextField/SecureField），不拦截，让系统处理
            return false
        }

        // 如果 InlineComposer 正在显示，放行事件给文本框
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

        // 所有快捷键都通过 KeyboardSystem 处理
        if let keyboardSystem = coordinator?.keyboardSystem {
            let result = keyboardSystem.handleKeyDown(event)
            switch result {
            case .handled:
                return true
            case .passToIME:
                return false
            }
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        lastTypingTime = Date()
        isBlinkingCursorVisible = true
        lastBlinkToggle = nil

        guard let pool = terminalPool,
              let terminalId = coordinator?.getActiveTerminalId() else {
            super.keyDown(with: event)
            return
        }

        let keyStroke = KeyStroke.from(event)

        // 处理编辑快捷键（Cmd+C/V）
        if handleEditShortcut(keyStroke, pool: pool) {
            return
        }

        // 转换为终端序列并发送到当前激活终端
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
    private func handleEditShortcut(_ keyStroke: KeyStroke, pool: TerminalPoolWrapper) -> Bool {
        guard let terminalId = coordinator?.getActiveTerminalId() else {
            return false
        }

        // Cmd+C 复制
        if keyStroke.matches(.cmd("c")) {
            // 直接从 Rust 获取选中文本
            if let text = pool.getSelectionText(terminalId: Int(terminalId)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return true
            }
            return false
        }

        // Cmd+V 粘贴
        if keyStroke.matches(.cmd("v")) {
            if let text = NSPasteboard.general.string(forType: .string) {
                _ = pool.writeInput(terminalId: Int(terminalId), data: text)
            }
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
        guard let panelId = coordinator.findPanel(at: location, containerBounds: bounds) else {
            super.mouseDown(with: event)
            return
        }

        guard let panel = coordinator.terminalWindow.getPanel(panelId) else {
            super.mouseDown(with: event)
            return
        }

        guard let activeTab = panel.activeTab else {
            super.mouseDown(with: event)
            return
        }

        guard let terminalId = activeTab.rustTerminalId else {
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
        // 将 Screen 坐标转换为真实行号（新架构使用 terminalPool）
        guard let pool = terminalPool,
              let (absoluteRow, col) = pool.screenToAbsolute(
                  terminalId: Int(terminalId),
                  screenRow: Int(gridPos.row),
                  screenCol: Int(gridPos.col)
              ) else {
            super.mouseDown(with: event)
            return
        }

        activeTab.startSelection(absoluteRow: absoluteRow, col: UInt16(col))

        // 通知 Rust 层渲染高亮（新架构使用 terminalPool）
        if let selection = activeTab.textSelection {
            _ = pool.setSelection(
                terminalId: Int(terminalId),
                startAbsoluteRow: selection.startAbsoluteRow,
                startCol: Int(selection.startCol),
                endAbsoluteRow: selection.endAbsoluteRow,
                endCol: Int(selection.endCol)
            )
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
        // 新架构：使用 terminalPool
        guard let pool = terminalPool else { return }

        let row = Int(gridPos.row)
        let col = Int(gridPos.col)

        // 直接调用 Rust API 获取单词边界（支持中文分词）
        guard let boundary = pool.getWordAt(
            terminalId: Int(terminalId),
            screenRow: row,
            screenCol: col
        ) else {
            return
        }

        // 设置选区（使用绝对行号）
        activeTab.startSelection(absoluteRow: boundary.absoluteRow, col: UInt16(boundary.startCol))
        activeTab.updateSelection(absoluteRow: boundary.absoluteRow, col: UInt16(boundary.endCol))

        // 通知 Rust 层渲染高亮（新架构：使用 terminalPool）
        if let selection = activeTab.textSelection {
            _ = pool.setSelection(
                terminalId: Int(terminalId),
                startAbsoluteRow: selection.startAbsoluteRow,
                startCol: Int(selection.startCol),
                endAbsoluteRow: selection.endAbsoluteRow,
                endCol: Int(selection.endCol)
            )
        }

        // 触发渲染
        requestRender()

        // 记录选中状态（双击后不进入拖拽模式，直接完成选中）
        isDraggingSelection = false
        selectionPanelId = panelId
        selectionTab = activeTab

        // 发布选中结束事件（双击选中）
        let trimmed = boundary.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
              let pool = terminalPool else {
            super.mouseDragged(with: event)
            return
        }

        // 获取鼠标位置
        let location = convert(event.locationInWindow, from: nil)

        // 转换为网格坐标
        let gridPos = screenToGrid(location: location, panelId: panelId)

        // 将 Screen 坐标转换为真实行号（新架构：使用 terminalPool）
        guard let (absoluteRow, col) = pool.screenToAbsolute(
            terminalId: Int(terminalId),
            screenRow: Int(gridPos.row),
            screenCol: Int(gridPos.col)
        ) else {
            super.mouseDragged(with: event)
            return
        }

        // 更新 Domain 层状态
        activeTab.updateSelection(absoluteRow: absoluteRow, col: UInt16(col))

        // 通知 Rust 层渲染高亮（新架构：使用 terminalPool）
        if let selection = activeTab.textSelection {
            _ = pool.setSelection(
                terminalId: Int(terminalId),
                startAbsoluteRow: selection.startAbsoluteRow,
                startCol: Int(selection.startCol),
                endAbsoluteRow: selection.endAbsoluteRow,
                endCol: Int(selection.endCol)
            )
        }

        // 触发渲染（事件驱动模式下必须手动触发）
        requestRender()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingSelection else {
            super.mouseUp(with: event)
            return
        }

        // 完成选区（业务逻辑在 Rust 端处理）
        // - 如果选区全是空白，Rust 会自动清除选区并返回 nil
        // - 如果有内容，返回选中的文本
        if let activeTab = selectionTab,
           let terminalId = activeTab.rustTerminalId,
           let pool = terminalPool {
            if let text = pool.finalizeSelection(terminalId: Int(terminalId)) {
                // 有有效选区，发布选中结束事件
                let mouseLoc = self.convert(event.locationInWindow, from: nil)
                let rect = NSRect(origin: mouseLoc, size: NSSize(width: 1, height: 1))

                let payload = SelectionEndPayload(
                    text: text,
                    screenRect: rect,
                    sourceView: self
                )
                EventBus.shared.publish(TerminalEvent.selectionEnd, payload: payload)
            } else {
                // 选区被清除（全是空白），同步清除 Swift 侧状态
                activeTab.clearSelection()
            }

            // 触发重新渲染
            requestRender()
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
        if let metrics = terminalPool?.getFontMetrics() {
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
        // 计算终端的行列数（使用与上面相同的 metrics 来源）
        let physicalWidth = contentBounds.width * mapper.scale
        let physicalHeight = contentBounds.height * mapper.scale
        let physicalCellWidth = cellWidthVal * mapper.scale
        let physicalLineHeight = cellHeightVal * mapper.scale
        let maxCols = UInt16(physicalWidth / physicalCellWidth)
        let maxRows = UInt16(physicalHeight / physicalLineHeight)

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
        guard let pool = terminalPool,
              let coordinator = coordinator else {
            super.scrollWheel(with: event)
            return
        }

        // 使用鼠标所在位置确定目标终端
        let locationInView = convert(event.locationInWindow, from: nil)
        let terminalId = coordinator.getTerminalIdAtPoint(locationInView, containerBounds: bounds)

        guard let terminalId else {
            super.scrollWheel(with: event)
            return
        }

        let deltaY = event.scrollingDeltaY
        let scrollLines: Int32
        if event.hasPreciseScrollingDeltas {
            scrollLines = Int32(round(deltaY / 10.0))
        } else {
            scrollLines = Int32(deltaY * 3)
        }

        if scrollLines != 0 {
            _ = pool.scroll(terminalId: Int(terminalId), deltaLines: scrollLines)
            requestRender()
        }
    }

    /// 清理资源（在窗口关闭前调用）
    ///
    /// 必须在主线程调用，确保 Metal 渲染完成后再释放资源
    func cleanup() {
        // 停止 Rust RenderScheduler
        renderScheduler?.stop()
        renderScheduler = nil

        // 标记为未初始化，阻止后续渲染
        isInitialized = false

        // 清除 coordinator 引用
        coordinator = nil

        // 清除 richTextIds（不再需要渲染）
        richTextIds.removeAll()

        // 清除坐标映射器
        coordinateMapper = nil

        // 清理 TerminalPoolWrapper
        terminalPool = nil
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

        // 获取光标位置用于输入法候选框定位（新架构：使用 terminalPool）
        if let terminalId = coordinator?.getActiveTerminalId(),
           let pool = terminalPool,
           let cursor = pool.getCursorPosition(terminalId: Int(terminalId)),
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

        // 新架构：发送键盘输入到当前激活的终端
        if let terminalId = coordinator?.getActiveTerminalId() {
            _ = terminalPool?.writeInput(terminalId: Int(terminalId), data: committedText)
        }
    }
}

// MARK: - Terminal Search Overlay

struct TerminalSearchOverlay: View {
    @ObservedObject var coordinator: TerminalWindowCoordinator
    @State private var searchText: String = ""

    var body: some View {
        VStack {
            HStack {
                Spacer()

                // 搜索框
                HStack(spacing: 8) {
                    // 搜索图标
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))

                    // 搜索输入框
                    TextField("搜索...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .frame(width: 200)
                        .onSubmit {
                            if !searchText.isEmpty {
                                coordinator.startSearch(pattern: searchText)
                            }
                        }

                    // 匹配数量和导航
                    if let searchInfo = coordinator.currentTabSearchInfo {
                        HStack(spacing: 4) {
                            Text("\(searchInfo.currentIndex)/\(searchInfo.totalCount)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            // 上一个
                            Button(action: {
                                coordinator.searchPrev()
                            }) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(searchInfo.totalCount == 0)

                            // 下一个
                            Button(action: {
                                coordinator.searchNext()
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(searchInfo.totalCount == 0)
                        }
                    }

                    // 关闭按钮
                    Button(action: {
                        coordinator.clearSearch()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                )
                .padding(.trailing, 20)
                .padding(.top, 50)  // 在 PageBar 下方
            }
            Spacer()
        }
        .onChange(of: coordinator.activePanelId) {
            // Tab 切换时，更新搜索框内容
            if let searchInfo = coordinator.currentTabSearchInfo {
                searchText = searchInfo.pattern
            } else {
                searchText = ""
            }
        }
        .onAppear {
            // 从当前 Tab 的搜索信息恢复文本
            if let searchInfo = coordinator.currentTabSearchInfo {
                searchText = searchInfo.pattern
            }
        }
    }
}
