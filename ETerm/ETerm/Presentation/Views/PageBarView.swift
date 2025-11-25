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
    private var hostingView: NSHostingView<PageBarView>?

    // 数据状态
    private var pages: [PageItem] = []
    private var activePageId: UUID?

    // 回调
    var onPageClick: ((UUID) -> Void)?
    var onPageClose: ((UUID) -> Void)?
    var onPageRename: ((UUID, String) -> Void)?
    var onAddPage: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        let swiftUIView = PageBarView(
            pages: Binding(
                get: { self.pages },
                set: { self.pages = $0 }
            ),
            activePageId: Binding(
                get: { self.activePageId },
                set: { self.activePageId = $0 }
            ),
            onPageClick: onPageClick,
            onPageClose: onPageClose,
            onPageRename: onPageRename,
            onAddPage: onAddPage
        )

        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hosting)

        hostingView = hosting
    }

    private func refreshHostingView() {
        guard let hostingView = hostingView else { return }

        let swiftUIView = PageBarView(
            pages: Binding(
                get: { self.pages },
                set: { self.pages = $0 }
            ),
            activePageId: Binding(
                get: { self.activePageId },
                set: { self.activePageId = $0 }
            ),
            onPageClick: onPageClick,
            onPageClose: onPageClose,
            onPageRename: onPageRename,
            onAddPage: onAddPage
        )

        hostingView.rootView = swiftUIView
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    /// 设置 Page 列表（兼容旧接口）
    func setPages(_ newPages: [(id: UUID, title: String)]) {
        pages = newPages.map { PageItem(id: $0.id, title: $0.title) }
        refreshHostingView()
    }

    /// 设置激活的 Page（兼容旧接口）
    func setActivePage(_ pageId: UUID) {
        activePageId = pageId
        refreshHostingView()
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
