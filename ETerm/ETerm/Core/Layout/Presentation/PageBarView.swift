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

// MARK: - PageBarView (SwiftUI)

struct PageBarView: View {
    // MARK: - 数据

    @Binding var pages: [PageItem]
    @Binding var activePageId: UUID?
    @ObservedObject private var translationMode = TranslationModeStore.shared
    @State private var editingPageId: UUID?

    // MARK: - 回调

    var onPageClick: ((UUID) -> Void)?
    var onPageClose: ((UUID) -> Void)?
    var onPageRename: ((UUID, String) -> Void)?
    var onAddPage: (() -> Void)?

    // MARK: - 常量

    private static let barHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            // 红绿灯按钮
            TrafficLightButtons()
                .padding(.leading, 12)

            Spacer().frame(width: 12)

            // Page 标签列表
            HStack(spacing: 2) {
                ForEach(pages) { page in
                    PageTabView(
                        title: page.title,
                        isActive: page.id == activePageId,
                        showCloseButton: pages.count > 1,
                        isEditing: Binding(
                            get: { editingPageId == page.id },
                            set: { if $0 { editingPageId = page.id } else { editingPageId = nil } }
                        ),
                        onTap: { onPageClick?(page.id) },
                        onClose: { onPageClose?(page.id) },
                        onRename: { newTitle in onPageRename?(page.id, newTitle) }
                    )
                }
            }

            Spacer()

            // 添加按钮
            Button(action: { onAddPage?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            StatusTabView(
                text: translationMode.statusText,
                isActive: translationMode.isEnabled,
                onTap: { translationMode.toggle() }
            )
            .padding(.trailing, 12)
        }
        .frame(height: Self.barHeight)
    }

    // MARK: - 推荐高度

    static func recommendedHeight() -> CGFloat {
        return barHeight
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

// MARK: - Page 标签（使用简约圆角风格）

struct PageTabView: View {
    let title: String
    let isActive: Bool
    let showCloseButton: Bool
    var needsAttention: Bool = false
    @Binding var isEditing: Bool
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?

    @State private var isHovered: Bool = false
    @State private var editingText: String = ""
    @FocusState private var isFocused: Bool
    @State private var lastTapTime: Date = .distantPast
    private let height: CGFloat = 22
    private let doubleTapInterval: TimeInterval = 0.3

    var body: some View {
        if isEditing {
            // 编辑模式：显示 TextField
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.1))
                )
                .focused($isFocused)
                .onAppear {
                    editingText = title
                    // 延迟获取焦点
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isFocused = true
                    }
                }
                .onSubmit {
                    finishEditing()
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        finishEditing()
                    }
                }
        } else {
            // 正常模式：显示标签
            // 点击手势在外层处理，Button（关闭按钮）会自动优先响应
            SimpleTabView(
                title,
                isActive: isActive,
                needsAttention: needsAttention,
                height: height,
                isHovered: isHovered,
                onClose: showCloseButton ? onClose : nil
            )
            .onTapGesture {
                // 自己检测双击，避免 onTapGesture(count: 2) 导致单击延迟
                let now = Date()
                if now.timeIntervalSince(lastTapTime) < doubleTapInterval {
                    // 双击 -> 重命名
                    isEditing = true
                } else {
                    // 单击 -> 切换
                    onTap?()
                }
                lastTapTime = now
            }
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private func finishEditing() {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != title {
            onRename?(trimmed)
        }
        isEditing = false
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

// MARK: - AppKit Bridge（供 RioContainerView 使用）

/// AppKit 桥接类，用于在 NSView 层级中使用 SwiftUI PageBarView
final class PageBarHostingView: NSView {
    private var hostingView: NSHostingView<PageBarControlsView>?

    // 数据状态
    private var pages: [PageItem] = []
    private var activePageId: UUID?

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
        guard let userInfo = notification.userInfo,
              let pageId = userInfo["pageId"] as? UUID,
              let attention = userInfo["attention"] as? Bool else {
            return
        }
        setPageNeedsAttention(pageId, attention: attention)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        // 只使用 SwiftUI 渲染红绿灯和添加按钮，Page 标签用 AppKit
        // 使用闭包捕获 self，确保能访问到后续设置的 onAddPage
        let controlsView = PageBarControlsView(onAddPage: { [weak self] in
            self?.onAddPage?()
        })
        let hosting = NSHostingView(rootView: controlsView)
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

        // 创建新的 Page 视图
        for page in pages {
            let pageView = PageItemView(pageId: page.id, title: page.title)
            pageView.setActive(page.id == activePageId)
            pageView.setShowCloseButton(pages.count > 1)

            // 捕获 pageId 而不是 page，避免闭包捕获问题
            let pageId = page.id
            pageView.onTap = { [weak self] in
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
        // 检查点击是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 优先检查 pageContainer 中的 PageItemView
        let pointInPageContainer = convert(point, to: pageContainer)
        for pageView in pageItemViews {
            let pointInPage = pageContainer.convert(pointInPageContainer, to: pageView)
            if pageView.bounds.contains(pointInPage) {
                // 直接调用 PageItemView 的 hitTest
                if let hitView = pageView.hitTest(pointInPage) {
                    return hitView
                }
                return pageView
            }
        }

        // 然后检查红绿灯和右侧按钮区域（SwiftUI）
        if let hosting = hostingView {
            let pointInHosting = convert(point, to: hosting)
            if let swiftUIHit = hosting.hitTest(pointInHosting), swiftUIHit is NSControl {
                return swiftUIHit
            }
        }

        // 其他区域返回自己，用于窗口拖动
        return self
    }

    /// 设置 Page 列表
    func setPages(_ newPages: [(id: UUID, title: String)]) {
        pages = newPages.map { PageItem(id: $0.id, title: $0.title) }
        rebuildPageItemViews()
    }

    /// 设置激活的 Page
    func setActivePage(_ pageId: UUID) {
        activePageId = pageId
        // 更新激活状态，并清除被激活 Page 的提醒状态
        for pageView in pageItemViews {
            let isActive = pageView.pageId == pageId
            pageView.setActive(isActive)
            if isActive {
                pageView.clearAttention()
            }
        }
    }

    /// 设置指定 Page 的提醒状态
    func setPageNeedsAttention(_ pageId: UUID, attention: Bool) {
        for pageView in pageItemViews where pageView.pageId == pageId {
            pageView.setNeedsAttention(attention)
            break
        }
    }

    /// 推荐高度
    static func recommendedHeight() -> CGFloat {
        return PageBarView.recommendedHeight()
    }

    // MARK: - 窗口拖动

    override var mouseDownCanMoveWindow: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // 在 PageBar 区域拖动窗口
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
    var onAddPage: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // 红绿灯按钮
            TrafficLightButtons()
                .padding(.leading, 12)

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

            StatusTabView(
                text: translationMode.statusText,
                isActive: translationMode.isEnabled,
                onTap: { translationMode.toggle() }
            )
            .padding(.trailing, 12)
        }
        .frame(height: 28)
    }
}

// MARK: - SwiftUIPageBar（用于 ContentView）

/// 纯 SwiftUI 实现的 PageBar，用于在 ContentView 层显示
/// 解决 NSView 嵌套时 safe area 无法正确传递的问题
///
/// TODO: Page 拖拽排序功能暂时禁用，需要用 AppKit 方案实现
struct SwiftUIPageBar: View {
    @ObservedObject var coordinator: TerminalWindowCoordinator
    @ObservedObject private var translationMode = TranslationModeStore.shared
    @State private var isFullScreen = false
    @State private var pagesNeedingAttention: Set<UUID> = []
    @State private var editingPageId: UUID?

    private let barHeight: CGFloat = 28

    var body: some View {
        // 读取 updateTrigger 强制刷新
        let _ = coordinator.updateTrigger

        HStack(spacing: 0) {
            // 系统红绿灯区域预留空间（全屏时不需要）
            if !isFullScreen {
                Spacer().frame(width: 78)
            } else {
                Spacer().frame(width: 12)
            }

            // Page 标签列表
            HStack(spacing: 2) {
                ForEach(coordinator.terminalWindow.pages, id: \.pageId) { page in
                    PageTabView(
                        title: page.title,
                        isActive: page.pageId == coordinator.terminalWindow.activePageId,
                        showCloseButton: coordinator.terminalWindow.pages.count > 1,
                        needsAttention: pagesNeedingAttention.contains(page.pageId),
                        isEditing: Binding(
                            get: { editingPageId == page.pageId },
                            set: { if $0 { editingPageId = page.pageId } else { editingPageId = nil } }
                        ),
                        onTap: { _ = coordinator.switchToPage(page.pageId) },
                        onClose: { _ = coordinator.closePage(page.pageId) },
                        onRename: { newTitle in
                            _ = coordinator.renamePage(page.pageId, to: newTitle)
                        }
                    )
                }
            }

            Spacer()

            // 添加按钮
            Button(action: { _ = coordinator.createPage() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            // 侧边栏按钮
            Button(action: {
                NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
            }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            StatusTabView(
                text: translationMode.statusText,
                isActive: translationMode.isEnabled,
                onTap: { translationMode.toggle() }
            )
            .padding(.trailing, 12)
        }
        .frame(height: barHeight)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PageNeedsAttention"))) { notification in
            guard let userInfo = notification.userInfo,
                  let pageId = userInfo["pageId"] as? UUID,
                  let attention = userInfo["attention"] as? Bool else {
                return
            }
            if attention {
                pagesNeedingAttention.insert(pageId)
            } else {
                pagesNeedingAttention.remove(pageId)
            }
        }
        // 核心逻辑：Page 被激活时自动消费提醒状态
        .onChange(of: coordinator.terminalWindow.activePageId) { _, newPageId in
            if let pageId = newPageId {
                pagesNeedingAttention.remove(pageId)
            }
        }
    }
}

// MARK: - Preview

#Preview("PageBarView") {
    PageBarView(
        pages: .constant([
            PageItem(id: UUID(), title: "Page 1"),
            PageItem(id: UUID(), title: "Page 2"),
            PageItem(id: UUID(), title: "很长的页面名称")
        ]),
        activePageId: .constant(nil)
    )
    .frame(width: 600)
    .background(Color.black.opacity(0.8))
}

#Preview("TrafficLightButtons") {
    TrafficLightButtons()
        .padding(20)
        .background(Color.black.opacity(0.8))
}

#Preview("PageTabView") {
    VStack(spacing: 10) {
        PageTabView(title: "Active Tab", isActive: true, showCloseButton: true, isEditing: .constant(false))
        PageTabView(title: "Inactive Tab", isActive: false, showCloseButton: true, isEditing: .constant(false))
        PageTabView(title: "No Close", isActive: true, showCloseButton: false, isEditing: .constant(false))
    }
    .padding(20)
    .background(Color.black.opacity(0.8))
}
