//
//  PageBarView.swift
//  ETerm
//
//  Page 栏视图
//
//  横向排列所有 PageItemView
//  支持：
//  - 显示所有 Page
//  - 新增 Page 按钮（+）
//  - 接收 Tab 拖入创建新 Page（预留）
//

import AppKit
import Foundation

/// Page 栏视图
///
/// 显示所有 Page，支持 Page 切换、添加和关闭
final class PageBarView: NSView {
    // MARK: - 常量

    private static let barHeight: CGFloat = 28
    private static let pageItemWidth: CGFloat = 100
    private static let pageItemSpacing: CGFloat = 2
    private static let addButtonWidth: CGFloat = 24
    private static let padding: CGFloat = 4

    // MARK: - 子视图

    /// Page 容器（用于横向排列 Page）
    private let pageContainer: NSView

    /// 添加按钮
    private let addButton: NSButton

    /// Page 视图列表
    private var pageItemViews: [PageItemView] = []

    /// 当前激活的 Page ID
    private var activePageId: UUID?

    // MARK: - 回调

    /// Page 点击回调
    var onPageClick: ((UUID) -> Void)?

    /// Page 关闭回调
    var onPageClose: ((UUID) -> Void)?

    /// Page 重命名回调
    var onPageRename: ((UUID, String) -> Void)?

    /// 添加 Page 回调
    var onAddPage: (() -> Void)?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        self.pageContainer = NSView()
        self.addButton = NSButton()

        super.init(frame: frameRect)

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 设置 Page 列表
    ///
    /// - Parameter pages: Page 数据列表（按顺序）
    func setPages(_ pages: [(id: UUID, title: String)]) {
        let newIds = Set(pages.map { $0.id })
        let existingIds = Set(pageItemViews.map { $0.pageId })

        // 1. 删除不再存在的 Page
        let toRemove = pageItemViews.filter { !newIds.contains($0.pageId) }
        toRemove.forEach { $0.removeFromSuperview() }
        pageItemViews.removeAll { !newIds.contains($0.pageId) }

        // 2. 计算是否显示关闭按钮
        let showCloseButton = pages.count > 1

        // 3. 更新已存在的，创建新的
        for page in pages {
            if let existingView = pageItemViews.first(where: { $0.pageId == page.id }) {
                // 已存在：只更新标题和关闭按钮状态
                existingView.setTitle(page.title)
                existingView.setShowCloseButton(showCloseButton)
            } else {
                // 新的：创建 View
                let pageView = PageItemView(pageId: page.id, title: page.title)
                pageView.setShowCloseButton(showCloseButton)
                pageView.onTap = { [weak self] in
                    self?.onPageClick?(page.id)
                }
                pageView.onClose = { [weak self] in
                    self?.onPageClose?(page.id)
                }
                pageView.onRename = { [weak self] newTitle in
                    self?.onPageRename?(page.id, newTitle)
                }
                pageContainer.addSubview(pageView)
                pageItemViews.append(pageView)
            }
        }

        // 4. 按 pages 顺序重新排序 pageItemViews
        pageItemViews.sort { view1, view2 in
            let idx1 = pages.firstIndex(where: { $0.id == view1.pageId }) ?? Int.max
            let idx2 = pages.firstIndex(where: { $0.id == view2.pageId }) ?? Int.max
            return idx1 < idx2
        }

        // 5. 更新激活状态
        if let activeId = activePageId {
            setActivePage(activeId)
        }

        layoutPages()
    }

    /// 设置激活的 Page
    ///
    /// - Parameter pageId: Page ID
    func setActivePage(_ pageId: UUID) {
        activePageId = pageId
        pageItemViews.forEach { $0.setActive($0.pageId == pageId) }
    }

    /// 获取推荐的 Bar 高度
    static func recommendedHeight() -> CGFloat {
        return barHeight
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true
        // 使用稍深的背景色，与 Tab 栏区分
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor

        // 底部边框
        let bottomBorder = CALayer()
        bottomBorder.backgroundColor = NSColor.separatorColor.cgColor
        bottomBorder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        bottomBorder.autoresizingMask = [.layerWidthSizable]
        layer?.addSublayer(bottomBorder)

        // 配置 Page 容器
        pageContainer.wantsLayer = true
        addSubview(pageContainer)

        // 配置添加按钮
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.title = ""
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Page")
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(handleAddPage)
        addSubview(addButton)
    }

    private func layoutPages() {
        var x: CGFloat = Self.padding

        for pageView in pageItemViews {
            pageView.frame = CGRect(
                x: x,
                y: (Self.barHeight - 22) / 2,
                width: Self.pageItemWidth,
                height: 22
            )
            x += Self.pageItemWidth + Self.pageItemSpacing
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        // 添加按钮在右侧
        let buttonSize = Self.addButtonWidth
        addButton.frame = CGRect(
            x: bounds.width - buttonSize - Self.padding,
            y: (bounds.height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )

        // Page 容器占据剩余空间
        pageContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width - buttonSize - Self.padding * 2,
            height: bounds.height
        )

        // 重新布局 Page
        layoutPages()
    }

    // MARK: - Event Handlers

    @objc private func handleAddPage() {
        onAddPage?()
    }

    // MARK: - Mouse Tracking（为 hover 效果做准备）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的 tracking area
        trackingAreas.forEach { removeTrackingArea($0) }

        // 添加新的 tracking area
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
}

// MARK: - NSDraggingDestination（预留：接收 Tab 拖入）

extension PageBarView {
    /// 注册接受的拖拽类型
    func registerForDraggedTypes() {
        registerForDraggedTypes([.string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 预留：检查是否是 Tab 拖拽
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 预留：高亮显示放置位置
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 预留：创建新 Page 并移动 Tab
        return false
    }
}
