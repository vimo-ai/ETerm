//
//  PanelHeaderView.swift
//  ETerm
//
//  Panel Header 视图 - Tab 栏（SwiftUI 版本）
//
//  对应 Golden Layout 的 Header 组件。
//  负责：
//  - 显示所有 Tab
//  - 管理 Tab 的布局
//  - 处理 Tab 的添加/移除
//

import SwiftUI
import AppKit

// MARK: - Tab 数据模型

struct TabItem: Identifiable, Equatable {
    let id: UUID
    var title: String
}

// MARK: - PanelHeaderView (SwiftUI)

struct PanelHeaderView: View {
    // MARK: - 数据

    @Binding var tabs: [TabItem]
    @Binding var activeTabId: UUID?

    // MARK: - 回调

    var onTabClick: ((UUID) -> Void)?
    var onTabClose: ((UUID) -> Void)?
    var onTabRename: ((UUID, String) -> Void)?
    var onAddTab: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?

    // MARK: - 常量

    private static let headerHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 4) {
            // Tab 列表
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    TabItemSwiftUIView(
                        title: tab.title,
                        isActive: tab.id == activeTabId,
                        onTap: { onTabClick?(tab.id) },
                        onClose: { onTabClose?(tab.id) }
                    )
                }
            }

            Spacer()

            // 水平分割按钮
            Button(action: { onSplitHorizontal?() }) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)

            // 添加按钮
            Button(action: { onAddTab?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 4)
        .frame(height: Self.headerHeight)
    }

    // MARK: - 推荐高度

    static func recommendedHeight() -> CGFloat {
        return headerHeight
    }
}

// MARK: - Tab 视图（使用水墨风格）

struct TabItemSwiftUIView: View {
    let title: String
    let isActive: Bool
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?

    private let height: CGFloat = 26

    var body: some View {
        ShuimoTabView(
            title,
            isActive: isActive,
            height: height,
            onClose: onClose
        )
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - AppKit Bridge（供 DomainPanelView 使用）

/// AppKit 桥接类，用于在 NSView 层级中使用 SwiftUI PanelHeaderView
final class PanelHeaderHostingView: NSView {
    private var hostingView: NSHostingView<PanelHeaderControlsView>?

    // 数据状态
    private var tabs: [TabItem] = []
    private var activeTabId: UUID?

    // Tab 标签容器
    private let tabContainer = NSView()
    private var tabItemViews: [TabItemView] = []

    // 拖拽相关
    private var draggingTabId: UUID?

    // 回调
    var onTabClick: ((UUID) -> Void)?
    var onTabClose: ((UUID) -> Void)?
    var onTabRename: ((UUID, String) -> Void)?
    var onAddTab: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?
    var onTabReorder: (([UUID]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
        setupTabContainer()
        setupDragDestination()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        // 只使用 SwiftUI 渲染右侧按钮，Tab 标签用 AppKit
        let controlsView = PanelHeaderControlsView(
            onAddTab: onAddTab,
            onSplitHorizontal: onSplitHorizontal
        )
        let hosting = NSHostingView(rootView: controlsView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hosting)
        hostingView = hosting
    }

    private func setupTabContainer() {
        tabContainer.wantsLayer = true
        addSubview(tabContainer)
    }

    private func setupDragDestination() {
        registerForDraggedTypes([.string])
    }

    private func rebuildTabItemViews() {
        // 移除旧的 Tab 视图
        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        // 创建新的 Tab 视图
        for tab in tabs {
            let tabView = TabItemView(tabId: tab.id, title: tab.title)
            tabView.setActive(tab.id == activeTabId)

            tabView.onTap = { [weak self] in
                self?.onTabClick?(tab.id)
            }

            tabView.onClose = { [weak self] in
                self?.onTabClose?(tab.id)
            }

            tabView.onRename = { [weak self] newTitle in
                self?.onTabRename?(tab.id, newTitle)
            }

            tabView.onDragStart = { [weak self] in
                self?.draggingTabId = tab.id
            }

            tabContainer.addSubview(tabView)
            tabItemViews.append(tabView)
        }

        layoutTabItems()
    }

    private func layoutTabItems() {
        let leftPadding: CGFloat = 4
        let spacing: CGFloat = 4
        var x: CGFloat = leftPadding

        for tabView in tabItemViews {
            let size = tabView.fittingSize
            tabView.frame = CGRect(x: x, y: 3, width: size.width, height: size.height)
            x += size.width + spacing
        }
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
        tabContainer.frame = bounds
        layoutTabItems()
    }

    /// 设置 Tab 列表（兼容旧接口）
    func setTabs(_ newTabs: [(id: UUID, title: String)]) {
        tabs = newTabs.map { TabItem(id: $0.id, title: $0.title) }
        rebuildTabItemViews()
    }

    /// 设置激活的 Tab（兼容旧接口）
    func setActiveTab(_ tabId: UUID) {
        activeTabId = tabId
        // 更新激活状态
        for tabView in tabItemViews {
            tabView.setActive(tabView.tabId == tabId)
        }
    }

    /// 获取所有 Tab 的边界（用于拖拽计算）
    func getTabBounds() -> [UUID: CGRect] {
        var bounds: [UUID: CGRect] = [:]
        for tabView in tabItemViews {
            bounds[tabView.tabId] = tabView.frame
        }
        return bounds
    }

    /// 推荐高度
    static func recommendedHeight() -> CGFloat {
        return PanelHeaderView.recommendedHeight()
    }
}

// MARK: - NSDraggingDestination

extension PanelHeaderHostingView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 检查是否是 Tab 拖拽
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              pasteboardString.hasPrefix("tab:") else {
            return []
        }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              pasteboardString.hasPrefix("tab:") else {
            return []
        }

        // 计算鼠标位置并高亮插入位置（可选，暂时省略）
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              pasteboardString.hasPrefix("tab:"),
              let draggingId = draggingTabId else {
            return false
        }

        // 计算插入位置
        let location = convert(sender.draggingLocation, from: nil)
        guard let targetIndex = indexForInsertionAt(location: location) else {
            return false
        }

        // 获取当前拖拽的 Tab 索引
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == draggingId }) else {
            return false
        }

        // 如果位置相同，不处理
        if sourceIndex == targetIndex || sourceIndex + 1 == targetIndex {
            return false
        }

        // 重新排列
        var newTabs = tabs
        let movedTab = newTabs.remove(at: sourceIndex)
        let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        newTabs.insert(movedTab, at: insertIndex)

        tabs = newTabs
        rebuildTabItemViews()

        // 通知外部重排序
        let tabIds = tabs.map { $0.id }
        onTabReorder?(tabIds)

        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        draggingTabId = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        draggingTabId = nil
    }

    /// 根据位置计算插入索引
    private func indexForInsertionAt(location: NSPoint) -> Int? {
        let leftPadding: CGFloat = 4
        let spacing: CGFloat = 4

        if location.x < leftPadding {
            return 0
        }

        var x: CGFloat = leftPadding
        for (index, tabView) in tabItemViews.enumerated() {
            let midpoint = x + tabView.fittingSize.width / 2
            if location.x < midpoint {
                return index
            }
            x += tabView.fittingSize.width + spacing
        }

        return tabItemViews.count
    }
}

// MARK: - PanelHeaderControlsView (SwiftUI)

/// 只包含右侧按钮的控制栏
struct PanelHeaderControlsView: View {
    var onAddTab: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            // 水平分割按钮
            Button(action: { onSplitHorizontal?() }) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)

            // 添加按钮
            Button(action: { onAddTab?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
    }
}

// MARK: - Preview

#Preview("PanelHeaderView") {
    PanelHeaderView(
        tabs: .constant([
            TabItem(id: UUID(), title: "终端 1"),
            TabItem(id: UUID(), title: "终端 2"),
            TabItem(id: UUID(), title: "很长的标签名称")
        ]),
        activeTabId: .constant(nil)
    )
    .frame(width: 500)
    .background(Color.black.opacity(0.8))
}

#Preview("TabItemSwiftUIView") {
    VStack(spacing: 10) {
        TabItemSwiftUIView(title: "Active Tab", isActive: true)
        TabItemSwiftUIView(title: "Inactive Tab", isActive: false)
    }
    .padding(20)
    .background(Color.black.opacity(0.8))
}
