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

    private static var updateCount = 0

    func updateNSView(_ nsView: RioContainerView, context: Context) {
        Self.updateCount += 1

        // 读取 updateTrigger 触发更新
        let _ = coordinator.updateTrigger

        // 读取对话框状态，触发 layout 更新
        let _ = coordinator.showInlineComposer
        let _ = coordinator.composerInputHeight

        // 触发 layout 重新计算（当对话框状态变化时）
        nsView.needsLayout = true

        // 触发 Panel 视图更新
        nsView.updatePanelViews()

        // 只在尺寸变化时触发渲染（避免 updateNSView 过度触发）
        let newSize = nsView.bounds.size
        if newSize != nsView.renderView.lastReportedSize {
            nsView.renderView.lastReportedSize = newSize
            if newSize.width > 0 && newSize.height > 0 {
                nsView.renderView.requestRender()
            }
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

    /// 当前正在高亮的 Panel（用于清除旧高亮）
    private weak var currentHighlightedPanel: DomainPanelView?

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

        // 添加 Active 终端发光层（Metal 层之上，初始不创建 SwiftUI 视图）
        addSubview(activeGlowView)

        // PageBar 已移至 SwiftUI 层（ContentView）

        // 注册拖拽目标（Tab 拖拽）
        registerForDraggedTypes([.string])

        // 监听状态变化，更新 UI
        setupObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        // 优先检查分割线（分割线在 Panel 之间，需要最先响应拖拽）
        for dividerView in dividerViews {
            if dividerView.frame.contains(point) {
                // 直接返回 dividerView，因为分割线没有子视图需要检测
                // 注意：hitTest 需要父视图坐标，不需要转换
                return dividerView
            }
        }

        // 检查 Panel UI 视图（Tab 栏）
        for (_, panelView) in panelUIViews {
            // 检查点是否在这个 Panel 的 frame 内
            if panelView.frame.contains(point) {
                let pointInPanel = convert(point, to: panelView)
                if let hitView = panelView.hitTest(pointInPanel) {
                    return hitView
                }
            }
        }

        // 其他区域返回 renderView（让 Metal 视图处理鼠标事件）
        let pointInRender = convert(point, to: renderView)
        return renderView.hitTest(pointInRender) ?? renderView
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

        // 监听 Active 终端变化（Tab 切换）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeTerminalDidChange),
            name: .activeTerminalDidChange,
            object: nil
        )
    }

    @objc private func activeTerminalDidChange(_ notification: Notification) {
        // Tab 切换时更新 Panel 视图（确保提醒状态等 UI 同步）
        updatePanelViews()
        // Tab 切换时显示发光效果
        showActiveGlow()
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
            self?.activeGlowView.hide()  // 销毁 SwiftUI 视图，停止动画
        }
    }

    /// 立即隐藏发光效果
    private func hideActiveGlow() {
        glowFadeOutTimer?.invalidate()
        glowFadeOutTimer = nil
        activeGlowView.hide()
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

        // 插件页面由 ContentView 层处理，这里只处理终端页面
        if let activePage = coordinator.activePage, activePage.isPluginPage {
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
        // 注意：通过 DropIntentQueue 确保在 drag session 结束后才执行模型变更，
        // 所以这里可以安全地立即删除视图
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

        // 标记需要布局，让系统在下一个 run loop 自然触发
        // 注意：不能调用 layoutSubtreeIfNeeded()，因为可能在 SwiftUI updateNSView 中被调用，
        // 此时系统可能正在布局过程中，会触发递归布局警告
        needsLayout = true
    }

    /// 更新 Active 终端发光视图
    /// - Parameters:
    ///   - panels: 所有 Panel
    ///   - activePanelId: 激活的 Panel ID
    ///   - forceShow: 是否强制显示（窗口获得焦点时为 true）
    private func updateActiveGlow(panels: [EditorPanel], activePanelId: UUID?, forceShow: Bool) {
        // 只有多个 Panel 时才需要显示发光提示
        guard panels.count > 1 else {
            activeGlowView.hide()
            return
        }

        // 找到 active panel
        guard let activePanelId = activePanelId,
              let activePanel = panels.first(where: { $0.panelId == activePanelId }) else {
            activeGlowView.hide()
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
            activeGlowView.show()  // 创建 SwiftUI 视图，启动呼吸动画
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

    // MARK: - Tab Drop Handling

    /// 根据屏幕坐标找到对应的 Panel
    /// - Parameter point: 在 RioContainerView 坐标系中的点
    /// - Returns: 找到的 Panel 和对应的视图，如果没有找到返回 nil
    private func findPanel(at point: NSPoint) -> (panel: EditorPanel, view: DomainPanelView)? {
        for (panelId, view) in panelUIViews {
            if view.frame.contains(point) {
                // 从 coordinator 获取对应的 EditorPanel
                if let panel = coordinator?.terminalWindow.allPanels.first(where: { $0.panelId == panelId }) {
                    return (panel, view)
                }
            }
        }
        return nil
    }

    /// 拖拽数据结构（包含完整信息）
    private struct DragPayload {
        let tabId: UUID
        let sourcePanelId: UUID
        let sourceWindowNumber: Int
    }

    /// 解析拖拽数据（新格式）
    /// - Parameter dataString: 粘贴板字符串，格式 `tab:{windowNumber}:{panelId}:{tabId}`
    /// - Returns: 完整的拖拽数据，失败返回 nil
    private func parseDragPayload(_ dataString: String) -> DragPayload? {
        guard dataString.hasPrefix("tab:") else { return nil }

        let components = dataString.components(separatedBy: ":")
        guard components.count >= 4 else { return nil }

        // 新格式：tab:{windowNumber}:{panelId}:{tabId}
        guard let windowNumber = Int(components[1]),
              let sourcePanelId = UUID(uuidString: components[2]),
              let tabId = UUID(uuidString: components[3]) else {
            return nil
        }

        return DragPayload(tabId: tabId, sourcePanelId: sourcePanelId, sourceWindowNumber: windowNumber)
    }
}

// MARK: - NSDraggingDestination (Tab Drop)

extension RioContainerView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 检查是否是 Tab 拖拽
        guard let dataString = sender.draggingPasteboard.string(forType: .string),
              parseDragPayload(dataString) != nil else {
            return []
        }

        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 检查是否是 Tab 拖拽
        guard let dataString = sender.draggingPasteboard.string(forType: .string),
              parseDragPayload(dataString) != nil else {
            return []
        }

        // 根据鼠标坐标计算目标 Panel
        let location = convert(sender.draggingLocation, from: nil)
        guard let (_, targetView) = findPanel(at: location) else {
            // 没有找到 Panel，清除高亮
            currentHighlightedPanel?.clearHighlight()
            currentHighlightedPanel = nil
            return []
        }

        // 如果切换到新的 Panel，清除旧 Panel 的高亮
        if currentHighlightedPanel !== targetView {
            currentHighlightedPanel?.clearHighlight()
            currentHighlightedPanel = targetView
        }

        // 将坐标转换到 targetView 的坐标系
        let locationInPanel = convert(location, to: targetView)

        // 计算 Drop Zone
        if let dropZone = targetView.calculateDropZone(mousePosition: locationInPanel) {
            targetView.highlightDropZone(dropZone)
            return .move
        } else {
            targetView.clearHighlight()
            return []
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // 清除高亮
        currentHighlightedPanel?.clearHighlight()
        currentHighlightedPanel = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 清除高亮
        currentHighlightedPanel?.clearHighlight()
        currentHighlightedPanel = nil

        // 解析完整的拖拽数据
        guard let dataString = sender.draggingPasteboard.string(forType: .string),
              let payload = parseDragPayload(dataString) else {
            return false
        }

        // 根据鼠标坐标找到目标 Panel
        let location = convert(sender.draggingLocation, from: nil)
        guard let (targetPanel, targetView) = findPanel(at: location) else {
            return false
        }

        // 将坐标转换到 targetView 的坐标系
        let locationInPanel = convert(location, to: targetView)

        // 计算 Drop Zone
        guard let dropZone = targetView.calculateDropZone(mousePosition: locationInPanel) else {
            return false
        }

        // 调用 Coordinator 处理 Drop
        guard let coordinator = coordinator else {
            return false
        }

        return coordinator.handleDrop(
            tabId: payload.tabId,
            sourcePanelId: payload.sourcePanelId,
            dropZone: dropZone,
            targetPanelId: targetPanel.panelId
        )
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


    // MARK: - Render Scheduler（Rust 侧渲染）

    /// Rust 侧的渲染调度器
    ///
    /// 新架构：
    /// - RenderScheduler 绑定到 TerminalPool
    /// - 在 VSync 时自动调用 pool.render_all()
    /// - Swift 只负责同步布局
    private var renderScheduler: RenderSchedulerWrapper?

    /// 渲染请求统计（用于调试）
    private var requestCount: Int = 0
    private let needsRenderLock = NSLock()

    /// 布局缓存（用于检测布局是否变化）
    private var lastLayoutHash: Int = 0

    /// 上次报告的尺寸（用于检测 updateNSView 中尺寸是否变化）
    var lastReportedSize: CGSize = .zero

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
    private weak var selectionTab: Tab?

    // MARK: - 超链接悬停状态

    /// 是否按下 Cmd 键
    private var isCmdKeyDown: Bool = false
    /// 当前悬停的超链接（用于避免重复设置）
    private var currentHoveredHyperlink: TerminalHyperlink?
    /// 当前悬停的终端 ID
    private var currentHoveredTerminalId: Int?
    /// 鼠标追踪区域
    private var trackingArea: NSTrackingArea?

    // MARK: - IME 支持

    /// IME 协调器
    private let imeCoordinator = IMECoordinator()

    /// 需要直接处理的特殊键 keyCode
    private let specialKeyCodes: Set<UInt16> = [
        36,   // Return (主键盘)
        76,   // Enter (小键盘)
        48,   // Tab
        51,   // Delete (Backspace)
        53,   // Escape
        114,  // Insert
        117,  // Forward Delete (Del)
        123,  // Left Arrow
        124,  // Right Arrow
        125,  // Down Arrow
        126,  // Up Arrow
        115,  // Home
        119,  // End
        116,  // Page Up
        121,  // Page Down
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

        // 设置鼠标追踪区域（用于 Cmd+hover 超链接检测）
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        // 移除旧的追踪区域
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        // 创建新的追踪区域
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea

        super.updateTrackingAreas()
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

            // 监听系统唤醒（从睡眠/锁屏恢复）
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(systemDidWake),
                name: NSWorkspace.didWakeNotification,
                object: nil
            )

            // 监听应用激活（从后台切回前台）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )

            // 不管 isKeyWindow 状态，都尝试初始化
            // 使用延迟确保视图布局完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.initialize()
            }
        } else {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
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

            // 2. 通知 Rust 更新 scale（关键！确保字体度量和选区坐标正确）
            terminalPool?.setScale(Float(newScale))

            // 3. 更新 CoordinateMapper
            let mapper = CoordinateMapper(scale: newScale, containerBounds: bounds)
            coordinateMapper = mapper
            coordinator?.setCoordinateMapper(mapper)

            // 4. 触发 layout（确保 resize 被正确调用）
            // 注意：只设置 needsLayout，不调用 layoutSubtreeIfNeeded()
            // 因为此方法可能在系统布局过程中被调用，直接调用会导致递归布局
            needsLayout = true

            // 5. DPI 变化，布局需要重新同步
            onLayoutChanged()
        }
    }

    @objc private func windowDidBecomeKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.initialize()
        }
    }

    /// 系统从睡眠/锁屏唤醒
    @objc private func systemDidWake() {
        logDebug("[RenderLoop] systemDidWake - CVDisplayLink isRunning: \(renderScheduler?.isRunning ?? false)")
        resumeRenderingIfNeeded()
    }

    /// 应用从后台切回前台
    @objc private func applicationDidBecomeActive() {
        logDebug("[RenderLoop] applicationDidBecomeActive - CVDisplayLink isRunning: \(renderScheduler?.isRunning ?? false)")
        resumeRenderingIfNeeded()
    }

    /// 恢复渲染（唤醒后）
    private func resumeRenderingIfNeeded() {
        guard isInitialized else {
            logDebug("[RenderLoop] resumeRenderingIfNeeded - not initialized, skip")
            return
        }

        // 检查 CVDisplayLink 是否在运行
        if let scheduler = renderScheduler, !scheduler.isRunning {
            logWarn("[RenderLoop] CVDisplayLink was stopped, restarting...")
            _ = scheduler.start()
        }

        // 强制同步布局并请求渲染（确保画面更新）
        lastLayoutHash = 0  // 清除缓存，强制同步
        requestRender()
        logDebug("[RenderLoop] resumeRenderingIfNeeded - requested render")
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

            // 3. 布局变化，同步到 Rust 并请求渲染
            onLayoutChanged()
        }
    }

    // MARK: - Sugarloaf Initialization

    private func initializeSugarloaf() {
        guard let window = window else { return }

        // 新架构：创建 TerminalPoolWrapper（多终端管理 + 统一渲染）
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()

        // 优先使用 window 关联的 screen 的 scale，更可靠
        let effectiveScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor

        // TerminalPoolWrapper 初始化

        // 创建 TerminalPoolWrapper
        terminalPool = TerminalPoolWrapper(
            windowHandle: viewPointer,
            displayHandle: viewPointer,
            width: Float(bounds.width),
            height: Float(bounds.height),
            scale: Float(effectiveScale),
            fontSize: 14.0
        )

        guard let pool = terminalPool else { return }

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

        // 设置 IME 回调（同步预编辑状态到 Rust 渲染层）
        imeCoordinator.onPreeditChange = { [weak self, weak pool] text, cursorOffset in
            guard let self = self,
                  let pool = pool,
                  let terminalId = self.coordinator?.getActiveTerminalId() else { return }
            pool.setImePreedit(terminalId: Int(terminalId), text: text, cursorOffset: cursorOffset)
        }

        imeCoordinator.onPreeditClear = { [weak self, weak pool] in
            guard let self = self,
                  let pool = pool,
                  let terminalId = self.coordinator?.getActiveTerminalId() else { return }
            pool.clearImePreedit(terminalId: Int(terminalId))
        }

        // 将 TerminalPool 注册到 Coordinator
        if let coordinator = coordinator {
            coordinator.setTerminalPool(pool)

            // 配置 KeyboardSystem 的 IME 回调（如果存在）
            coordinator.keyboardSystem?.configureImeCallbacks(
                onPreeditChange: { [weak self, weak pool] text, cursorOffset in
                    guard let self = self,
                          let pool = pool,
                          let terminalId = self.coordinator?.getActiveTerminalId() else { return }
                    pool.setImePreedit(terminalId: Int(terminalId), text: text, cursorOffset: cursorOffset)
                },
                onPreeditClear: { [weak self, weak pool] in
                    guard let self = self,
                          let pool = pool,
                          let terminalId = self.coordinator?.getActiveTerminalId() else { return }
                    pool.clearImePreedit(terminalId: Int(terminalId))
                }
            )
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
    ///
    /// 新架构：
    /// - RenderScheduler 绑定到 TerminalPool
    /// - 在 VSync 时自动调用 pool.render_all()
    /// - Swift 只负责同步布局，不参与渲染循环
    private func setupRenderScheduler() {
        guard let pool = terminalPool else { return }

        // 创建 RenderScheduler
        let scheduler = RenderSchedulerWrapper()
        self.renderScheduler = scheduler

        // 绑定到 TerminalPool
        // - 共享 needs_render 标记
        // - 在 VSync 时自动调用 pool.render_all()
        scheduler.bind(to: pool)

        // 启动
        _ = scheduler.start()

        // 初始同步布局
        syncLayoutToRust()
    }

    // MARK: - Layout Sync (New Architecture)

    /// 同步布局到 Rust 侧
    ///
    /// 在布局变化时调用（Tab 切换、窗口 resize 等）
    /// Rust 侧会在下一个 VSync 时使用此布局进行渲染
    private func syncLayoutToRust() {
        guard isInitialized,
              let pool = terminalPool,
              let coordinator = coordinator else { return }

        // 获取所有需要渲染的终端及其位置
        let tabsToRender = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: bounds,
            headerHeight: 30.0
        )

        // 计算布局 hash，判断是否变化
        let currentHash = calculateLayoutHash(tabsToRender)
        if currentHash == lastLayoutHash {
            return  // 布局没变，跳过同步
        }
        lastLayoutHash = currentHash

        // 转换为 Rust 坐标系并设置布局
        let layouts: [(terminalId: Int, x: Float, y: Float, width: Float, height: Float)] = tabsToRender.map { (terminalId, contentBounds) in
            // contentBounds 是 Swift 坐标系（左下角原点）
            // 转换为 Rust 坐标系（左上角原点）
            let x = Float(contentBounds.origin.x)
            let y = Float(bounds.height - contentBounds.origin.y - contentBounds.height)
            let width = Float(contentBounds.width)
            let height = Float(contentBounds.height)
            return (terminalId: terminalId, x: x, y: y, width: width, height: height)
        }

        pool.setRenderLayout(layouts, containerHeight: Float(bounds.height))
    }

    /// 计算布局的 hash 值
    ///
    /// 用于检测布局是否发生变化，避免不必要的 FFI 调用
    private func calculateLayoutHash(_ tabs: [(Int, CGRect)]) -> Int {
        var hasher = Hasher()
        for (id, rect) in tabs {
            hasher.combine(id)
            // 乘以 100 转换为整数，避免浮点数精度问题
            hasher.combine(Int(rect.origin.x * 100))
            hasher.combine(Int(rect.origin.y * 100))
            hasher.combine(Int(rect.width * 100))
            hasher.combine(Int(rect.height * 100))
        }
        return hasher.finalize()
    }

    // MARK: - RenderViewProtocol

    /// 请求渲染（内容变化）
    ///
    /// 新架构下：
    /// - 同步布局到 Rust（有 hash 缓存，无变化时跳过）
    /// - 标记 needs_render
    /// - Rust 侧在下一个 VSync 时自动渲染
    func requestRender() {
        guard isInitialized else { return }

        // 同步布局（有 hash 缓存优化，无变化时自动跳过）
        syncLayoutToRust()

        // 通知 Rust 侧需要渲染
        renderScheduler?.requestRender()

        // 更新统计
        needsRenderLock.lock()
        requestCount += 1
        needsRenderLock.unlock()
    }

    /// 布局变化通知
    ///
    /// 在布局可能变化的场景调用（Tab 切换、窗口 resize、DPI 变化等）
    private func onLayoutChanged() {
        syncLayoutToRust()
        requestRender()
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


    // render() 已移除 - 新架构下渲染完全在 Rust 侧完成
    // Swift 只负责通过 syncLayoutToRust() 同步布局

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
    ///
    /// 注意：大部分快捷键由 KeyableWindow.performKeyEquivalent 在 Window 级别处理
    /// 这里只处理终端特有的情况（如果有的话）
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 快捷键已经在 Window 级别由 KeyableWindow 处理
        // 这里直接返回 false，让事件继续传递
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

        // IME 预编辑状态检查：如果正在输入中文，交给系统处理（包括 Backspace）
        let imeCoord = coordinator?.keyboardSystem?.imeCoordinator ?? imeCoordinator
        if imeCoord.isComposing {
            interpretKeyEvents([event])
            return
        }

        // 1. 首先检查自定义 keybinding（如 Shift+Enter）
        // 这允许用户配置特定按键组合发送自定义终端序列
        let keybindingManager = TerminalKeybindingManager.shared
        if let customSequence = keybindingManager.findSequence(
            keyCode: keyStroke.keyCode,
            modifiers: keyStroke.modifiers
        ) {
            _ = pool.writeInput(terminalId: Int(terminalId), data: customSequence)
            return
        }

        // 2. 转换为终端序列并发送到当前激活终端
        // 不主动触发渲染，依赖 Wakeup 事件（终端有输出时自动触发）
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
                // 根据终端是否启用 Bracketed Paste Mode 决定是否包裹转义序列
                if pool.isBracketedPasteEnabled(terminalId: Int(terminalId)) {
                    let bracketedText = "\u{1B}[200~" + text + "\u{1B}[201~"
                    _ = pool.writeInput(terminalId: Int(terminalId), data: bracketedText)
                } else {
                    _ = pool.writeInput(terminalId: Int(terminalId), data: text)
                }
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
        // 检测 Cmd 键状态变化
        let cmdPressed = event.modifierFlags.contains(.command)

        if cmdPressed != isCmdKeyDown {
            isCmdKeyDown = cmdPressed

            if cmdPressed {
                // Cmd 按下：检测当前鼠标位置的超链接
                if let window = window {
                    let mouseLocation = window.mouseLocationOutsideOfEventStream
                    let location = convert(mouseLocation, from: nil)
                    checkHyperlinkAtLocation(location)
                }
            } else {
                // Cmd 释放：清除超链接悬停状态
                clearHyperlinkHover()
            }
        }
    }

    // MARK: - 超链接悬停处理

    /// 检测指定位置的超链接
    private func checkHyperlinkAtLocation(_ location: CGPoint) {
        guard isCmdKeyDown,
              let coordinator = coordinator,
              let pool = terminalPool else {
            clearHyperlinkHover()
            return
        }

        // 找到对应的 Panel
        guard let panelId = coordinator.findPanel(at: location, containerBounds: bounds),
              let panel = coordinator.terminalWindow.getPanel(panelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId else {
            clearHyperlinkHover()
            return
        }

        // 转换为网格坐标
        let gridPos = screenToGrid(location: location, panelId: panelId)

        // 查询超链接
        if let hyperlink = pool.getHyperlinkAt(
            terminalId: Int(terminalId),
            screenRow: Int(gridPos.row),
            screenCol: Int(gridPos.col)
        ) {
            // 检查是否与当前悬停的超链接相同（避免重复设置）
            if let current = currentHoveredHyperlink,
               current.uri == hyperlink.uri,
               current.startRow == hyperlink.startRow,
               current.startCol == hyperlink.startCol,
               currentHoveredTerminalId == Int(terminalId) {
                return  // 相同，无需更新
            }

            // 清除旧的悬停状态
            if let oldTerminalId = currentHoveredTerminalId {
                pool.clearHyperlinkHover(terminalId: oldTerminalId)
            }

            // 设置新的悬停状态
            pool.setHyperlinkHover(terminalId: Int(terminalId), hyperlink: hyperlink)
            currentHoveredHyperlink = hyperlink
            currentHoveredTerminalId = Int(terminalId)

            // 切换鼠标指针为手型
            NSCursor.pointingHand.set()

            // 触发重新渲染
            requestRender()
        } else {
            // 无超链接，清除悬停状态
            clearHyperlinkHover()
        }
    }

    /// 清除超链接悬停状态
    private func clearHyperlinkHover() {
        guard let pool = terminalPool else { return }

        // 清除 Rust 侧悬停状态
        if let terminalId = currentHoveredTerminalId {
            pool.clearHyperlinkHover(terminalId: terminalId)
        }

        // 清除本地状态
        let hadHyperlink = currentHoveredHyperlink != nil
        currentHoveredHyperlink = nil
        currentHoveredTerminalId = nil

        // 恢复鼠标指针
        NSCursor.arrow.set()

        // 如果之前有高亮，触发重新渲染
        if hadHyperlink {
            requestRender()
        }
    }

    /// 打开超链接
    private func openHyperlink(_ uri: String) {
        guard let url = URL(string: uri) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    override func mouseMoved(with event: NSEvent) {
        // 只有 Cmd 按下时才检测超链接
        guard isCmdKeyDown else {
            super.mouseMoved(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        checkHyperlinkAtLocation(location)
    }

    override func mouseExited(with event: NSEvent) {
        // 鼠标离开视图时清除超链接悬停
        clearHyperlinkHover()
        super.mouseExited(with: event)
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

        // Cmd+click：打开超链接（OSC 8 或自动检测的 URL）
        if event.modifierFlags.contains(.command) {
            // 优先检查 OSC 8 超链接
            if let hyperlink = currentHoveredHyperlink {
                openHyperlink(hyperlink.uri)
                clearHyperlinkHover()
                return
            }

            // 检查自动检测的 URL
            if let coordinator = coordinator,
               let panelId = coordinator.findPanel(at: location, containerBounds: bounds),
               let panel = coordinator.terminalWindow.getPanel(panelId),
               let activeTab = panel.activeTab,
               let terminalId = activeTab.rustTerminalId,
               let pool = terminalPool {
                let gridPos = screenToGrid(location: location, panelId: panelId)
                if let url = pool.getUrlAt(
                    terminalId: Int(terminalId),
                    screenRow: Int(gridPos.row),
                    screenCol: Int(gridPos.col)
                ) {
                    openHyperlink(url.uri)
                    return
                }
            }
        }

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
        activeTab: Tab,
        terminalId: Int,
        panelId: UUID,
        event: NSEvent
    ) {
        // 新架构：使用 terminalPool
        guard let pool = terminalPool else { return }

        let row = Int(gridPos.row)
        let col = Int(gridPos.col)

        // 直接调用 Rust API 获取单词边界（支持中文分词）
        guard let boundary = pool.getWordAt(
            terminalId: terminalId,
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
                terminalId: terminalId,
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

        // 清除超链接状态
        currentHoveredHyperlink = nil
        currentHoveredTerminalId = nil
        isCmdKeyDown = false

        // 清理 TerminalPoolWrapper
        terminalPool = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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

        // 计算光标偏移（grapheme cluster 索引）
        // selectedRange.location 是 UTF-16 码元偏移，需要转换为 grapheme 索引
        let cursorOffset: UInt32
        if selectedRange.location != NSNotFound && selectedRange.location <= text.utf16.count {
            let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: selectedRange.location)
            if let stringIndex = utf16Index.samePosition(in: text) {
                // 计算 grapheme cluster 索引
                let graphemeCount = text.distance(from: text.startIndex, to: stringIndex)
                cursorOffset = UInt32(graphemeCount)
            } else {
                cursorOffset = 0
            }
        } else {
            cursorOffset = 0
        }

        // 如果有 KeyboardSystem，使用它的 IME 协调器
        if let keyboardSystem = coordinator?.keyboardSystem {
            keyboardSystem.imeCoordinator.setMarkedText(text, cursorOffset: cursorOffset)
        } else {
            imeCoordinator.setMarkedText(text, cursorOffset: cursorOffset)
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
        guard let window = window,
              let coordinator = coordinator,
              let pool = terminalPool,
              let mapper = coordinateMapper else {
            return window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        }

        // 获取当前 active terminal 和光标位置
        guard let terminalId = coordinator.getActiveTerminalId(),
              let cursor = pool.getCursorPosition(terminalId: Int(terminalId)) else {
            return window.convertToScreen(convert(bounds, to: nil))
        }

        // 从 fontMetrics 获取实际的 cell 尺寸（逻辑点）
        let logicalCellWidth: CGFloat
        let logicalCellHeight: CGFloat
        if let metrics = pool.getFontMetrics() {
            logicalCellWidth = CGFloat(metrics.cell_width) / mapper.scale
            logicalCellHeight = CGFloat(metrics.line_height) / mapper.scale
        } else {
            logicalCellWidth = 9.6
            logicalCellHeight = 20.0
        }

        // 获取当前 active panel 的 content bounds（考虑 Panel 偏移）
        let tabsToRender = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: bounds,
            headerHeight: 30.0
        )

        // 查找当前终端对应的 content bounds
        let panelOrigin: CGPoint
        let panelHeight: CGFloat
        if let contentBounds = tabsToRender.first(where: { $0.0 == terminalId })?.1 {
            panelOrigin = contentBounds.origin
            panelHeight = contentBounds.height
        } else {
            // fallback: 使用整个 bounds
            panelOrigin = bounds.origin
            panelHeight = bounds.height
        }

        // 计算光标在屏幕上的位置（考虑 Panel 偏移）
        let x = panelOrigin.x + CGFloat(cursor.col) * logicalCellWidth
        let y = panelOrigin.y + panelHeight - CGFloat(cursor.row + 1) * logicalCellHeight

        let rect = CGRect(x: x, y: y, width: logicalCellWidth, height: logicalCellHeight)
        return window.convertToScreen(convert(rect, to: nil))
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

        // 发送键盘输入到当前激活的终端
        // 不主动触发渲染，依赖 Wakeup 事件（终端有输出时自动触发）
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
        // 使用 GeometryReader 获取当前激活 Panel 的位置
        GeometryReader { geometry in
            // 计算激活 Panel 的 bounds（用于定位搜索框）
            let activePanelFrame = getActivePanelFrame(in: geometry)

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
            .position(
                x: activePanelFrame.maxX - 150,  // 距离右边缘 150pt（搜索框宽度约 300pt）
                y: activePanelFrame.minY + 40     // 距离顶部 40pt
            )
        }
        .onChange(of: coordinator.searchPanelId) {
            // 搜索目标 Panel 切换时，更新搜索框内容
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

    /// 获取搜索目标 Panel 的 frame（转换为 SwiftUI 坐标系）
    private func getActivePanelFrame(in geometry: GeometryProxy) -> CGRect {
        // 使用 searchPanelId 定位搜索框（搜索绑定到特定 Panel）
        guard let searchPanelId = coordinator.searchPanelId else {
            return geometry.frame(in: .local)
        }

        // 从 coordinator 获取 Panel 的 bounds
        let panels = coordinator.terminalWindow.allPanels
        guard let activePanel = panels.first(where: { $0.panelId == searchPanelId }) else {
            return geometry.frame(in: .local)
        }

        // Panel bounds 使用 AppKit 坐标系（左下角原点，Y 轴向上）
        // 需要转换为 SwiftUI 坐标系（左上角原点，Y 轴向下）
        let appKitBounds = activePanel.bounds
        let containerHeight = geometry.size.height

        // 坐标转换公式：
        // SwiftUI.minY = containerHeight - AppKit.maxY
        // SwiftUI.maxY = containerHeight - AppKit.minY
        let swiftUIFrame = CGRect(
            x: appKitBounds.minX,
            y: containerHeight - appKitBounds.maxY,  // 转换 Y 坐标
            width: appKitBounds.width,
            height: appKitBounds.height
        )

        return swiftUIFrame
    }
}
