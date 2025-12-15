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
    var rustTerminalId: Int?
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
    private var isPageActive: Bool = true
    private var isPanelActive: Bool = false  // Panel 是否接收键盘输入

    // Tab 标签容器
    private let tabContainer = NSView()
    private var tabItemViews: [TabItemView] = []

    // 所属 Panel ID
    var panelId: UUID?

    // 回调
    var onTabClick: ((UUID) -> Void)?
    var onTabClose: ((UUID) -> Void)?
    var onTabRename: ((UUID, String) -> Void)?
    var onAddTab: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?
    var onTabReorder: (([UUID]) -> Void)?
    var onTabDragOutOfWindow: ((UUID, NSPoint) -> Void)?
    var onTabReceivedFromOtherWindow: ((UUID, UUID, Int) -> Void)?  // tabId, sourcePanelId, sourceWindowNumber

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        print("🔴 [PanelHeader] init - 新实例被创建")
        setupHostingView()
        setupTabContainer()
        setupDragDestination()
    }

    deinit {
        print("🔴 [PanelHeader] deinit - 实例被销毁")
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
            // 只有当前 Tab 激活 且 Panel 也接收键盘输入时，才标记为 active
            tabView.setActive(tab.id == activeTabId && isPanelActive)

            // 设置 Rust Terminal ID（用于 Claude 响应匹配）
            tabView.rustTerminalId = tab.rustTerminalId

            tabView.onTap = { [weak self] in
                self?.onTabClick?(tab.id)
            }

            tabView.onClose = { [weak self] in
                self?.onTabClose?(tab.id)
            }

            tabView.onRename = { [weak self] newTitle in
                self?.onTabRename?(tab.id, newTitle)
            }

            tabView.onDragOutOfWindow = { [weak self] screenPoint in
                self?.onTabDragOutOfWindow?(tab.id, screenPoint)
            }

            // 设置所属 Panel ID（用于拖拽数据）
            tabView.panelId = panelId

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查点击是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 优先检查 tabContainer 中的 TabItemView
        let pointInTabContainer = convert(point, to: tabContainer)
        for tabView in tabItemViews {
            let pointInTab = tabContainer.convert(pointInTabContainer, to: tabView)
            if tabView.bounds.contains(pointInTab) {
                // 直接调用 TabItemView 的 hitTest
                if let hitView = tabView.hitTest(pointInTab) {
                    return hitView
                }
                return tabView
            }
        }

        // 然后检查右侧按钮区域（SwiftUI）
        if let hosting = hostingView {
            let pointInHosting = convert(point, to: hosting)
            if let swiftUIHit = hosting.hitTest(pointInHosting), swiftUIHit is NSControl {
                return swiftUIHit
            }
        }

        // 其他区域返回 nil，让事件穿透
        return nil
    }

    /// 设置 Tab 列表
    func setTabs(_ newTabs: [(id: UUID, title: String, rustTerminalId: Int?)]) {
        let newTabItems = newTabs.map { TabItem(id: $0.id, title: $0.title, rustTerminalId: $0.rustTerminalId) }

        // 检查 tabs 是否真的变化了（ID 列表和顺序）
        let oldIds = tabs.map { $0.id }
        let newIds = newTabItems.map { $0.id }

        if oldIds == newIds {
            // ID 和顺序相同，只更新标题（不重建视图）
            for (index, newTab) in newTabItems.enumerated() {
                tabs[index].title = newTab.title
                tabs[index].rustTerminalId = newTab.rustTerminalId
                if index < tabItemViews.count {
                    tabItemViews[index].setTitle(newTab.title)
                }
            }
        } else {
            // tabs 真的变化了，重建视图
            print("🔵 [PanelHeader] setTabs: 重建视图 old=\(oldIds.map { $0.uuidString.prefix(4) }) new=\(newIds.map { $0.uuidString.prefix(4) })")
            tabs = newTabItems
            rebuildTabItemViews()
        }
    }

    /// 设置激活的 Tab
    func setActiveTab(_ tabId: UUID) {
        activeTabId = tabId
        // 更新激活状态，只有当 Page 也激活时才清除提醒
        for tabView in tabItemViews {
            let isActive = tabView.tabId == tabId
            // 只有当前 Tab 激活 且 Panel 也接收键盘输入时，才标记为 active
            tabView.setActive(isActive && isPanelActive)
            // 只有 Tab 激活且 Page 也激活且 Panel 也激活时，才清除提醒
            if isActive && isPageActive && isPanelActive {
                tabView.clearAttention()
            }
        }
    }

    /// 设置所属 Page 的激活状态
    func setPageActive(_ active: Bool) {
        isPageActive = active
        for tabView in tabItemViews {
            tabView.setPageActive(active)
        }

        // 如果 Page 变为激活，且当前有激活的 Tab，清除其提醒
        if active, let activeTabId = activeTabId {
            for tabView in tabItemViews where tabView.tabId == activeTabId {
                tabView.clearAttention()
                break
            }
        }
    }

    /// 设置 Panel 的激活状态（用于键盘输入焦点）
    func setPanelActive(_ active: Bool) {
        guard isPanelActive != active else { return }
        isPanelActive = active

        // 更新所有 Tab 的激活状态
        for tabView in tabItemViews {
            let isTabActive = tabView.tabId == activeTabId
            // 只有当前 Tab 激活 且 Panel 也接收键盘输入时，才标记为 active
            tabView.setActive(isTabActive && isPanelActive)
        }
    }

    /// 设置指定 Tab 的高亮状态
    func setTabNeedsAttention(_ tabId: UUID, attention: Bool) {
        for tabView in tabItemViews where tabView.tabId == tabId {
            if attention {
                tabView.setNeedsAttention(true)
            } else {
                tabView.clearAttention()
            }
            break
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
    /// 解析拖拽数据
    /// 格式：tab:{windowNumber}:{panelId}:{tabId}
    private func parseTabDragData(_ pasteboardString: String) -> (windowNumber: Int, sourcePanelId: UUID, tabId: UUID)? {
        guard pasteboardString.hasPrefix("tab:") else { return nil }

        let components = pasteboardString.components(separatedBy: ":")
        guard components.count == 4,
              let windowNumber = Int(components[1]),
              let sourcePanelId = UUID(uuidString: components[2]),
              let tabId = UUID(uuidString: components[3]) else {
            return nil
        }
        return (windowNumber, sourcePanelId, tabId)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 检查是否是 Tab 拖拽
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              parseTabDragData(pasteboardString) != nil else {
            return []
        }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              parseTabDragData(pasteboardString) != nil else {
            return []
        }

        // 计算鼠标位置并高亮插入位置（可选，暂时省略）
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pasteboardString = sender.draggingPasteboard.string(forType: .string),
              let dragData = parseTabDragData(pasteboardString) else {
            return false
        }

        let sourceWindowNumber = dragData.windowNumber
        let sourcePanelId = dragData.sourcePanelId
        let tabId = dragData.tabId
        let currentWindowNumber = window?.windowNumber ?? 0

        // 检查是否是跨窗口拖拽
        if sourceWindowNumber != currentWindowNumber {
            // 跨窗口移动
            onTabReceivedFromOtherWindow?(tabId, sourcePanelId, sourceWindowNumber)
            return true
        }

        // 检查是否是同一个 Panel 内的重排序
        guard sourcePanelId == panelId else {
            // 跨 Panel 同窗口拖拽，返回 false 让 DomainPanelView 处理
            return false
        }

        // 同 Panel 内重排序，使用粘贴板中的 tabId
        let draggingId = tabId

        // 计算插入位置
        let location = convert(sender.draggingLocation, from: nil)
        guard let targetIndex = indexForInsertionAt(location: location) else {
            print("🔴 [TabReorder] indexForInsertionAt 返回 nil")
            return false
        }

        // 获取当前拖拽的 Tab 索引
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == draggingId }) else {
            print("🔴 [TabReorder] 找不到拖拽的 Tab: \(draggingId)")
            print("🔴 [TabReorder] 当前 tabs: \(tabs.map { $0.id })")
            return false
        }

        print("🟡 [TabReorder] 拖拽开始:")
        print("  - 拖拽 Tab ID: \(draggingId)")
        print("  - sourceIndex: \(sourceIndex), targetIndex: \(targetIndex)")
        print("  - 当前 tabs: \(tabs.map { "\($0.title)(\($0.id.uuidString.prefix(4)))" })")

        // 如果位置相同，不处理
        if sourceIndex == targetIndex || sourceIndex + 1 == targetIndex {
            print("🟡 [TabReorder] 位置相同，不处理")
            return false
        }

        // 计算新的顺序
        var newOrder = tabs.map { $0.id }
        let movedId = newOrder.remove(at: sourceIndex)
        let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        newOrder.insert(movedId, at: insertIndex)

        print("🟢 [TabReorder] 计算新顺序: \(newOrder.map { $0.uuidString.prefix(4) })")

        // 提交意图到队列，不立即执行
        // drag session 结束后会通过 Notification 触发实际执行
        guard let panelId = panelId else {
            print("🔴 [TabReorder] panelId 为 nil")
            return false
        }

        DropIntentQueue.shared.submit(.reorderTabs(panelId: panelId, tabIds: newOrder))
        return true
    }

    /// 应用 Tab 重排序（视图复用，不重建）
    ///
    /// 由 Coordinator 通过 Notification 触发，在 drag session 结束后调用
    func applyTabReorder(_ newOrder: [UUID]) {
        print("🟢 [PanelHeader] applyTabReorder: \(newOrder.map { $0.uuidString.prefix(4) })")

        // 1. 根据新顺序重新排列 tabItemViews（复用，不重建）
        var reorderedViews: [TabItemView] = []
        for tabId in newOrder {
            if let view = tabItemViews.first(where: { $0.tabId == tabId }) {
                reorderedViews.append(view)
            }
        }

        // 2. 更新视图数组
        tabItemViews = reorderedViews

        // 3. 更新数据数组
        let newTabs = newOrder.compactMap { id in tabs.first { $0.id == id } }
        tabs = newTabs

        // 4. 只调整位置，不重建
        layoutTabItems()

        print("🟢 [PanelHeader] applyTabReorder 完成，视图已复用")
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
            // Spacer 区域禁用点击，让事件穿透到下面的 TabItemView
            Spacer()
                .allowsHitTesting(false)

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
