//
//  PanelHeaderView.swift
//  ETerm
//
//  Panel Header 视图 - Tab 栏
//
//  对应 Golden Layout 的 Header 组件。
//  负责：
//  - 显示所有 Tab
//  - 管理 Tab 的布局
//  - 处理 Tab 的添加/移除
//  - 提供 Tab 边界信息（用于 Drop Zone 计算）
//

import AppKit
import Foundation

/// Panel Header 视图
///
/// 显示 Panel 的所有 Tab，支持 Tab 切换、拖拽和添加。
final class PanelHeaderView: NSView {
    // MARK: - 常量

    private static let headerHeight: CGFloat = 32
    private static let tabWidth: CGFloat = 120
    private static let tabSpacing: CGFloat = 4
    private static let addButtonWidth: CGFloat = 24

    // MARK: - 子视图

    /// Tab 容器（用于横向排列 Tab）
    private let tabContainer: NSView

    /// 添加按钮
    private let addButton: NSButton

    /// Tab 视图列表
    private var tabItemViews: [TabItemView] = []

    // MARK: - 回调

    /// Tab 点击回调
    var onTabClick: ((UUID) -> Void)?

    /// Tab 拖拽开始回调
    var onTabDragStart: ((UUID) -> Void)?

    /// Tab 关闭回调
    var onTabClose: ((UUID) -> Void)?

    /// 添加 Tab 回调
    var onAddTab: (() -> Void)?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        self.tabContainer = NSView()
        self.addButton = NSButton()

        super.init(frame: frameRect)

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 设置 Tab 列表
    ///
    /// - Parameter tabs: Tab 节点列表（按顺序）
    func setTabs(_ tabs: [(id: UUID, title: String)]) {
        // 移除旧的 TabItemView
        tabItemViews.forEach { $0.removeFromSuperview() }
        tabItemViews.removeAll()

        // 创建新的 TabItemView（保持顺序）
        for tab in tabs {
            let tabView = TabItemView(tabId: tab.id, title: tab.title)
            tabView.onTap = { [weak self] in
                self?.onTabClick?(tab.id)
            }
            tabView.onDragStart = { [weak self] in
                self?.onTabDragStart?(tab.id)
            }
            tabView.onClose = { [weak self] in
                self?.onTabClose?(tab.id)
            }
            tabContainer.addSubview(tabView)
            tabItemViews.append(tabView)
        }

        layoutTabs()
    }

    /// 获取所有 Tab 的边界
    ///
    /// - Returns: Tab ID 到边界的映射
    func getTabBounds() -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        for tabView in tabItemViews {
            if result[tabView.tabId] != nil {
                // 检测到重复的 Tab ID
                print("⚠️ 警告：检测到重复的 Tab ID: \(tabView.tabId.uuidString.prefix(8))")
                print("  当前 tabItemViews:", tabItemViews.map { $0.tabId.uuidString.prefix(8) })
            }
            result[tabView.tabId] = tabView.frame
        }
        return result
    }

    /// 设置激活的 Tab
    ///
    /// - Parameter tabId: Tab ID
    func setActiveTab(_ tabId: UUID) {
        tabItemViews.forEach { $0.setActive($0.tabId == tabId) }
    }

    /// 获取推荐的 Header 高度
    static func recommendedHeight() -> CGFloat {
        return headerHeight
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // 配置 Tab 容器
        tabContainer.wantsLayer = true
        addSubview(tabContainer)

        // 配置添加按钮
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.title = ""
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
        addButton.imagePosition = .imageOnly
        addButton.target = self
        addButton.action = #selector(handleAddTab)
        addSubview(addButton)
    }

    private func layoutTabs() {
        var x: CGFloat = Self.tabSpacing

        for tabView in tabItemViews {
            tabView.frame = CGRect(
                x: x,
                y: 0,
                width: Self.tabWidth,
                height: Self.headerHeight
            )
            x += Self.tabWidth + Self.tabSpacing
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        // Tab 容器占据大部分空间
        tabContainer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width - Self.addButtonWidth,
            height: bounds.height
        )

        // 添加按钮在右侧
        addButton.frame = CGRect(
            x: bounds.width - Self.addButtonWidth,
            y: (bounds.height - Self.addButtonWidth) / 2,
            width: Self.addButtonWidth,
            height: Self.addButtonWidth
        )

        // 重新布局 Tab
        layoutTabs()
    }

    // MARK: - Event Handlers

    @objc private func handleAddTab() {
        onAddTab?()
    }
}
