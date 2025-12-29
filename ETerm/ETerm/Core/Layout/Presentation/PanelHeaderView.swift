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

    /// Tab 模型注册表（弱引用，用于传递给 TabItemView）
    private var tabRegistry: [UUID: Tab] = [:]

    // 滚动容器
    private let scrollView = NSScrollView()
    // Tab 标签容器（作为 scrollView 的 documentView）
    private let tabContainer = NSView()
    private var tabItemViews: [TabItemView] = []

    // 渐变遮罩层
    private let leftFadeLayer = CAGradientLayer()
    private let rightFadeLayer = CAGradientLayer()
    private let fadeWidth: CGFloat = 16

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

    // 批量关闭回调
    var onTabCloseOthers: ((UUID) -> Void)?  // 关闭除指定 Tab 外的所有 Tab
    var onTabCloseLeft: ((UUID) -> Void)?    // 关闭指定 Tab 左侧的所有 Tab
    var onTabCloseRight: ((UUID) -> Void)?   // 关闭指定 Tab 右侧的所有 Tab

    // 跨 Panel 合并回调（从其他 Panel 拖入 Tab）
    var onTabMergedFromOtherPanel: ((UUID, UUID) -> Void)?  // tabId, sourcePanelId

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
        setupScrollView()
        setupFadeLayers()
        setupDragDestination()
    }

    deinit {
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingView() {
        // 只使用 SwiftUI 渲染右侧按钮，Tab 标签用 AppKit
        // 使用 [weak self] 捕获，让回调在调用时读取最新值
        let controlsView = PanelHeaderControlsView(
            onAddTab: { [weak self] in self?.onAddTab?() },
            onSplitHorizontal: { [weak self] in self?.onSplitHorizontal?() }
        )
        let hosting = NSHostingView(rootView: controlsView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hosting)
        hostingView = hosting
    }

    private func setupScrollView() {
        // 配置 scrollView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        // 设置 documentView
        tabContainer.wantsLayer = true
        scrollView.documentView = tabContainer

        addSubview(scrollView)

        // 监听滚动位置变化
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func setupFadeLayers() {
        wantsLayer = true

        // 使用深色背景色（匹配终端背景）
        let fadeColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)

        // 左侧渐变（从不透明到透明）
        leftFadeLayer.colors = [
            fadeColor.cgColor,
            fadeColor.withAlphaComponent(0).cgColor
        ]
        leftFadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        leftFadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        leftFadeLayer.opacity = 0
        leftFadeLayer.zPosition = 100  // 确保在最上层

        // 右侧渐变（从透明到不透明）
        rightFadeLayer.colors = [
            fadeColor.withAlphaComponent(0).cgColor,
            fadeColor.cgColor
        ]
        rightFadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        rightFadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        rightFadeLayer.opacity = 0
        rightFadeLayer.zPosition = 100  // 确保在最上层
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 确保 layer 创建后再添加渐变层
        if let layer = self.layer {
            if leftFadeLayer.superlayer == nil {
                layer.addSublayer(leftFadeLayer)
            }
            if rightFadeLayer.superlayer == nil {
                layer.addSublayer(rightFadeLayer)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 将滚轮事件转发给 scrollView
        scrollView.scrollWheel(with: event)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        updateFadeVisibility()
    }

    private func updateFadeVisibility() {
        let contentWidth = tabContainer.frame.width
        let visibleWidth = scrollView.bounds.width
        let scrollOffset = scrollView.contentView.bounds.origin.x

        // 左侧渐变：有内容被滚动到左边时显示
        let showLeftFade = scrollOffset > 1
        // 右侧渐变：有内容在右边时显示
        let showRightFade = contentWidth - scrollOffset > visibleWidth + 1

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        leftFadeLayer.opacity = showLeftFade ? 1.0 : 0.0
        rightFadeLayer.opacity = showRightFade ? 1.0 : 0.0
        CATransaction.commit()
    }

    private func setupDragDestination() {
        registerForDraggedTypes([.string])
    }

    private func rebuildTabItemViews() {
        // 移除旧的 Tab 视图
        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        let tabCount = tabs.count

        // 创建新的 Tab 视图
        for (index, tab) in tabs.enumerated() {
            // 从注册表获取 Tab 模型引用
            let tabModel = tabRegistry[tab.id]
            let tabView = TabItemView(tabId: tab.id, title: tab.title, tab: tabModel)
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

            // 批量关闭回调
            tabView.onCloseOthers = { [weak self] in
                self?.onTabCloseOthers?(tab.id)
            }
            tabView.onCloseLeft = { [weak self] in
                self?.onTabCloseLeft?(tab.id)
            }
            tabView.onCloseRight = { [weak self] in
                self?.onTabCloseRight?(tab.id)
            }

            // 宽度变化时重新布局
            tabView.onWidthChanged = { [weak self] in
                self?.layoutTabItems()
            }

            // 设置可关闭状态（基于位置）
            tabView.canCloseLeft = index > 0
            tabView.canCloseRight = index < tabCount - 1
            tabView.canCloseOthers = tabCount > 1

            // 设置所属 Panel ID（用于拖拽数据）
            tabView.panelId = panelId

            tabContainer.addSubview(tabView)
            tabItemViews.append(tabView)
        }

        layoutTabItems()
    }

    private func layoutTabItems() {
        let spacing: CGFloat = 4
        var x: CGFloat = 0  // scrollView 内部从 0 开始

        for tabView in tabItemViews {
            let size = tabView.fittingSize
            tabView.frame = CGRect(x: x, y: 3, width: size.width, height: size.height)
            // 设置 frame 后触发 layout()，确保 hostingView 被创建并设置正确尺寸
            tabView.layout()
            x += size.width + spacing
        }

        // 更新 tabContainer 的尺寸以适应内容
        let contentWidth = max(x, scrollView.bounds.width)
        tabContainer.frame = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)

        // 更新渐变显示状态
        updateFadeVisibility()
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds

        // scrollView 布局：左侧留出 padding，右侧留出按钮空间
        let leftPadding: CGFloat = 4
        let rightPadding: CGFloat = 60  // 右侧按钮区域
        let scrollWidth = bounds.width - leftPadding - rightPadding
        scrollView.frame = CGRect(x: leftPadding, y: 0, width: max(0, scrollWidth), height: bounds.height)

        layoutTabItems()
        layoutFadeLayers()
    }

    private func layoutFadeLayers() {
        let leftPadding: CGFloat = 4
        let rightPadding: CGFloat = 60
        let scrollWidth = bounds.width - leftPadding - rightPadding

        // 左侧渐变位置（紧贴 scrollView 左边缘）
        leftFadeLayer.frame = CGRect(x: leftPadding, y: 0, width: fadeWidth, height: bounds.height)

        // 右侧渐变位置（紧贴 scrollView 右边缘）
        rightFadeLayer.frame = CGRect(x: leftPadding + scrollWidth - fadeWidth, y: 0, width: fadeWidth, height: bounds.height)
    }

    /// 右侧按钮区域宽度（两个按钮 24x2 + padding 4x2 + 间距）
    private static let controlsAreaWidth: CGFloat = 60

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查点击是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 检查是否在右侧按钮区域（Split/Add 按钮）
        if point.x > bounds.width - Self.controlsAreaWidth {
            if let hosting = hostingView {
                let pointInHosting = convert(point, to: hosting)
                // 返回 hostingView 内部的视图，让 SwiftUI 处理事件
                if let swiftUIHit = hosting.hitTest(pointInHosting) {
                    // 即使是 hosting 本身也返回，让 SwiftUI 决定是否响应
                    return swiftUIHit
                }
            }
        }

        // 检查是否在 scrollView 区域内
        if scrollView.frame.contains(point) {
            // 转换到 tabContainer 坐标
            let pointInScrollView = convert(point, to: scrollView)
            let pointInTabContainer = scrollView.convert(pointInScrollView, to: tabContainer)

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

            // 点击在 scrollView 内的空白区域，返回 self
            // （滚动通过 scrollWheel 事件转发处理）
            return self
        }

        // 其他区域返回 nil，让事件穿透
        return nil
    }

    /// 设置 Tab 列表
    /// - Parameters:
    ///   - newTabs: Tab 信息元组数组
    ///   - tabModels: 对应的 Tab 模型数组（用于装饰系统读取）
    func setTabs(_ newTabs: [(id: UUID, title: String, rustTerminalId: Int?)], tabModels: [Tab] = []) {
        let newTabItems = newTabs.map { TabItem(id: $0.id, title: $0.title, rustTerminalId: $0.rustTerminalId) }

        // 更新 Tab 模型注册表
        tabRegistry.removeAll()
        for tab in tabModels {
            tabRegistry[tab.tabId] = tab
        }

        // 检查 tabs 是否真的变化了（ID 列表和顺序）
        let oldIds = tabs.map { $0.id }
        let newIds = newTabItems.map { $0.id }

        if oldIds == newIds {
            // ID 和顺序相同，只更新标题、rustTerminalId 和 Tab 引用（不重建视图）
            for (index, newTab) in newTabItems.enumerated() {
                tabs[index].title = newTab.title
                tabs[index].rustTerminalId = newTab.rustTerminalId
                if index < tabItemViews.count {
                    tabItemViews[index].title = newTab.title
                    tabItemViews[index].rustTerminalId = newTab.rustTerminalId
                    tabItemViews[index].tab = tabRegistry[newTab.id]
                }
            }
            // 标题变化可能导致宽度变化，需要重新布局
            layoutTabItems()
        } else {
            // tabs 真的变化了，重建视图
            tabs = newTabItems
            rebuildTabItemViews()
        }
    }

    /// 设置激活的 Tab
    /// - Parameter tabId: 要激活的 Tab ID
    /// 注意：装饰清除由插件通过 tabDidFocus 通知处理，核心层不直接清除
    func setActiveTab(_ tabId: UUID) {
        activeTabId = tabId
        // 更新激活状态
        for tabView in tabItemViews {
            let isActive = tabView.tabId == tabId
            // 只有当前 Tab 激活 且 Panel 也接收键盘输入时，才标记为 active
            tabView.setActive(isActive && isPanelActive)
        }
    }

    /// 设置所属 Page 的激活状态
    func setPageActive(_ active: Bool) {
        isPageActive = active
        for tabView in tabItemViews {
            tabView.setPageActive(active)
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
            // 跨 Panel 同窗口拖拽，调用合并回调
            onTabMergedFromOtherPanel?(tabId, sourcePanelId)
            return true
        }

        // 同 Panel 内重排序，使用粘贴板中的 tabId
        let draggingId = tabId

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

        // 计算新的顺序
        var newOrder = tabs.map { $0.id }
        let movedId = newOrder.remove(at: sourceIndex)
        let insertIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        newOrder.insert(movedId, at: insertIndex)


        // 提交意图到队列，不立即执行
        // drag session 结束后会通过 Notification 触发实际执行
        guard let panelId = panelId else {
            return false
        }

        DropIntentQueue.shared.submit(.reorderTabs(panelId: panelId, tabIds: newOrder))
        return true
    }

    /// 应用 Tab 重排序（视图复用，不重建）
    ///
    /// 由 Coordinator 通过 Notification 触发，在 drag session 结束后调用
    func applyTabReorder(_ newOrder: [UUID]) {

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

    }


    /// 根据位置计算插入索引
    private func indexForInsertionAt(location: NSPoint) -> Int? {
        let spacing: CGFloat = 4

        // 将位置转换到 scrollView/tabContainer 坐标系
        let scrollOffset = scrollView.contentView.bounds.origin.x
        let locationInContainer = location.x - scrollView.frame.origin.x + scrollOffset

        if locationInContainer < 0 {
            return 0
        }

        var x: CGFloat = 0
        for (index, tabView) in tabItemViews.enumerated() {
            let midpoint = x + tabView.fittingSize.width / 2
            if locationInContainer < midpoint {
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 添加按钮
            Button(action: { onAddTab?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
