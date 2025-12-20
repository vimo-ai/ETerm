//
//  PageItemView.swift
//  ETerm
//
//  单个 Page 的视图
//
//  继承 DraggableItemView，使用 SimpleTabView 实现简约风格
//  支持：
//  - 点击切换 Page
//  - 双击编辑标题（重命名）
//  - 关闭 Page（当 Page > 1 时）
//

import AppKit
import SwiftUI
import Foundation

// MARK: - 禁止窗口拖动的 NSHostingView

/// 自定义 NSHostingView 子类，禁止窗口拖动
/// 让 PageItemView 可以正确处理拖拽事件
final class PageItemHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

/// 单个 Page 的视图
///
/// 显示 Page 的标题和关闭按钮，支持点击、双击编辑
final class PageItemView: DraggableItemView {
    // MARK: - 属性

    /// Page ID
    let pageId: UUID

    override var itemId: UUID { pageId }

    /// 关联的 Page 模型（弱引用，用于读取 effectiveDecoration）
    weak var page: Page?

    /// 是否显示关闭按钮
    private var _showCloseButton: Bool = true
    override var showCloseButton: Bool { _showCloseButton }

    // MARK: - 初始化

    init(pageId: UUID, title: String, page: Page? = nil) {
        self.pageId = pageId
        self.page = page

        super.init(frame: .zero)

        setTitle(title)
        setupUI()
        setupDecorationNotifications()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 设置是否显示关闭按钮
    func setShowCloseButton(_ show: Bool) {
        _showCloseButton = show
        updateItemView()
    }

    // MARK: - 子类实现

    override var editFieldFontSize: CGFloat { 22 * 0.4 }
    override var editFieldHeight: CGFloat { 18 }

    override func updateItemView() {
        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 从 Page 模型读取 effectiveDecoration（聚合其下所有 Tab 的装饰）
        // 优先级逻辑：
        // - 如果 isActive：不传 decoration，让 SimpleTabView 用 active 样式
        // - 否则如果有 effectiveDecoration 且 priority > 0：显示该装饰
        var displayDecoration: TabDecoration? = nil
        if !isActive, let pageDecoration = page?.effectiveDecoration, pageDecoration.priority > 0 {
            displayDecoration = pageDecoration
        }

        // 创建新的 SwiftUI 视图
        let closeAction: (() -> Void)? = _showCloseButton ? { [weak self] in
            self?.onClose?()
        } : nil

        let simpleTab = SimpleTabView(
            title,
            isActive: isActive,
            decoration: displayDecoration,
            height: Self.tabHeight,
            isHovered: isHovered,
            onClose: closeAction,
            onCloseOthers: { [weak self] in
                self?.onCloseOthers?()
            },
            onCloseLeft: { [weak self] in
                self?.onCloseLeft?()
            },
            onCloseRight: { [weak self] in
                self?.onCloseRight?()
            },
            canCloseLeft: canCloseLeft,
            canCloseRight: canCloseRight,
            canCloseOthers: canCloseOthers
        )

        // 使用自定义子类禁止窗口拖动
        let hosting = PageItemHostingView(rootView: simpleTab)
        hosting.translatesAutoresizingMaskIntoConstraints = true

        addSubview(hosting)
        hostingView = hosting

        // 立即布局 hostingView
        hosting.frame = bounds

        // 确保编辑框在最上层
        bringEditFieldToFront()
    }

    override func createPasteboardData() -> String {
        // 格式：page:{windowNumber}:{pageId}
        let windowNumber = window?.windowNumber ?? 0
        return "page:\(windowNumber):\(pageId.uuidString)"
    }

    // 使用基类的 hitTest 实现，不需要 override

    // MARK: - Layout

    /// SimpleTabView 的固定高度
    private static let tabHeight: CGFloat = 22

    /// SimpleTabView 的固定宽度
    private static let tabWidth: CGFloat = 180

    override var fittingSize: NSSize {
        return NSSize(width: Self.tabWidth, height: Self.tabHeight)
    }

    override var intrinsicContentSize: NSSize {
        let width = hostingView?.intrinsicContentSize.width ?? NSView.noIntrinsicMetric
        return NSSize(width: width, height: Self.tabHeight)
    }

    // MARK: - Private Methods

    private func setupUI() {
        updateItemView()
    }
}

// MARK: - Page 装饰通知处理

extension PageItemView {
    /// 设置装饰通知监听
    ///
    /// 监听 tabDecorationChanged 通知，当任意 Tab 装饰变化时重新计算 Page.effectiveDecoration
    private func setupDecorationNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDecorationChanged(_:)),
            name: .tabDecorationChanged,
            object: nil
        )

        // 也监听 PageNeedsAttention 通知（兼容旧机制）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageNeedsAttention(_:)),
            name: NSNotification.Name("PageNeedsAttention"),
            object: nil
        )
    }

    @objc private func handleDecorationChanged(_ notification: Notification) {
        // 检查是否与当前 Page 相关
        // Page.effectiveDecoration 是计算属性，会自动聚合所有 Tab
        // 只需刷新视图即可
        updateItemView()
    }

    @objc private func handlePageNeedsAttention(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let notifPageId = userInfo["pageId"] as? UUID,
              notifPageId == pageId else {
            return
        }

        // Page 需要刷新，updateItemView 会从 page.effectiveDecoration 读取
        updateItemView()
    }
}
