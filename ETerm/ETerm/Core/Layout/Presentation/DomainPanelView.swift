//
//  DomainPanelView.swift
//  ETerm
//
//  基于 Domain AR 的 Panel 视图（重构版）
//
//  架构原则：
//  - 从 EditorPanel AR 读取数据
//  - 不持有状态，只负责显示
//  - 用户操作通过 Coordinator 调用 AR 方法
//
//  重构变化：
//  - 使用 PanelHeaderHostingView（SwiftUI 桥接）实现 Tab 栏
//  - 通过回调处理事件
//

import AppKit
import Foundation
import PanelLayoutKit
import SwiftUI
import ETermKit

/// 基于 Domain AR 的 Panel 视图
final class DomainPanelView: NSView {
    // MARK: - Properties

    /// Panel 聚合根（只读引用）
    private weak var panel: EditorPanel?

    /// Coordinator（用于调用 AR 方法）
    private weak var coordinator: TerminalWindowCoordinator?

    /// Header 视图（SwiftUI 桥接）
    private let headerView: PanelHeaderHostingView

    /// Content 视图（渲染区域 - 透明，用于终端内容）
    let contentView: NSView

    /// 高亮层（显示 Drop Zone）
    private let highlightLayer: CALayer

    /// 当前的 Drop Zone
    private var currentDropZone: DropZone?

    // MARK: - Initialization

    init(panel: EditorPanel, coordinator: TerminalWindowCoordinator) {
        self.panel = panel
        self.coordinator = coordinator
        self.headerView = PanelHeaderHostingView()
        self.contentView = NSView()
        self.highlightLayer = CALayer()

        super.init(frame: .zero)

        setupUI()
        updateUI()
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    private func setupNotifications() {
        // 监听 Tab 重排序通知（视图复用）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplyTabReorder(_:)),
            name: .applyTabReorder,
            object: nil
        )

    }

    @objc private func handleApplyTabReorder(_ notification: Notification) {
        guard let notifPanelId = notification.userInfo?["panelId"] as? UUID,
              notifPanelId == panel?.panelId,
              let tabIds = notification.userInfo?["tabIds"] as? [UUID] else {
            return
        }


        // 应用视图重排序（复用视图，不重建）
        headerView.applyTabReorder(tabIds)
    }


    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit Testing

    /// 让 content 区域的鼠标事件穿透
    ///
    /// - 终端 Tab：穿透到底层 Metal 视图
    /// - View Tab：穿透到 ContentView 的 SwiftUI overlay 层
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 首先检查点是否在自己的 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 检查是否在 Header 区域
        let headerPoint = convert(point, to: headerView)
        if headerView.bounds.contains(headerPoint) {
            // 直接调用 headerView 的 hitTest，确保事件正确路由到 TabItemView
            if let hitView = headerView.hitTest(headerPoint) {
                return hitView
            }
            // 如果 headerView.hitTest 返回 nil，返回 headerView 自己
            return headerView
        }

        // Content 区域：始终返回 nil（终端穿透到 Metal，View Tab 穿透到 SwiftUI overlay）
        return nil
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        // Content（透明，让 Metal 层透过来）
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.isOpaque = false
        addSubview(contentView)

        // Header（不透明，有背景色）
        addSubview(headerView)

        // 配置高亮层
        highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        highlightLayer.cornerRadius = 4
        highlightLayer.isHidden = true
        contentView.layer?.addSublayer(highlightLayer)

        // 设置 Header 的回调
        headerView.onTabClick = { [weak self] tabId in
            self?.handleTabClick(tabId)
        }

        headerView.onTabClose = { [weak self] tabId in
            self?.handleTabClose(tabId)
        }

        headerView.onTabRename = { [weak self] tabId, newTitle in
            self?.handleTabRename(tabId, newTitle: newTitle)
        }

        headerView.onAddTab = { [weak self] in
            self?.handleAddTab()
        }

        headerView.onSplitHorizontal = { [weak self] in
            self?.handleSplitHorizontal()
        }

        headerView.onTabReorder = { [weak self] tabIds in
            self?.handleTabReorder(tabIds)
        }

        // 跨窗口拖拽：Tab 拖出当前窗口
        headerView.onTabDragOutOfWindow = { [weak self] tabId, screenPoint in
            self?.handleTabDragOutOfWindow(tabId, screenPoint: screenPoint)
        }

        // 跨窗口拖拽：从其他窗口接收 Tab
        headerView.onTabReceivedFromOtherWindow = { [weak self] tabId, sourcePanelId, sourceWindowNumber in
            self?.handleTabReceivedFromOtherWindow(tabId, sourcePanelId: sourcePanelId, sourceWindowNumber: sourceWindowNumber)
        }

        // 批量关闭回调
        headerView.onTabCloseOthers = { [weak self] tabId in
            self?.handleTabCloseOthers(tabId)
        }
        headerView.onTabCloseLeft = { [weak self] tabId in
            self?.handleTabCloseLeft(tabId)
        }
        headerView.onTabCloseRight = { [weak self] tabId in
            self?.handleTabCloseRight(tabId)
        }

        // 跨 Panel 合并回调
        headerView.onTabMergedFromOtherPanel = { [weak self] tabId, sourcePanelId in
            self?.handleTabMergedFromOtherPanel(tabId, sourcePanelId: sourcePanelId)
        }

        // 设置 panelId（用于拖拽数据）
        headerView.panelId = panel?.panelId
    }

    // MARK: - Update

    /// 从 AR 更新 UI
    func updateUI() {
        guard let panel = panel else { return }

        // 更新 Header 显示的 Tab（传入 Tab 模型数组用于装饰系统）
        let tabInfos = panel.tabs.map { (id: $0.tabId, title: $0.title, rustTerminalId: $0.rustTerminalId.map { Int($0) }) }
        headerView.setTabs(tabInfos, tabModels: panel.tabs)

        // 更新激活的 Tab
        if let activeTabId = panel.activeTabId {
            headerView.setActiveTab(activeTabId)
        }

        // 根据 activeTab 类型切换内容显示
        updateContentView()
    }

    /// 根据 activeTab 类型更新内容视图
    ///
    /// View Tab 的渲染由 ContentView 的 SwiftUI overlay 层处理，
    /// 这里只需要确保 contentView 保持透明即可。
    private func updateContentView() {
        // contentView 始终保持透明：
        // - 终端 Tab：透过到底层 Metal 视图
        // - View Tab：透过到上层 SwiftUI overlay
    }

    /// 设置所属 Page 的激活状态
    func setPageActive(_ active: Bool) {
        headerView.setPageActive(active)
    }

    /// 设置 Panel 的激活状态（用于键盘输入焦点）
    func setPanelActive(_ active: Bool) {
        headerView.setPanelActive(active)
    }

    // MARK: - Layout

    private static var layoutCount = 0
    private static var lastLayoutLog = Date()

    override func layout() {
        super.layout()

        // 调试：统计 layout 调用频率
        Self.layoutCount += 1
        let now = Date()
        if now.timeIntervalSince(Self.lastLayoutLog) > 1.0 {
            if Self.layoutCount > 10 {
                logDebug("[DomainPanelView] layout called \(Self.layoutCount) times in last second!")
            }
            Self.layoutCount = 0
            Self.lastLayoutLog = now
        }

        let headerHeight = PanelHeaderHostingView.recommendedHeight()

        // Header 在顶部
        headerView.frame = CGRect(
            x: 0,
            y: bounds.height - headerHeight,
            width: bounds.width,
            height: headerHeight
        )

        // Content 占据剩余空间
        contentView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - headerHeight
        )

    }

    // MARK: - Event Handlers

    private func handleTabClick(_ tabId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        // 更新 UI 状态（装饰清除由插件通过 tabDidFocus 通知处理）
        headerView.setActiveTab(tabId)

        coordinator.handleTabClick(panelId: panel.panelId, tabId: tabId)
    }

    private func handleTabClose(_ tabId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        // 直接关闭指定的 Tab（不使用 SmartClose，避免 activePanelId 不一致的问题）
        coordinator.handleTabClose(panelId: panel.panelId, tabId: tabId)
    }

    private func handleTabRename(_ tabId: UUID, newTitle: String) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabRename(panelId: panel.panelId, tabId: tabId, newTitle: newTitle)
    }

    private func handleAddTab() {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleAddTab(panelId: panel.panelId)
    }

    private func handleSplitHorizontal() {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleSplitPanel(panelId: panel.panelId, direction: .horizontal)
    }

    private func handleTabReorder(_ tabIds: [UUID]) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabReorder(panelId: panel.panelId, tabIds: tabIds)
    }

    private func handleTabDragOutOfWindow(_ tabId: UUID, screenPoint: NSPoint) {
        guard let panel = panel,
              let coordinator = coordinator,
              let tab = panel.tabs.first(where: { $0.tabId == tabId }) else {
            return
        }

        // 前置检查：单 Window 单 Page 单 Panel 单 Tab 时禁止拖出
        // 原因：拖出后源窗口必然关闭，等于移动整个窗口，应该直接拖窗口标题栏
        guard canDragTabOut(panel: panel, coordinator: coordinator) else {
            return
        }

        // 创建新窗口
        WindowManager.shared.createWindowWithTab(tab, from: panel.panelId, sourceCoordinator: coordinator, at: screenPoint)
    }

    /// 检查是否可以将 Tab 拖出到新窗口
    ///
    /// 单 Window 单 Page 单 Panel 单 Tab 时禁止拖出，
    /// 因为拖出后源窗口必然关闭，等于移动整个窗口。
    private func canDragTabOut(panel: EditorPanel, coordinator: TerminalWindowCoordinator) -> Bool {
        // 多 Tab：允许（关掉一个 Tab，其他 Tab 还在）
        if panel.tabCount > 1 {
            return true
        }

        // 单 Tab 但有多 Panel：允许（关掉这个 Panel，其他 Panel 还在）
        if let page = coordinator.terminalWindow.active.page,
           page.allPanels.count > 1 {
            return true
        }

        // 单 Panel 但有多 Page：允许（关掉这个 Page，其他 Page 还在）
        if coordinator.terminalWindow.pages.count > 1 {
            return true
        }

        // 单 Window 单 Page 单 Panel 单 Tab：禁止
        // 注：Window 数量由 WindowManager 管理，这里只检查当前窗口内部
        return false
    }

    private func handleTabReceivedFromOtherWindow(_ tabId: UUID, sourcePanelId: UUID, sourceWindowNumber: Int) {
        guard let panel = panel,
              let targetWindow = window else {
            return
        }

        let targetWindowNumber = targetWindow.windowNumber
        let targetPanelId = panel.panelId

        WindowManager.shared.moveTab(tabId, from: sourcePanelId, sourceWindowNumber: sourceWindowNumber, to: targetPanelId, targetWindowNumber: targetWindowNumber)
    }

    private func handleTabCloseOthers(_ tabId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabCloseOthers(panelId: panel.panelId, keepTabId: tabId)
    }

    private func handleTabCloseLeft(_ tabId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabCloseLeft(panelId: panel.panelId, fromTabId: tabId)
    }

    private func handleTabCloseRight(_ tabId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabCloseRight(panelId: panel.panelId, fromTabId: tabId)
    }

    /// 处理跨 Panel 合并（从其他 Panel 拖入 Tab 到当前 Panel 的 header）
    private func handleTabMergedFromOtherPanel(_ tabId: UUID, sourcePanelId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabMerge(tabId: tabId, from: sourcePanelId, to: panel.panelId)
    }

    // MARK: - Drop Zone Calculation (Public for RioContainerView)

    /// 计算 Drop Zone
    /// - Parameter mousePosition: 在 DomainPanelView 坐标系中的鼠标位置
    /// - Returns: 计算出的 Drop Zone，如果无法计算返回 nil
    func calculateDropZone(mousePosition: CGPoint) -> DropZone? {
        guard let panel = panel else { return nil }

        let panelNode = PanelNode(
            id: panel.panelId,
            tabs: panel.tabs.map { TabNode(id: $0.tabId, title: $0.title, rustTerminalId: Int($0.rustTerminalId ?? 0)) },
            activeTabIndex: panel.tabs.firstIndex(where: { $0.tabId == panel.activeTabId }) ?? 0
        )

        let panelBounds = bounds
        let headerBounds = headerView.frame
        let tabBounds = headerView.getTabBounds()

        let calculator = DropZoneCalculator()
        return calculator.calculateDropZoneWithTabBounds(
            panel: panelNode,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            tabBounds: tabBounds,
            mousePosition: mousePosition
        )
    }

    /// 高亮 Drop Zone
    /// - Parameter zone: 要高亮的 Drop Zone
    func highlightDropZone(_ zone: DropZone) {
        currentDropZone = zone
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = zone.highlightArea
        highlightLayer.isHidden = false
        CATransaction.commit()
    }

    /// 清除高亮
    func clearHighlight() {
        currentDropZone = nil
        highlightLayer.isHidden = true
    }

}

