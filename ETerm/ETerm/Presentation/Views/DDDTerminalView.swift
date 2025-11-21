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
    /// Metal 渲染层（在底部）
    let renderView: DDDPanelRenderView

    /// Panel UI 视图列表（在上面）
    private var panelUIViews: [UUID: DomainPanelView] = [:]

    weak var coordinator: TerminalWindowCoordinator? {
        didSet {
            renderView.coordinator = coordinator
        }
    }

    override init(frame frameRect: NSRect) {
        renderView = DDDPanelRenderView()
        super.init(frame: frameRect)

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

    override func layout() {
        super.layout()

        // Metal 层填满整个容器
        renderView.frame = bounds

        // 更新 Panel UI 视图
        updatePanelViews()
    }

    @objc func updatePanelViews() {
        print("[DDDContainerView] 🔄 updatePanelViews called")
        print("[DDDContainerView] 📏 DDDContainerView.bounds = \(bounds)")
        guard let coordinator = coordinator else {
            print("[DDDContainerView] ❌ coordinator is nil")
            return
        }

        // 🎯 关键：先触发 bounds 更新
        let _ = coordinator.terminalWindow.getActiveTabsForRendering(
            containerBounds: bounds,
            headerHeight: 30.0
        )

        let panels = coordinator.terminalWindow.allPanels
        print("[DDDContainerView] 📊 Found \(panels.count) panels")
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
                print("[DDDContainerView] 创建 PanelView: \(panel.panelId.uuidString.prefix(8))")
                print("  Panel bounds: \(panel.bounds)")
                let view = DomainPanelView(panel: panel, coordinator: coordinator)
                view.frame = panel.bounds
                print("  View frame: \(view.frame)")
                print("  View added to superview: \(view.superview != nil)")
                addSubview(view)
                print("  After addSubview - superview: \(view.superview != nil)")
                panelUIViews[panel.panelId] = view
            }
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
            print("[DDDPanelRenderView] ❌ Failed to create SugarloafWrapper")
            return
        }

        self.sugarloaf = sugarloaf
        print("[DDDPanelRenderView] ✅ Sugarloaf initialized")

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

        print("[DDDPanelRenderView] ✅ Initialization complete")

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
            print("[PTY Reader] ✅ Background read loop started")

            while !self.shouldStopReading {
                terminalPool?.readAllOutputs()
                usleep(1000)
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
        print("[CVDisplayLink] ✅ Started")
    }

    func requestRender() {
        renderLock.lock()
        needsRender = true
        renderLock.unlock()
    }

    private func performRender() {
        print("[DDDPanelRenderView] 📏 DDDPanelRenderView.bounds = \(bounds)")

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

        // 根据位置找到对应的 Panel
        if let coordinator = coordinator,
           let panelId = coordinator.findPanel(at: location, containerBounds: bounds) {
            // 设置激活的 Panel
            coordinator.setActivePanel(panelId)
        }

        super.mouseDown(with: event)
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
