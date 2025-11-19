//
//  PanelView.swift
//  ETerm
//
//  Panel 视图 - Panel 容器（充血模型）
//
//  对应 Golden Layout 的 Stack。
//  采用充血模型设计：
//  - 持有 UI 元素（headerView, contentView, tabViews）
//  - 自己计算 Drop Zone（可以访问 subviews 的 frame）
//  - 自己处理高亮显示
//

import AppKit
import Foundation
import PanelLayoutKit

/// Panel 视图
///
/// 显示一个 Panel（Tab 容器），包含 Header 和 Content 区域。
/// 采用充血模型，自己负责 Drop Zone 计算和显示。
final class PanelView: NSView {
    // MARK: - 数据模型

    /// Panel 节点
    private(set) var panel: PanelNode

    // MARK: - UI 组件

    /// Header 视图（Tab 栏）
    private(set) var headerView: PanelHeaderView

    /// Content 视图（Rust 渲染 Term 的区域）
    private(set) var contentView: NSView

    /// 高亮层（用于显示 Drop Zone）
    private let highlightLayer: CALayer

    // MARK: - 状态

    /// 当前激活的 Tab ID
    private(set) var activeTabId: UUID?

    /// 当前的 Drop Zone
    private var currentDropZone: DropZone?

    // MARK: - 依赖

    /// PanelLayoutKit 实例
    private let layoutKit: PanelLayoutKit

    // MARK: - 回调

    /// Tab 点击回调
    var onTabClick: ((UUID) -> Void)?

    /// Tab 拖拽开始回调
    var onTabDragStart: ((UUID) -> Void)?

    /// Tab 关闭回调
    var onTabClose: ((UUID) -> Void)?

    /// 添加 Tab 回调
    var onAddTab: (() -> Void)?

    /// Drop 回调（用于执行布局重构）
    /// - Parameters:
    ///   - tabId: 被拖拽的 Tab ID
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 是否成功处理 Drop
    var onDrop: ((UUID, DropZone, UUID) -> Bool)?

    // MARK: - 初始化

    init(panel: PanelNode, frame: CGRect, layoutKit: PanelLayoutKit) {
        self.panel = panel
        self.layoutKit = layoutKit
        self.headerView = PanelHeaderView(frame: .zero)
        self.contentView = NSView(frame: .zero)
        self.highlightLayer = CALayer()

        super.init(frame: frame)

        setupUI()
        setupAccessibility()
        updateTabs()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 更新 Panel 数据
    ///
    /// - Parameter panel: 新的 Panel 节点
    func updatePanel(_ panel: PanelNode) {
        self.panel = panel
        updateTabs()
    }

    /// 计算 Drop Zone（充血模型：自己计算）
    ///
    /// 可以访问自己的 subviews，获取实时边界。
    ///
    /// - Parameter mousePosition: 鼠标位置（在 PanelView 内的坐标）
    /// - Returns: 计算出的 Drop Zone，如果不在任何区域则返回 nil
    func calculateDropZone(mousePosition: CGPoint) -> DropZone? {
        // 1. 收集 UI 边界
        let panelBounds = bounds
        let headerBounds = headerView.frame
        let tabBounds = headerView.getTabBounds()

        // 2. 调用 PanelLayoutKit 的完整版算法（支持 Tab 边界）
        return layoutKit.dropZoneCalculator.calculateDropZoneWithTabBounds(
            panel: panel,
            panelBounds: panelBounds,
            headerBounds: headerBounds,
            tabBounds: tabBounds,
            mousePosition: mousePosition
        )
    }

    /// 高亮 Drop Zone
    ///
    /// - Parameter zone: Drop Zone
    func highlightDropZone(_ zone: DropZone) {
        currentDropZone = zone

        // 更新高亮层
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

    /// 设置激活的 Tab
    ///
    /// - Parameter tabId: Tab ID
    func setActiveTab(_ tabId: UUID) {
        activeTabId = tabId
        headerView.setActiveTab(tabId)
        updateAccessibilityLabel()

        // 通知外部（可以用于触发 Rust 渲染）
        onTabClick?(tabId)
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // 配置 Content 视图
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        // 配置高亮层
        highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        highlightLayer.cornerRadius = 4
        highlightLayer.isHidden = true

        // 添加子视图
        addSubview(contentView)
        addSubview(headerView)

        // 添加高亮层到 Content 视图
        contentView.layer?.addSublayer(highlightLayer)

        // 注册接受拖拽类型
        registerForDraggedTypes([.string])

        // 设置 Header 的回调
        headerView.onTabClick = { [weak self] tabId in
            self?.setActiveTab(tabId)
        }
        headerView.onTabDragStart = { [weak self] tabId in
            self?.onTabDragStart?(tabId)
        }
        headerView.onTabClose = { [weak self] tabId in
            self?.onTabClose?(tabId)
        }
        headerView.onAddTab = { [weak self] in
            self?.onAddTab?()
        }
    }

    private func updateTabs() {
        // 更新 Header 显示的 Tab（保持顺序）
        let tabs = panel.tabs.map { (id: $0.id, title: $0.title) }
        headerView.setTabs(tabs)

        // 更新激活的 Tab
        if let activeTab = panel.activeTab {
            setActiveTab(activeTab.id)
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

    // MARK: - Accessibility

    private func setupAccessibility() {
        setAccessibilityRole(.group)
        updateAccessibilityLabel()
    }

    private func updateAccessibilityLabel() {
        if let activeTab = panel.activeTab {
            setAccessibilityLabel("Panel: \(activeTab.title)")
        } else {
            setAccessibilityLabel("Panel")
        }
    }
}

// MARK: - NSDraggingDestination

extension PanelView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 计算 Drop Zone
        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let dropZone = calculateDropZone(mousePosition: locationInView) else {
            return []
        }

        // 高亮 Drop Zone
        highlightDropZone(dropZone)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 与 draggingEntered 逻辑相同
        return draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // 清除高亮
        clearHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 获取拖拽的 Tab ID
        guard let tabIdString = sender.draggingPasteboard.string(forType: .string),
              let tabId = UUID(uuidString: tabIdString) else {
            return false
        }

        // 计算最终的 Drop Zone
        let locationInView = convert(sender.draggingLocation, from: nil)
        guard let dropZone = calculateDropZone(mousePosition: locationInView) else {
            return false
        }

        clearHighlight()

        // 调用回调执行布局重构
        if let onDrop = onDrop {
            return onDrop(tabId, dropZone, panel.id)
        }

        // 如果没有设置回调，只打印日志
        print("[PanelView] performDragOperation: tabId=\(tabId), dropZone=\(dropZone.type), targetPanel=\(panel.id)")
        return true
    }
}
