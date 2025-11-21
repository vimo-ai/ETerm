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
//  - 使用 PanelHeaderView 替代简陋的 NSButton
//  - 使用 TabItemView 实现完整的 Tab UI
//  - 通过回调处理事件，避免 button.tag 黑科技
//

import AppKit
import Foundation
import PanelLayoutKit

/// 基于 Domain AR 的 Panel 视图
final class DomainPanelView: NSView {
    // MARK: - Properties

    /// Panel 聚合根（只读引用）
    private weak var panel: EditorPanel?

    /// Coordinator（用于调用 AR 方法）
    private weak var coordinator: TerminalWindowCoordinator?

    /// Header 视图（使用 PanelHeaderView）
    private let headerView: PanelHeaderView

    /// Content 视图（渲染区域 - 透明）
    let contentView: NSView

    /// 高亮层（显示 Drop Zone）
    private let highlightLayer: CALayer

    /// 当前的 Drop Zone
    private var currentDropZone: DropZone?

    // MARK: - Initialization

    init(panel: EditorPanel, coordinator: TerminalWindowCoordinator) {
        self.panel = panel
        self.coordinator = coordinator
        self.headerView = PanelHeaderView()
        self.contentView = NSView()
        self.highlightLayer = CALayer()

        super.init(frame: .zero)

        setupUI()
        updateUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        // 注册拖拽类型
        registerForDraggedTypes([.string])

        // 设置 Header 的回调
        headerView.onTabClick = { [weak self] tabId in
            self?.handleTabClick(tabId)
        }

        headerView.onTabClose = { [weak self] tabId in
            self?.handleTabClose(tabId)
        }

        headerView.onAddTab = { [weak self] in
            self?.handleAddTab()
        }

        headerView.onTabDragStart = { tabId in
            print("[DomainPanelView] Tab drag start: \(tabId)")
        }

        headerView.onSplitHorizontal = { [weak self] in
            self?.handleSplitHorizontal()
        }

        headerView.onSplitVertical = { [weak self] in
            self?.handleSplitVertical()
        }
    }

    // MARK: - Update

    /// 从 AR 更新 UI
    func updateUI() {
        guard let panel = panel else { return }

        // 更新 Header 显示的 Tab
        let tabs = panel.tabs.map { (id: $0.tabId, title: $0.title) }
        headerView.setTabs(tabs)

        // 更新激活的 Tab
        if let activeTabId = panel.activeTabId {
            headerView.setActiveTab(activeTabId)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let headerHeight = PanelHeaderView.recommendedHeight()

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

        coordinator.handleTabClick(panelId: panel.panelId, tabId: tabId)
    }

    private func handleTabClose(_ tabId: UUID) {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleTabClose(panelId: panel.panelId, tabId: tabId)
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

    private func handleSplitVertical() {
        guard let panel = panel,
              let coordinator = coordinator else { return }

        coordinator.handleSplitPanel(panelId: panel.panelId, direction: .vertical)
    }

    // MARK: - Drop Zone Calculation

    /// 计算 Drop Zone
    private func calculateDropZone(mousePosition: CGPoint) -> DropZone? {
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
    private func highlightDropZone(_ zone: DropZone) {
        currentDropZone = zone
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = zone.highlightArea
        highlightLayer.isHidden = false
        CATransaction.commit()
    }

    /// 清除高亮
    private func clearHighlight() {
        currentDropZone = nil
        highlightLayer.isHidden = true
    }
}

// MARK: - NSDraggingDestination

extension DomainPanelView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let dropZone = calculateDropZone(mousePosition: locationInView) else {
            return []
        }
        highlightDropZone(dropZone)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let tabIdString = sender.draggingPasteboard.string(forType: .string),
              let tabId = UUID(uuidString: tabIdString) else {
            return false
        }

        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let dropZone = calculateDropZone(mousePosition: locationInView) else {
            return false
        }

        clearHighlight()

        // 调用 Coordinator 处理 Drop
        guard let panel = panel,
              let coordinator = coordinator else {
            return false
        }

        return coordinator.handleDrop(tabId: tabId, dropZone: dropZone, targetPanelId: panel.panelId)
    }
}
