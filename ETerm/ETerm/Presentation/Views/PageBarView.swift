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

// MARK: - Page 数据模型

struct PageItem: Identifiable, Equatable {
    let id: UUID
    var title: String
}

// MARK: - PageBarView (SwiftUI)

struct PageBarView: View {
    // MARK: - 数据

    @Binding var pages: [PageItem]
    @Binding var activePageId: UUID?

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
                        onTap: { onPageClick?(page.id) },
                        onClose: { onPageClose?(page.id) }
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
            .padding(.trailing, 8)
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

// MARK: - Page 标签（使用水墨风格）

struct PageTabView: View {
    let title: String
    let isActive: Bool
    let showCloseButton: Bool
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?

    private let height: CGFloat = 22

    var body: some View {
        ShuimoTabView(
            title,
            isActive: isActive,
            height: height,
            onClose: showCloseButton ? onClose : nil
        )
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - AppKit Bridge（供 RioContainerView 使用）

/// AppKit 桥接类，用于在 NSView 层级中使用 SwiftUI PageBarView
final class PageBarHostingView: NSView {
    private var hostingView: NSHostingView<PageBarControlsView>?

    // 数据状态
    private var pages: [PageItem] = []
    private var activePageId: UUID?

    // Page 标签容器
    private let pageContainer = NSView()
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        // 只使用 SwiftUI 渲染红绿灯和添加按钮，Page 标签用 AppKit
        let controlsView = PageBarControlsView(onAddPage: onAddPage)
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

            pageView.onTap = { [weak self] in
                self?.onPageClick?(page.id)
            }

            pageView.onClose = { [weak self] in
                self?.onPageClose?(page.id)
            }

            pageView.onRename = { [weak self] newTitle in
                self?.onPageRename?(page.id, newTitle)
            }

            pageView.onDragStart = { [weak self] in
                self?.draggingPageId = page.id
            }

            pageView.onDragOutOfWindow = { [weak self] screenPoint in
                self?.onPageDragOutOfWindow?(page.id, screenPoint)
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
        pageContainer.frame = bounds
        layoutPageItems()
    }

    /// 设置 Page 列表（兼容旧接口）
    func setPages(_ newPages: [(id: UUID, title: String)]) {
        pages = newPages.map { PageItem(id: $0.id, title: $0.title) }
        rebuildPageItemViews()
    }

    /// 设置激活的 Page（兼容旧接口）
    func setActivePage(_ pageId: UUID) {
        activePageId = pageId
        // 更新激活状态
        for pageView in pageItemViews {
            pageView.setActive(pageView.pageId == pageId)
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
        // 兼容旧格式 page:{pageId} 和新格式 page:{windowNumber}:{pageId}
        if components.count == 2 {
            // 旧格式
            guard let pageId = UUID(uuidString: components[1]) else { return nil }
            return (window?.windowNumber ?? 0, pageId)
        } else if components.count == 3 {
            // 新格式
            guard let windowNumber = Int(components[1]),
                  let pageId = UUID(uuidString: components[2]) else { return nil }
            return (windowNumber, pageId)
        }
        return nil
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
            .padding(.trailing, 8)
        }
        .frame(height: 28)
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
        PageTabView(title: "Active Tab", isActive: true, showCloseButton: true)
        PageTabView(title: "Inactive Tab", isActive: false, showCloseButton: true)
        PageTabView(title: "No Close", isActive: true, showCloseButton: false)
    }
    .padding(20)
    .background(Color.black.opacity(0.8))
}
