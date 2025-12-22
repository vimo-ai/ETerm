//
//  PageBarView.swift
//  ETerm
//
//  Page 栏视图 - SwiftUI 版本
//
//  横向排列：红绿灯 + Page 标签 + 添加按钮
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 常量

/// PageBar 高度
private let kPageBarHeight: CGFloat = 28

// MARK: - Page 数据模型

struct PageItem: Identifiable, Equatable {
    let id: UUID
    var title: String
}

// MARK: - Page 拖拽数据

/// Page 拖拽数据（用于同窗口和跨窗口拖拽）
struct PageDragData: Codable, Transferable {
    let windowNumber: Int
    let pageId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plainText)
    }
}

// MARK: - 红绿灯按钮

struct TrafficLightButtons: View {
    @State private var isHovering = false
    @State private var isWindowActive = true

    private let buttonSize: CGFloat = 12
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            TrafficLightButton(type: .close, isHovering: isHovering, isActive: isWindowActive)
            TrafficLightButton(type: .minimize, isHovering: isHovering, isActive: isWindowActive)
            TrafficLightButton(type: .zoom, isHovering: isHovering, isActive: isWindowActive)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == NSApplication.shared.keyWindow {
                isWindowActive = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            isWindowActive = false
        }
    }
}

struct TrafficLightButton: View {
    enum ButtonType {
        case close, minimize, zoom

        var color: Color {
            switch self {
            case .close: return Color(red: 0.996, green: 0.373, blue: 0.396)
            case .minimize: return Color(red: 0.992, green: 0.761, blue: 0.235)
            case .zoom: return Color(red: 0.161, green: 0.808, blue: 0.357)
            }
        }

        var iconName: String {
            switch self {
            case .close: return "xmark"
            case .minimize: return "minus"
            case .zoom: return "arrow.up.left.and.arrow.down.right"
            }
        }
    }

    let type: ButtonType
    let isHovering: Bool
    let isActive: Bool

    private let size: CGFloat = 12

    var body: some View {
        Button(action: performAction) {
            ZStack {
                Circle()
                    .fill(isActive ? type.color : Color.gray.opacity(0.5))
                    .frame(width: size, height: size)

                if isHovering && isActive {
                    Image(systemName: type.iconName)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func performAction() {
        guard let window = NSApplication.shared.keyWindow else { return }
        switch type {
        case .close: window.close()
        case .minimize: window.miniaturize(nil)
        case .zoom: window.zoom(nil)
        }
    }
}

// MARK: - Status Tab

struct StatusTabView: View {
    let text: String
    let isActive: Bool
    var onTap: (() -> Void)?

    var body: some View {
        // 使用 Button 而非 onTapGesture，确保被 hitTest 识别为 NSControl
        Button(action: { onTap?() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text(text)
                    .font(.caption)
                    .foregroundColor(isActive ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.green.opacity(0.15) : Color.gray.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 穿透容器（只响应子视图区域的点击）

private class PassthroughContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查所有子视图
        for subview in subviews.reversed() {
            let convertedPoint = convert(point, to: subview)
            if let hitView = subview.hitTest(convertedPoint) {
                return hitView
            }
        }
        // 没有子视图响应，返回 nil 让点击穿透
        return nil
    }
}

// MARK: - NSHostingView 忽略 Safe Area

/// 自定义 NSHostingView 子类，覆盖 safeAreaInsets 和 safeAreaRect
/// 解决 macOS SwiftUI 中 titlebar safe area 无法被 ignoresSafeArea() 忽略的问题
/// 同时禁止窗口拖动，让子视图可以正确处理拖拽事件
/// 参考: https://ardentswift.com/posts/macos-hide-toolbar/
final class NSHostingViewIgnoringSafeArea<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var safeAreaRect: NSRect {
        bounds
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

// MARK: - AppKit Bridge（供 RioContainerView 使用）

/// AppKit 桥接类，用于在 NSView 层级中使用 SwiftUI PageBarView
final class PageBarHostingView: NSView {
    private var hostingView: NSView?  // NSHostingView with wrapped view

    // 数据状态
    private var pages: [PageItem] = []
    private var activePageId: UUID?

    /// Page 模型注册表（用于传递给 PageItemView）
    private var pageRegistry: [UUID: Page] = [:]

    // Page 标签容器（使用穿透容器）
    private let pageContainer = PassthroughContainerView()
    private var pageItemViews: [PageItemView] = []

    // 拖拽相关
    private var draggingPageId: UUID?

    // 回调
    var onPageClick: ((UUID) -> Void)?
    var onPageClose: ((UUID) -> Void)?
    var onPageRename: ((UUID, String) -> Void)?
    var onAddPage: (() -> Void)?
    var onPageReorder: (([UUID]) -> Void)?
    var onPageDragOutOfWindow: ((UUID, NSPoint) -> Void)?
    var onPageReceivedFromOtherWindow: ((UUID, Int) -> Void)?  // pageId, sourceWindowNumber

    // 批量关闭回调
    var onPageCloseOthers: ((UUID) -> Void)?
    var onPageCloseLeft: ((UUID) -> Void)?
    var onPageCloseRight: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
        setupPageContainer()
        setupDragDestination()
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageNeedsAttention(_:)),
            name: NSNotification.Name("PageNeedsAttention"),
            object: nil
        )
    }

    @objc private func handlePageNeedsAttention(_ notification: Notification) {
        // PageItemView 现在从 Page 模型读取 effectiveDecoration，并自己处理通知
        // 这里仅作为备份刷新机制，确保 PageItemView 在没有收到通知时也能更新
        guard let userInfo = notification.userInfo,
              let pageId = userInfo["pageId"] as? UUID else {
            return
        }

        // 找到对应的 PageItemView 并触发刷新
        for pageView in pageItemViews where pageView.pageId == pageId {
            pageView.updateItemView()
            break
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        // 只使用 SwiftUI 渲染添加按钮等控件，Page 标签用 AppKit
        // 使用闭包捕获 self，确保能访问到后续设置的 onAddPage
        let controlsView = PageBarControlsView(onAddPage: { [weak self] in
            self?.onAddPage?()
        })
        // 使用自定义 NSHostingView 子类，覆盖 safeAreaInsets 确保贴顶
        let hosting = NSHostingViewIgnoringSafeArea(rootView: controlsView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hosting)
        hostingView = hosting
    }

    private func setupPageContainer() {
        pageContainer.wantsLayer = true
        addSubview(pageContainer)
    }

    private func setupDragDestination() {
        registerForDraggedTypes([.string])
    }

    private func rebuildPageItemViews() {
        // 移除旧的 Page 视图
        pageItemViews.forEach { $0.removeFromSuperview() }
        pageItemViews.removeAll()

        let pageCount = pages.count

        // 创建新的 Page 视图
        for (index, page) in pages.enumerated() {
            // 从 registry 获取 Page 模型引用
            let pageModel = pageRegistry[page.id]
            let pageView = PageItemView(pageId: page.id, title: page.title, page: pageModel)
            pageView.setActive(page.id == activePageId)
            pageView.setShowCloseButton(pageCount > 1)

            // 捕获 pageId 而不是 page，避免闭包捕获问题
            let pageId = page.id
            pageView.onTap = { [weak self] in
                // 装饰清除由插件通过 tabDidFocus 通知处理，核心层不直接清除
                self?.onPageClick?(pageId)
            }

            pageView.onClose = { [weak self] in
                self?.onPageClose?(pageId)
            }

            pageView.onRename = { [weak self] newTitle in
                self?.onPageRename?(pageId, newTitle)
            }

            pageView.onDragStart = { [weak self] in
                self?.draggingPageId = pageId
            }

            pageView.onDragOutOfWindow = { [weak self] screenPoint in
                self?.onPageDragOutOfWindow?(pageId, screenPoint)
            }

            // 批量关闭回调
            pageView.onCloseOthers = { [weak self] in
                self?.onPageCloseOthers?(pageId)
            }
            pageView.onCloseLeft = { [weak self] in
                self?.onPageCloseLeft?(pageId)
            }
            pageView.onCloseRight = { [weak self] in
                self?.onPageCloseRight?(pageId)
            }

            // 设置可关闭状态（基于位置）
            pageView.canCloseLeft = index > 0
            pageView.canCloseRight = index < pageCount - 1
            pageView.canCloseOthers = pageCount > 1

            pageContainer.addSubview(pageView)
            pageItemViews.append(pageView)
        }

        layoutPageItems()
    }

    private func layoutPageItems() {
        let leftPadding: CGFloat = 88  // 红绿灯按钮宽度 + 间距
        let spacing: CGFloat = 2
        var x: CGFloat = leftPadding

        for pageView in pageItemViews {
            let size = pageView.fittingSize
            pageView.frame = CGRect(x: x, y: 3, width: size.width, height: size.height)
            x += size.width + spacing
        }
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
        // pageContainer 占满整个区域，但通过 hitTest 让点击穿透到下层
        pageContainer.frame = bounds
        layoutPageItems()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        // 优先检查 pageContainer 中的 PageItemView
        let pointInPageContainer = convert(point, to: pageContainer)
        for pageView in pageItemViews {
            let pointInPage = pageContainer.convert(pointInPageContainer, to: pageView)
            if pageView.bounds.contains(pointInPage) {
                if let hitView = pageView.hitTest(pointInPage) {
                    return hitView
                }
                return pageView
            }
        }

        // 检查是否在右侧按钮区域（PageItemView 右边的区域）
        // 计算 PageItemView 区域的右边界
        let leftPadding: CGFloat = 88
        let spacing: CGFloat = 2
        var pageAreaRightEdge = leftPadding
        for pageView in pageItemViews {
            pageAreaRightEdge += pageView.fittingSize.width + spacing
        }

        // 如果点击位置在 PageItemView 区域右侧，让 SwiftUI hostingView 处理
        if point.x > pageAreaRightEdge, let hosting = hostingView {
            return hosting
        }

        // 其他区域（PageItemView 左侧空白和间隙）返回自己，用于窗口拖动
        return self
    }

    /// 设置 Page 列表（只在数据变化时重建）
    ///
    /// - Parameters:
    ///   - newPages: Page 信息元组数组
    ///   - pageModels: Page 模型数组（可选，用于传递给 PageItemView 以读取 effectiveDecoration）
    func setPages(_ newPages: [(id: UUID, title: String)], pageModels: [Page] = []) {
        // 更新 registry
        pageRegistry.removeAll()
        for page in pageModels {
            pageRegistry[page.pageId] = page
        }

        let newPageItems = newPages.map { PageItem(id: $0.id, title: $0.title) }

        // 检查是否需要重建（ID 列表或标题变化）
        let needsRebuild = pages.count != newPageItems.count ||
            zip(pages, newPageItems).contains { $0.id != $1.id || $0.title != $1.title }

        if needsRebuild {
            pages = newPageItems
            rebuildPageItemViews()
        }
    }

    /// 设置激活的 Page
    func setActivePage(_ pageId: UUID) {
        activePageId = pageId
        // 更新激活状态（装饰清除由插件通过 tabDidFocus 通知处理）
        for pageView in pageItemViews {
            let isActive = pageView.pageId == pageId
            pageView.setActive(isActive)
        }
    }

    /// 推荐高度
    static func recommendedHeight() -> CGFloat {
        return kPageBarHeight
    }

    // MARK: - 窗口拖动

    override var mouseDownCanMoveWindow: Bool {
        // 禁用自动窗口拖动，手动控制
        return false
    }

    override func mouseDown(with event: NSEvent) {
        // 只在空白区域（非 PageItemView）启动窗口拖动
        let point = convert(event.locationInWindow, from: nil)

        // 检查是否点击在 PageItemView 上
        let pointInPageContainer = convert(point, to: pageContainer)
        for pageView in pageItemViews {
            let pointInPage = pageContainer.convert(pointInPageContainer, to: pageView)
            if pageView.bounds.contains(pointInPage) {
                // 点击在 Page 标签上，不拖动窗口
                return
            }
        }

        // 点击在空白区域，启动窗口拖动
        window?.performDrag(with: event)
    }
}

// MARK: - NSDraggingDestination

extension PageBarHostingView {
    /// 解析拖拽数据
    /// 格式：page:{windowNumber}:{pageId}
    private func parseDragData(_ pasteboardString: String) -> (windowNumber: Int, pageId: UUID)? {
        guard pasteboardString.hasPrefix("page:") else { return nil }

        let components = pasteboardString.components(separatedBy: ":")
        guard components.count == 3,
              let windowNumber = Int(components[1]),
              let pageId = UUID(uuidString: components[2]) else {
            return nil
        }
        return (windowNumber, pageId)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 检查是否是 Page 拖拽
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              parseDragData(pasteboardString) != nil else {
            return []
        }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              parseDragData(pasteboardString) != nil else {
            return []
        }

        // 计算鼠标位置并高亮插入位置（可选，暂时省略）
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              let dragData = parseDragData(pasteboardString) else {
            return false
        }

        let sourceWindowNumber = dragData.windowNumber
        let pageId = dragData.pageId
        let currentWindowNumber = window?.windowNumber ?? 0

        // 检查是否是跨窗口拖拽
        if sourceWindowNumber != currentWindowNumber {
            // 跨窗口移动
            onPageReceivedFromOtherWindow?(pageId, sourceWindowNumber)
            return true
        }

        // 同窗口内重排序
        guard let draggingId = draggingPageId else {
            return false
        }

        // 计算插入位置
        let location = convert(sender.draggingLocation, from: nil)
        guard let targetIndex = indexForInsertionAt(location: location) else {
            return false
        }

        // 获取当前拖拽的 Page 索引
        guard let sourceIndex = pages.firstIndex(where: { $0.id == draggingId }) else {
            return false
        }

        // 如果位置相同，不处理
        if sourceIndex == targetIndex || sourceIndex + 1 == targetIndex {
            return false
        }

        // 重新排列
        var newPages = pages
        let movedPage = newPages.remove(at: sourceIndex)
        let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        newPages.insert(movedPage, at: insertIndex)

        pages = newPages
        rebuildPageItemViews()

        // 通知外部重排序
        let pageIds = pages.map { $0.id }
        onPageReorder?(pageIds)

        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        draggingPageId = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        draggingPageId = nil
    }

    /// 根据位置计算插入索引
    private func indexForInsertionAt(location: NSPoint) -> Int? {
        let leftPadding: CGFloat = 88
        let spacing: CGFloat = 2

        if location.x < leftPadding {
            return 0
        }

        var x: CGFloat = leftPadding
        for (index, pageView) in pageItemViews.enumerated() {
            let midpoint = x + pageView.fittingSize.width / 2
            if location.x < midpoint {
                return index
            }
            x += pageView.fittingSize.width + spacing
        }

        return pageItemViews.count
    }
}

// MARK: - PageBarControlsView (SwiftUI)

/// 只包含红绿灯和添加按钮的控制栏
struct PageBarControlsView: View {
    @ObservedObject private var translationMode = TranslationModeStore.shared
    @ObservedObject private var pageBarItems = PageBarItemRegistry.shared
    var onAddPage: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // 系统红绿灯预留空间（系统窗口 .titled 样式自带原生红绿灯）
            Spacer().frame(width: 78)

            Spacer()

            // 添加按钮
            Button(action: { onAddPage?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            // 侧边栏按钮（原设置按钮）
            Button(action: {
                // 发送通知打开侧边栏
                NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
            }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            // 插件注册的 PageBar 组件
            ForEach(pageBarItems.items) { item in
                item.viewProvider()
                    .padding(.trailing, 6)
            }

            StatusTabView(
                text: translationMode.statusText,
                isActive: translationMode.isEnabled,
                onTap: { translationMode.toggle() }
            )
            .padding(.trailing, 12)
        }
        .frame(height: kPageBarHeight)
    }
}

// MARK: - AppKitPageBar (NSViewRepresentable)

/// SwiftUI 包装器，使用 AppKit 的 PageBarHostingView 实现 Page 拖拽排序
/// 解决 SwiftUI .onDrag 与 titlebar 窗口拖动的事件竞争问题
struct AppKitPageBar: NSViewRepresentable {
    @ObservedObject var coordinator: TerminalWindowCoordinator

    func makeNSView(context: Context) -> PageBarHostingView {
        let pageBarView = PageBarHostingView(frame: .zero)

        // 设置回调
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
            coordinator?.reorderPages(pageIds)
        }

        pageBarView.onPageDragOutOfWindow = { [weak coordinator] pageId, screenPoint in
            coordinator?.handlePageDragOutOfWindow(pageId, at: screenPoint)
        }

        pageBarView.onPageReceivedFromOtherWindow = { [weak coordinator, weak pageBarView] pageId, sourceWindowNumber in
            let targetWindowNumber = pageBarView?.window?.windowNumber ?? 0
            coordinator?.handlePageReceivedFromOtherWindow(pageId, sourceWindowNumber: sourceWindowNumber, targetWindowNumber: targetWindowNumber, insertBefore: nil)
        }

        // 批量关闭回调
        pageBarView.onPageCloseOthers = { [weak coordinator] pageId in
            coordinator?.handlePageCloseOthers(keepPageId: pageId)
        }
        pageBarView.onPageCloseLeft = { [weak coordinator] pageId in
            coordinator?.handlePageCloseLeft(fromPageId: pageId)
        }
        pageBarView.onPageCloseRight = { [weak coordinator] pageId in
            coordinator?.handlePageCloseRight(fromPageId: pageId)
        }

        // 初始设置 Pages
        updatePages(pageBarView)

        return pageBarView
    }

    func updateNSView(_ nsView: PageBarHostingView, context: Context) {
        updatePages(nsView)
    }

    private func updatePages(_ pageBarView: PageBarHostingView) {
        // 从 coordinator 获取 Pages 数据
        let pageModels = coordinator.terminalWindow.pages.all
        let pages = pageModels.map { page in
            (id: page.pageId, title: page.title)
        }
        // 传递 Page 模型，用于 PageItemView 读取 effectiveDecoration
        pageBarView.setPages(pages, pageModels: pageModels)

        // 设置激活的 Page
        if let activePageId = coordinator.terminalWindow.active.pageId {
            pageBarView.setActivePage(activePageId)
        }
    }
}

// MARK: - Preview

#Preview("TrafficLightButtons") {
    TrafficLightButtons()
        .padding(20)
        .background(Color.black.opacity(0.8))
}
